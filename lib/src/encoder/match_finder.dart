/// LZ77 match finders for the encoder.
///
/// Two matchers live here:
///
/// * [MatchFinder] - the reference "H2/H3 style" single-slot hash table used by
///   the fast quality 0/1 paths: one candidate position per hash, updated while
///   scanning. The table stores `position + 1` so that `0` means "empty"
///   without a separate bitmap. It is persistent across meta-blocks (the C fast
///   path resets it per block and so loses cross-block matches; keeping it is a
///   deliberate, documented ratio improvement).
/// * [HashChainMatcher] - the "H5-style" bucket + candidate ring used from
///   quality 4 upwards: each bucket keeps the last `2^blockBits` positions with
///   that hash and every one of them is scored with
///   [backwardReferenceScore] (`135 * len - 30 * log2(dist)`), so a slightly
///   shorter but much closer copy can win over the longest copy. It also checks
///   the last up-to-16 distances from the decoder's distance cache, which makes
///   the very common "repeat the previous distance" case nearly free.
///
/// Hash functions are 32-bit safe: every product goes through [mul32] and the
/// final mask is a small positive value, so the code produces identical hashes
/// on the VM, dart2js and dart2wasm even when intermediate bit patterns would
/// be negative in JavaScript.
library;

import 'dart:typed_data';

import '../common/bit_utils.dart';
import 'byte_access.dart';

export 'byte_access.dart' show findMatchLength, read32le;

/// 32-bit hash multiplier from `c/enc/hash_base.h`.
const int kHashMul32 = 0x1E35A7BD;

/// Hash of the four bytes at [pos], folded into `tableBits` bits.
int hash4(Uint8List data, int pos, int tableBits) {
  final mask = (1 << tableBits) - 1;
  return (mul32(read32le(data, pos), kHashMul32) >> (32 - tableBits)) & mask;
}

/// Hash of the six bytes at [pos], folded into `tableBits` bits.
///
/// This is our own deterministic 6-byte mix (the reference uses a 64-bit
/// multiply). It combines a 4-byte word with the two following bytes; the
/// intermediate product stays below 2^33, so it is exact on the web and the
/// final small mask discards everything above the table index.
int hash6(Uint8List data, int pos, int tableBits) {
  final mask = (1 << tableBits) - 1;
  final shift = 32 - tableBits;
  final h0 = (mul32(read32le(data, pos), kHashMul32) >> shift) & mask;
  final h1 = (mul32(read32le(data, pos + 2), 0x9E3779B1) >> shift) & mask;
  return ((h0 * 0x9E37) + h1) & mask;
}

/// Whether `data[a..a+minMatch)` equals `data[b..b+minMatch)`.
///
/// [minMatch] is 4 or 6. The caller guarantees both ranges are in bounds.
bool isMatch(Uint8List data, int a, int b, int minMatch) {
  if (read32le(data, a) != read32le(data, b)) return false;
  if (minMatch == 4) return true;
  return data[a + 4] == data[b + 4] && data[a + 5] == data[b + 5];
}

/// Single-slot hash table used by the greedy matcher.
final class MatchFinder {
  /// Creates a matcher with a `1 << tableBits` slot table.
  ///
  /// [minMatch] is the minimum match length (4 for quality 0, 6 for quality 1).
  MatchFinder({required this.tableBits, required this.minMatch})
    : assert(tableBits >= 8 && tableBits <= 24),
      assert(minMatch == 4 || minMatch == 6),
      table = Uint32List(1 << tableBits),
      shift = 32 - tableBits;

  /// Number of hash bits (16 for quality 0, 17 for quality 1).
  final int tableBits;

  /// Minimum match length checked by [isMatch].
  final int minMatch;

  /// `32 - tableBits`, kept for the hash helpers.
  final int shift;

  /// Hash table; slot `i` holds `position + 1`, or `0` when empty.
  final Uint32List table;

  /// Forgets every stored position.
  void clear() {
    table.fillRange(0, table.length, 0);
  }

  /// Hash of the [minMatch] bytes at [pos].
  int hashAt(Uint8List input, int pos) => minMatch == 4
      ? hash4(input, pos, tableBits)
      : hash6(input, pos, tableBits);

  /// Inserts the positions `ip - minMatch + 1 .. ip - 1` and returns the
  /// candidate recorded for `ip` (or `-1` when the slot was empty).
  ///
  /// This mirrors the "update table with the hashes of some positions within
  /// the last copy" trick of `CreateCommands`.
  int insertAndLookup(Uint8List input, int ip) {
    for (var p = ip - minMatch + 1; p < ip; p++) {
      table[hashAt(input, p)] = p + 1;
    }
    final hash = hashAt(input, ip);
    final candidate = table[hash] - 1;
    table[hash] = ip + 1;
    return candidate;
  }
}

