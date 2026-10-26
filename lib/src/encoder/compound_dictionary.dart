/// Compound (caller-attached) dictionary matching for the encoder.
///
/// The non-RFC compound dictionary extension (Rust `brotli --dictionary`,
/// `BrotliDecoderAttachDictionary`) lets a stream copy raw bytes from a
/// dictionary the caller supplies to the decoder. Distances in
/// `(maxDistance, maxDistance + dictionarySize]` address the dictionary:
///
/// * `address = dictionarySize - (distance - maxDistance)`;
/// * the command's copy length raw bytes are copied from `address`.
///
/// A dictionary reference does not update the decoder's distance ring, so a
/// rewritten parse ends with the same ring state as the parse it came from.
/// Because the static dictionary's addresses are shifted up by the compound
/// size, [applyStaticDictionaryMatches] needs that size too.
///
/// The rewritten parse is an extra candidate: the encoder serialises it and
/// keeps it only when it is smaller.
library;

import 'dart:typed_data';

import 'command.dart';

/// Shortest compound-dictionary match worth a command.
const int kMinCompoundMatchLength = 4;

/// Candidate positions kept per four-byte prefix (bounds the search).
const int _kMaxCandidatesPerKey = 8;

/// One compound-dictionary match: [length] bytes starting at [address].
final class CompoundMatch {
  const CompoundMatch(this.length, this.address);

  final int length;
  final int address;

  /// Distance to emit for this reference (always past the backward window).
  int distance(int maxBackward, int dictionarySize) =>
      maxBackward + dictionarySize - address;
}

/// Four-byte prefix index over the compound dictionary bytes.
final class CompoundDictionaryMatcher {
  CompoundDictionaryMatcher(this.dictionary, {Map<int, List<int>>? index})
    : _index = index ?? buildIndex(dictionary),
      _size = dictionary.length;

  final Uint8List dictionary;
  final Map<int, List<int>> _index;
  final int _size;

  static int _read32(Uint8List data, int offset) =>
      data[offset] |
      (data[offset + 1] << 8) |
      (data[offset + 2] << 16) |
      (data[offset + 3] << 24);

  /// Builds the four-byte-prefix index for [dictionary].
  ///
  /// Public so a `BrotliDictionary` can build it once and share it.
  static Map<int, List<int>> buildIndex(Uint8List dictionary) {
    final index = <int, List<int>>{};
    final last = dictionary.length - 4;
    for (var pos = 0; pos <= last; pos++) {
      final key = _read32(dictionary, pos);
      final list = index.putIfAbsent(key, () => <int>[]);
      // Keep the first few positions per key: deterministic and bounded.
      if (list.length < _kMaxCandidatesPerKey) list.add(pos);
    }
    return index;
  }

  /// Longest dictionary match at `input[pos ..)` covering at most [maxLength].
  ///
  /// The whole match must fit in the dictionary, so
  /// `address + length <= dictionary.length`.
  CompoundMatch? findMatch(Uint8List input, int pos, int maxLength) {
    if (maxLength < kMinCompoundMatchLength) return null;
    if (pos + 4 > input.length) return null;
    final entries = _index[_read32(input, pos)];
    if (entries == null) return null;
    CompoundMatch? best;
    for (final candidate in entries) {
      final available = _size - candidate;
      final limit = available < maxLength ? available : maxLength;
      if (limit < kMinCompoundMatchLength) continue;
      var length = 0;
      while (length < limit &&
          dictionary[candidate + length] == input[pos + length]) {
        length++;
      }
      if (length < kMinCompoundMatchLength) continue;
      if (best == null || length > best.length) {
        best = CompoundMatch(length, candidate);
      }
    }
    return best;
  }
}

/// Resolves a parameter-independent distance code against the ring [cache].
int? _resolveDistance(int code, int maxBackward, Int32List cache) {
  if (code >= 16) return code - 15;
  final candidates = <int>[
    cache[0],
    cache[1],
    cache[2],
    cache[3],
    cache[0] - 3,
    cache[0] - 2,
    cache[0] - 1,
    cache[0] + 1,
    cache[0] + 2,
    cache[0] + 3,
    cache[1] - 3,
    cache[1] - 2,
    cache[1] - 1,
    cache[1] + 1,
    cache[1] + 2,
    cache[1] + 3,
  ];
  for (final distance in candidates) {
    if (distance > 0 &&
        computeDistanceCode(distance, maxBackward, cache) == code) {
      return distance;
    }
  }
  return null;
}

/// Rewrites [commands] into [out], turning input spans that occur in the
/// compound dictionary into compound references.
///
/// Returns the number of compound references emitted. [cache] holds the
/// decoder's four-entry recent-distance ring on entry and its end state on
/// exit: the decoder rolls the ring for compound copies (unlike static words),
/// so this candidate needs its own final ring. The original parse's ring
/// evolution is tracked separately so the same match distances are preserved
/// while their codes are re-encoded for the rewritten ring.
int applyCompoundDictionaryMatches(
  Uint8List input,
  int start,
  int length,
  CommandBuffer commands,
  CommandBuffer out,
  int maxBackwardLimit,
  CompoundDictionaryMatcher matcher,
  Int32List cache,
) {
  out.clear();
  final dictionarySize = matcher.dictionary.length;
  final chainRing = Int32List.fromList(<int>[
    cache[0],
    cache[1],
    cache[2],
    cache[3],
  ]);
  var references = 0;
  var pending = 0;
  var pos = start;
  for (var i = 0; i < commands.count; i++) {
    final insertLen = commands.insertLen[i];
    final copyLen = commands.copyLen[i];
    final insertEnd = pos + insertLen;
    var cursor = pos;
    while (cursor < insertEnd) {
      final match = matcher.findMatch(input, cursor, insertEnd - cursor);
      if (match == null) {
        cursor++;
        continue;
      }
      final literals = pending + (cursor - pos);
      final maxBackward = cursor < maxBackwardLimit ? cursor : maxBackwardLimit;
      final distance = match.distance(maxBackward, dictionarySize);
      out.addCopyWithCode(literals, match.length, distance + 15);
      _push(cache, distance);
      references++;
      pending = 0;
      cursor += match.length;
      pos = cursor;
    }
    pending += insertEnd - pos;
    pos = insertEnd;
    if (copyLen != 0) {
      final maxBackward = pos < maxBackwardLimit ? pos : maxBackwardLimit;
      final distance = _resolveDistance(
        commands.distCode[i],
        maxBackward,
        chainRing,
      );
      if (distance == null) {
        out.addCopyWithCode(pending, copyLen, commands.distCode[i]);
      } else {
        final code = computeDistanceCode(distance, maxBackward, cache);
        out.addCopyWithCode(pending, copyLen, code);
        if (code > 0 && distance <= maxBackward) _push(cache, distance);
        if (commands.distCode[i] > 0 && distance <= maxBackward) {
          _push(chainRing, distance);
        }
      }
      pending = 0;
      pos += copyLen;
    }
  }
  if (pending > 0) out.addInsertOnly(pending);
  var covered = 0;
  for (var i = 0; i < out.count; i++) {
    covered += out.insertLen[i] + out.copyLen[i];
  }
  assert(covered == length, 'compound rewrite must cover the whole block');
  return references;
}

void _push(Int32List cache, int distance) {
  cache[3] = cache[2];
  cache[2] = cache[1];
  cache[1] = cache[0];
  cache[0] = distance;
}
