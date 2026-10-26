/// Hash-chain matcher and LZ77 parser for the fast tier (qualities 0..5).
///
/// A flat hash table with a per-position chain, four-byte multiply hashing,
/// candidate checks that stop at the first hit, and a parse loop written so
/// that the common case is a handful of loads and compares per byte. It fills
/// the same [CommandBuffer] as the high-ratio path, so both share the
/// command and distance encoding.
library;

import 'dart:typed_data';

import '../common/bit_utils.dart';
import 'command.dart';
import 'byte_access.dart';

/// Hash multiplier (`kHashMul32`).
const int _kHashMul = 0x1E35A7BD;

/// Minimum match length for the 4-byte hash.
const int _kMinMatch = 4;

/// Parse tuning knobs for one quality tier.
final class FastParseParams {
  const FastParseParams({
    required this.bucketBits,
    required this.maxCandidates,
    required this.numLastDistances,
    required this.lazySteps,
    required this.minMatch,
    required this.blockSize,
    this.denseInsertLimit = 8,
    this.minChainLen = 0,
    this.positionStride = 1,
  });

  /// log2 of the hash table size.
  final int bucketBits;

  /// Maximum chain candidates examined per position.
  final int maxCandidates;

  /// Recent distances tried before the chain.
  final int numLastDistances;

  /// Lazy deferral steps (0 = greedy).
  final int lazySteps;

  /// Minimum accepted match length.
  final int minMatch;

  /// Meta-block size.
  final int blockSize;

  /// Copies up to this length register every covered position in the hash
  /// table; longer copies only register their tail.
  final int denseInsertLimit;

  /// Skip the chain walk when a recent-distance probe already found a match of
  /// at least this length (0 = always walk the chain).
  final int minChainLen;

  /// Only every n-th position may start a copy (1 = every position). A larger
  /// stride trades a little ratio for a big cut in per-byte hashing, which is
  /// what the lowest quality binary tier wants.
  final int positionStride;

  /// Binary q0/q1 tier (shared): single-slot 4-byte hash with no chain memory
  /// traffic, greedy, no recent-distance probes, 128 KiB blocks, copies
  /// registered only at their tail, and only every second position able to
  /// start a copy (which halves the hashing work and turned out to *improve*
  /// the ratio on the binary corpus). The parse computes the hash once per
  /// position and reuses it for the insert. Tuned for binary input, where
  /// per-byte hashing dominates; text q0/q1 use the greedy path in `lz77.dart`.
  static const FastParseParams greedyBinary = FastParseParams(
    bucketBits: 15,
    maxCandidates: 1,
    numLastDistances: 0,
    lazySteps: 0,
    minMatch: 4,
    blockSize: 1 << 17,
    denseInsertLimit: 0,
    positionStride: 2,
  );

  /// Binary q5 tier: one extra candidate and a recent-distance probe, but
  /// still greedy and hash-light. Used when the input is classified binary;
  /// text q5 keeps the full lazy tier.
  static const FastParseParams q5Binary = FastParseParams(
    bucketBits: 16,
    maxCandidates: 2,
    numLastDistances: 1,
    lazySteps: 0,
    minMatch: 4,
    blockSize: 1 << 17,
    denseInsertLimit: 0,
    positionStride: 2,
  );

  /// Quality 2..5 speed tier: small table for cache locality, four chain
  /// candidates, two recent-distance probes, 1-step lazy, and the chain walk
  /// skipped once a recent distance already matches 24 bytes. Tuned on the
  /// 1 MiB text/binary benchmark corpora.
  static const FastParseParams q5 = FastParseParams(
    bucketBits: 17,
    maxCandidates: 4,
    numLastDistances: 2,
    lazySteps: 1,
    minMatch: 4,
    blockSize: 1 << 17,
    minChainLen: 24,
  );
}

/// Flat hash table plus per-position chain over the whole input.
final class FastHasher {
  FastHasher(Uint8List input, int bucketBits, {bool trackChain = true})
    : _input = input,
      _view = ByteData.sublistView(input),
      _buckets = Uint32List(1 << bucketBits),
      _shift = 32 - bucketBits,
      _prev = trackChain ? Uint32List(input.length + 1) : Uint32List(1),
      // ignore: prefer_initializing_formals
      _trackChain = trackChain;

  final Uint8List _input;

  /// The input as `ByteData`, for single-load reads on the VM.
  final ByteData _view;
  final int _shift;
  final Uint32List _buckets;
  final Uint32List _prev;
  final bool _trackChain;