// ---------------------------------------------------------------------------
// Backward-reference scoring (c/enc/hash.h)
// ---------------------------------------------------------------------------

/// Score contribution of one literal byte (`BROTLI_LITERAL_BYTE_SCORE`).
const int kLiteralByteScore = 135;

/// Penalty per distance bit (`BROTLI_DISTANCE_BIT_PENALTY`).
const int kDistanceBitPenalty = 30;

/// `BROTLI_SCORE_BASE = 30 * 8 * sizeof(size_t)`.
///
/// The reference is built with a 64-bit `size_t`; the constant shifts every
/// score by the same amount, so match *selection* is unaffected by using it
/// verbatim. It keeps the "score must stay positive" property documented next
/// to the C constant.
const int kScoreBase = kDistanceBitPenalty * 8 * 8;

/// Minimum score for a backward reference to be accepted (`kMinScore`).
const int kMinScore = kScoreBase + 100;

/// Score of a copy of [copyLength] bytes at [backward] distance.
///
/// `BROTLI_SCORE_BASE + 135 * len - 30 * log2(dist)`; a longer match is always
/// better, and at equal length a closer match wins.
int backwardReferenceScore(int copyLength, int backward) =>
    kScoreBase +
    kLiteralByteScore * copyLength -
    kDistanceBitPenalty * log2Floor(backward);

/// Score of a copy that reuses one of the last distances.
int backwardReferenceScoreUsingLastDistance(int copyLength) =>
    kLiteralByteScore * copyLength + kScoreBase + 15;

/// Penalty applied when the copy reuses a *non-most-recent* short code.
int backwardReferencePenaltyUsingLastDistance(int distanceShortCode) =>
    39 + ((0x1CA10 >> (distanceShortCode & 0xE)) & 0xE);

/// Mutable search result; one instance per search site keeps the hot loop
/// allocation-free.
final class HasherSearchResult {
  /// Match length in bytes.
  int len = 0;

  /// Backward distance in bytes (always positive for a real match).
  int distance = 0;

  /// Score of this match; starts at [kMinScore] so "no match" is `<= kMinScore`.
  int score = 0;

  /// Resets for a new search at [minScore].
  void reset(int minScore) {
    len = 0;
    distance = 0;
    score = minScore;
  }

  /// Copies [other] into this result.
  void copyFrom(HasherSearchResult other) {
    len = other.len;
    distance = other.distance;
    score = other.score;
  }
}

/// Expands the four decoder-known distances into the up-to-16 search entries
/// (`PrepareDistanceCache`).
///
/// Entries `4..9` are `distance_cache[0] +- 1..3`, entries `10..15` are the
/// same around `distance_cache[1]`. They are search-only values: the decoder
/// keeps four distances and the encoder only ever codes a short reference to
/// one of those four (or to one of the `+-1..3` codes, which the distance
/// prefix encoding covers directly).
void prepareDistanceCache(Int32List distanceCache, int numDistances) {
  if (numDistances > 4) {
    final last = distanceCache[0];
    distanceCache[4] = last - 1;
    distanceCache[5] = last + 1;
    distanceCache[6] = last - 2;
    distanceCache[7] = last + 2;
    distanceCache[8] = last - 3;
    distanceCache[9] = last + 3;
    if (numDistances > 10) {
      final next = distanceCache[1];
      distanceCache[10] = next - 1;
      distanceCache[11] = next + 1;
      distanceCache[12] = next - 2;
      distanceCache[13] = next + 2;
      distanceCache[14] = next - 3;
      distanceCache[15] = next + 3;
    }
  }
}

/// Creates the 16-entry distance cache used by [HashChainMatcher].
///
/// The first four entries are the RFC 7932 initial cache; the rest are filled
/// by [prepareDistanceCache] before the first search.
Int32List createSearchDistanceCache() => Int32List.fromList(<int>[
  4,
  11,
  15,
  16,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
]);

/// Hash-chain match finder ("H5 style": bucket 2^bucketBits + a ring of
/// `2^blockBits` recent positions per bucket).
///
/// Positions are absolute offsets into the whole input (the encoder keeps the
/// complete buffer in memory), so matches may cross meta-block boundaries. The
/// ring keeps the newest `blockSize` candidates: a bucket that overflows
/// silently drops its oldest entry, exactly like the reference hasher.
final class HashChainMatcher {
  /// Creates a matcher.
  ///
  /// [bucketBits] is the number of hash bits (14 in the reference for
  /// qualities 4..6) and [blockBits] the log2 of candidates per bucket
  /// (3 => 8, 4 => 16). [numLastDistances] is how many entries of the prepared
  /// distance cache are tried before the chain (4 in the reference at
  /// qualities 4..6, up to 16 at quality 9).
  HashChainMatcher({
    required this.bucketBits,
    required this.blockBits,
    required this.numLastDistances,
  }) : assert(bucketBits >= 8 && bucketBits <= 20),
       assert(blockBits >= 1 && blockBits <= 8),
       assert(
         numLastDistances == 4 ||
             numLastDistances == 10 ||
             numLastDistances == 16,
       ),
       bucketSize = 1 << bucketBits,
       blockSize = 1 << blockBits,
       blockMask = (1 << blockBits) - 1,
       hashShift = 32 - bucketBits,
       buckets = _takeBuckets((1 << bucketBits) << blockBits),
       counts = Uint32List(1 << bucketBits);

  /// Bucket storage handed back by [release], reused by the next matcher of
  /// the same geometry. At quality 9 the table is 32 MiB, and allocating
  /// (zeroing and faulting in) a fresh one per call cost more than the parse
  /// of a small input. Stale contents are harmless: a slot is only read below
  /// its bucket's count, and [counts] always starts at zero.
  static Uint32List? _pooledBuckets;

  static Uint32List _takeBuckets(int size) {
    final pooled = _pooledBuckets;
    if (pooled != null && pooled.length == size) {
      _pooledBuckets = null;
      return pooled;
    }
    return Uint32List(size);
  }

  /// Returns the bucket storage to the pool. The matcher must not be used
  /// afterwards; long-lived (streaming) matchers simply never release.
  void release() {
    _pooledBuckets = buckets;
  }

  /// Number of hash bits.
  final int bucketBits;

  /// log2 of the candidate ring size per bucket.
  final int blockBits;

  /// Number of last-distance entries checked before the chain.
  final int numLastDistances;

  /// `1 << bucketBits`.
  final int bucketSize;

  /// `1 << blockBits` candidates retained per bucket.
  final int blockSize;

  /// `blockSize - 1`.
  final int blockMask;

  /// `32 - bucketBits`.
  final int hashShift;

  /// Bucket storage: `buckets[(key << blockBits) + (count & blockMask)]`.
  final Uint32List buckets;

  /// Per-bucket insertion count (only the low `blockBits` matter for the slot;
  /// the total is needed to know how many entries are still live).
  final Uint32List counts;

  /// Forgets every stored position.
  void clear() {
    buckets.fillRange(0, buckets.length, 0);
    counts.fillRange(0, counts.length, 0);
  }

  /// Hash of the four bytes at [pos].
  @pragma('vm:prefer-inline')
  int hashAt(Uint8List data, int pos) =>
      (mul32(read32le(data, pos), kHashMul32) >> hashShift) & (bucketSize - 1);

  /// Stores [pos] in its bucket (`Store`).
  void store(Uint8List data, int pos) {
    final key = hashAt(data, pos);
    buckets[(key << blockBits) + (counts[key] & blockMask)] = pos;
    counts[key] = counts[key] + 1;
  }