  /// Hash of the four bytes at [pos], exposed so the single-slot parser can
  /// search and insert with one hash computation instead of two.
  int hashPosition(int pos) => _hash(pos);

  /// Head of the bucket for an already computed [hash].
  int bucketHeadAt(int hash) => _buckets[hash];

  /// Inserts [pos] into the bucket for an already computed [hash].
  void insertAt(int pos, int hash) {
    _buckets[hash] = pos + 1;
  }

  @pragma('vm:prefer-inline')
  int _hash(int pos) =>
      mul32(read32At(_view, _input, pos), _kHashMul) >> _shift;

  /// Inserts [pos] and returns the previous head (0 when empty).
  int insert(int pos) {
    final h = _hash(pos);
    final previous = _buckets[h];
    _buckets[h] = pos + 1;
    if (_trackChain) _prev[pos] = previous;
    return previous;
  }

  /// Length of the match between [a] and [b] (b > a), at most [limit].
  @pragma('vm:prefer-inline')
  int matchLength(int a, int b, int limit) =>
      findMatchLength(_input, a, b, limit);

  /// Best match at [pos]; writes to [outLen]/[outDistance].
  ///
  /// Candidates are visited from the most recent to the oldest; the first
  /// candidate whose 4-byte window differs is skipped cheaply. Returns the
  /// match length (0 when there is none).
  int find(
    int pos,
    int maxLength,
    int maxBackward,
    int maxCandidates,
    int minMatch,
    Int32List outLen,
    Int32List outDist,
  ) {
    var bestLen = 0;
    var bestDist = 0;
    if (pos + _kMinMatch > _input.length) return 0;
    if (maxBackward <= 0 || maxLength < minMatch) return 0;
    var candidate = _buckets[_hash(pos)];
    var tries = maxCandidates;
    while (candidate != 0 && tries-- > 0) {
      final prevPos = candidate - 1;
      final distance = pos - prevPos;
      if (distance <= 0 || distance > maxBackward) break;
      // Cheap rejection: only extend when the candidate can beat the best.
      // The 4-byte window ends at `bestLen`, so it needs `bestLen >= 3` to
      // stay inside the candidate (a 1..2 byte best would read before it).
      if (prevPos + bestLen + 1 <= pos && bestLen >= 3) {
        if (read32le(_input, prevPos + bestLen - 3) !=
            read32le(_input, pos + bestLen - 3)) {
          candidate = _prev[prevPos];
          continue;
        }
      }
      final length = matchLength(prevPos, pos, maxLength);
      if (length > bestLen) {
        bestLen = length;
        bestDist = distance;
        if (length >= maxLength) break;
      }
      candidate = _prev[prevPos];
    }
    if (bestLen < minMatch) return 0;
    outLen[0] = bestLen;
    outDist[0] = bestDist;
    return bestLen;
  }
}