  /// Finds the best scored match for [curIx] and stores [curIx].
  ///
  /// [maxLength] caps the copy length (`posEnd - curIx`), [maxBackward] caps
  /// the distance (`min(curIx, (1 << lgwin) - 16)`), [distanceCache] is the
  /// 16-entry cache prepared by [prepareDistanceCache] and [numDistances] is
  /// how many of its entries to try. [out] is updated in place; its incoming
  /// [HasherSearchResult.score] / [HasherSearchResult.len] act as thresholds
  /// (used by lazy matching to look for a strictly better match ahead).
  void findLongestMatch(
    Uint8List data,
    Int32List distanceCache,
    int numDistances,
    int curIx,
    int maxLength,
    int maxBackward,
    HasherSearchResult out, {
    int maxCandidates = 1 << 30,
  }) {
    var bestScore = out.score;
    var bestLen = out.len;
    final key = hashAt(data, curIx);
    out.len = 0;
    out.distance = 0;

    // Try the last distances first: they are cheap to code, especially the most
    // recent one.
    for (var i = 0; i < numDistances; i++) {
      final backward = distanceCache[i];
      if (backward <= 0) continue;
      if (backward > maxBackward) continue;
      final prevIx = curIx - backward;
      if (prevIx < 0 || prevIx >= curIx) continue;
      if (bestLen >= maxLength) break;
      if (data[curIx + bestLen] != data[prevIx + bestLen]) continue;
      final len = findMatchLength(data, prevIx, curIx, maxLength);
      if (len >= 3 || (len == 2 && i < 2)) {
        // Accepting len == 2 does not change semantics, it only avoids a few
        // useless logarithm computations for matches we would reject anyway.
        var score = backwardReferenceScoreUsingLastDistance(len);
        if (bestScore < score) {
          if (i != 0) score -= backwardReferencePenaltyUsingLastDistance(i);
          if (bestScore < score) {
            bestScore = score;
            bestLen = len;
            out.len = len;
            out.distance = backward;
            out.score = score;
          }
        }
      }
    }

    // Matches shorter than 4 are never taken from the chain; starting at
    // best_len >= 3 lets the candidates be filtered with one 32-bit compare.
    if (bestLen < 3) bestLen = 3;
    if (bestLen < maxLength) {
      final count = counts[key];
      final down = count > blockSize ? count - blockSize : 0;
      final bucketBase = key << blockBits;
      var candidatesLeft = maxCandidates;
      for (var i = count; i > down;) {
        if (candidatesLeft <= 0) break;
        candidatesLeft--;
        i--;
        // A match that already spans the whole remaining block cannot be
        // improved, and the 4-byte window used to reject candidates would read
        // past the end of the input.
        if (bestLen >= maxLength) break;
        final prevIx = buckets[bucketBase + (i & blockMask)];
        final backward = curIx - prevIx;
        // Stored positions increase monotonically, so once a candidate is out
        // of the window every older one is too.
        if (backward <= 0 || backward > maxBackward) break;
        // Compare the 4 bytes that end at `bestLen + 1`, so a candidate can
        // only be accepted if it is actually longer than the best so far.
        // The last of those bytes alone rejects most candidates (the
        // reference's one-byte check), so test it before the 4-byte window.
        if (data[curIx + bestLen] != data[prevIx + bestLen]) continue;
        if (read32le(data, curIx + bestLen - 3) !=
            read32le(data, prevIx + bestLen - 3)) {
          continue;
        }
        final len = findMatchLength(data, prevIx, curIx, maxLength);
        if (len >= 4) {
          final score = backwardReferenceScore(len, backward);
          if (bestScore < score) {
            bestScore = score;
            bestLen = len;
            out.len = len;
            out.distance = backward;
            out.score = score;
          }
        }
      }
    }

    final slot = (key << blockBits) + (counts[key] & blockMask);
    if (journalLength >= 0) {
      if (journalLength >= _journalValues.length) _growJournal();
      _journalSlots[journalLength] = slot;
      _journalValues[journalLength] = buckets[slot];
      _journalKeys[journalLength] = key;
      _journalCounts[journalLength] = counts[key];
      journalLength++;
    }
    buckets[slot] = curIx;
    counts[key] = counts[key] + 1;
  }

  // -- speculative parse support -----------------------------------------
  //
  // The guided parsers of qualities 10/11 search speculatively; every search
  // inserts a position into the table. That would perturb the table the next
  // block's chain parse sees (and with it the promise that quality 10 is never
  // worse than quality 9). An optional undo log lets the caller roll the
  // insertions back and restore the exact table state.

  Uint32List _journalSlots = Uint32List(0);
  Uint32List _journalValues = Uint32List(0);
  Uint32List _journalKeys = Uint32List(0);
  Uint32List _journalCounts = Uint32List(0);

  /// Number of logged insertions, or -1 when journaling is disabled.
  int journalLength = -1;

  /// Starts recording table insertions (up to [capacity] of them).
  void beginJournal(int capacity) {
    if (_journalValues.length < capacity) {
      _journalValues = Uint32List(capacity);
      _journalSlots = Uint32List(capacity);
      _journalKeys = Uint32List(capacity);
      _journalCounts = Uint32List(capacity);
    }
    journalLength = 0;
  }

  void _growJournal() {
    final capacity = _journalValues.length * 2 + 16;
    final values = Uint32List(capacity)
      ..setRange(0, journalLength, _journalValues);
    final slots = Uint32List(capacity)
      ..setRange(0, journalLength, _journalSlots);
    final keys = Uint32List(capacity)..setRange(0, journalLength, _journalKeys);
    final counts = Uint32List(capacity)
      ..setRange(0, journalLength, _journalCounts);
    _journalValues = values;
    _journalSlots = slots;
    _journalKeys = keys;
    _journalCounts = counts;
  }

  /// Undoes every insertion recorded since [beginJournal].
  void rollbackJournal() {
    if (journalLength <= 0) return;
    for (var i = journalLength - 1; i >= 0; i--) {
      buckets[_journalSlots[i]] = _journalValues[i];
      counts[_journalKeys[i]] = _journalCounts[i];
    }
    journalLength = 0;
  }

  /// Stops recording (call after [rollbackJournal]).
  void endJournal() {
    journalLength = -1;
  }
}