/// Greedy / lazy LZ77 parse of `input[start .. start + size)` into [commands].
///
/// [hasher] is persistent across blocks; [distanceCache] is the decoder ring
/// (16 entries, first four meaningful) and is advanced exactly like the
/// decoder's when copies are emitted.
void fastParse(
  Uint8List input,
  int start,
  int size,
  FastHasher hasher,
  CommandBuffer commands,
  Int32List distanceCache,
  int maxBackwardLimit,
  FastParseParams params,
) {
  commands.clear();
  final end = start + size;
  if (size < 16) {
    commands.addInsertOnly(size);
    return;
  }
  final maxCandidates = params.maxCandidates;
  final numLast = params.numLastDistances;
  final minMatch = params.minMatch;
  final lazySteps = params.lazySteps;
  final lenResult = Int32List(1);
  final distResult = Int32List(1);
  var pos = start;
  var insertLen = 0;

  const requiredLookahead = _kMinMatch;
  // Stride filter: powers of two use a mask (an integer modulo per input byte
  // is one of the most expensive operations in this loop).
  final stride = params.positionStride;
  final strideMask = (stride > 1 && (stride & (stride - 1)) == 0)
      ? stride - 1
      : 0;
  final useStrideMask = strideMask != 0;
  final useStrideModulo = stride > 1 && !useStrideMask;
  // Until the window limit is reached `maxBackward == pos`, so the distance
  // check against it is redundant; hoist the windowed branch out of the loop.
  while (pos < end) {
    final maxLength = end - pos;
    if (maxLength < requiredLookahead) break;
    final maxBackward = pos < maxBackwardLimit ? pos : maxBackwardLimit;
    if (useStrideMask
        ? ((pos - start) & strideMask) != 0
        : (useStrideModulo && (pos - start) % stride != 0)) {
      // Not a search position: emit a literal without touching the hash table.
      insertLen++;
      pos++;
      continue;
    }
    final searchHash = maxCandidates <= 1 ? hasher.hashPosition(pos) : 0;
    // Recent distances first: they are cheap to code.
    var bestLen = 0;
    var bestDist = 0;
    final lastCount = numLast < 4 ? numLast : 4;
    for (var i = 0; i < lastCount; i++) {
      final distance = distanceCache[i];
      if (distance <= 0 || distance > maxBackward || distance > pos) continue;
      final previous = pos - distance;
      if (previous < 0) continue;
      if (read32le(input, previous) != read32le(input, pos)) continue;
      final length = hasher.matchLength(previous, pos, maxLength);
      if (length > bestLen) {
        bestLen = length;
        bestDist = distance;
        if (length >= maxLength) break;
      }
    }
    // A recent-distance hit that already reaches [minChainLen] is good enough:
    // skipping the chain walk there is the single biggest binary speed win.
    if (bestLen < maxLength &&
        (params.minChainLen == 0 || bestLen < params.minChainLen)) {
      if (maxCandidates <= 1) {
        // Single-slot inline probe (q0/q1 fast tier): one bucket read, one
        // candidate check, no chain walk and no result object. The hash is
        // reused for the insert, halving the hashing work per position.
        final head = hasher.bucketHeadAt(searchHash);
        if (head != 0) {
          final previous = head - 1;
          final distance = pos - previous;
          if (distance > 0 && distance <= maxBackward) {
            final length = hasher.matchLength(previous, pos, maxLength);
            if (length > bestLen) {
              bestLen = length;
              bestDist = distance;
            }
          }
        }
      } else {
        final found = hasher.find(
          pos,
          maxLength,
          maxBackward,
          maxCandidates,
          minMatch,
          lenResult,
          distResult,
        );
        if (found > bestLen) {
          bestLen = lenResult[0];
          bestDist = distResult[0];
        }
      }
    }
    if (maxCandidates <= 1) {
      hasher.insertAt(pos, searchHash);
    } else {
      hasher.insert(pos);
    }

    if (bestLen >= minMatch) {
      if (lazySteps > 0 && pos + 1 < end && bestLen < maxLength) {
        // One-step lazy: prefer a match starting one byte later when it is
        // clearly longer.
        final nextMax = end - pos - 1;
        final nextBackward = (pos + 1) < maxBackwardLimit
            ? (pos + 1)
            : maxBackwardLimit;
        var nextLen = 0;
        var nextDist = 0;
        // The lazy probe is a single candidate: a full chain search here would
        // double the per-position cost for a small ratio gain.
        final found = hasher.find(
          pos + 1,
          nextMax,
          nextBackward,
          1,
          minMatch,
          lenResult,
          distResult,
        );
        if (found > 0) {
          nextLen = lenResult[0];
          nextDist = distResult[0];
        }
        if (nextLen > bestLen + 1) {
          // Defer: emit one literal, keep hashing.
          hasher.insert(pos + 1);
          insertLen++;
          pos++;
          bestLen = nextLen;
          bestDist = nextDist;
        }
      }
      final codingMaxDistance = pos < maxBackwardLimit ? pos : maxBackwardLimit;
      commands.addCopy(
        insertLen,
        bestLen,
        bestDist,
        codingMaxDistance,
        distanceCache,
      );
      insertLen = 0;
      // Hash the positions covered by the copy (skip a head-start for
      // short distances to avoid poisoning the table with a run).
      final copyEnd = pos + bestLen;
      final storeTo = copyEnd < end - 3 ? copyEnd : end - 3;
      if (bestLen <= params.denseInsertLimit) {
        // Short copies: keep the table dense so nearby positions stay viable.
        for (var i = pos + 1; i < storeTo; i++) {
          hasher.insert(i);
        }
      } else {
        // Long copies: only the tail is worth hashing; the interior is
        // re-found from later matches and hashing it would cost one hash per
        // covered byte (the dominant fast-tier cost before this policy).
        final from = copyEnd - 2 > pos + 1 ? copyEnd - 2 : pos + 1;
        for (var i = from; i < storeTo; i++) {
          hasher.insert(i);
        }
      }
      pos += bestLen;
    } else {
      insertLen++;
      pos++;
    }
  }
  final tail = end - pos;
  if (tail > 0) insertLen += tail;
  if (insertLen > 0) commands.addInsertOnly(insertLen);
}
