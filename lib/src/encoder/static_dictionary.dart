/// RFC 7932 static dictionary matching for the encoder.
///
/// The decoder already knows the 122,784-byte dictionary and its 121 transforms;
/// this file is the search side. It builds a hash index over the dictionary
/// words (four-byte prefix) once, lazily, and rewrites a parsed command stream
/// so that literal runs containing dictionary words become dictionary
/// references:
///
/// * only the length-preserving transforms are used - identity (0), uppercase
///   first (9) and uppercase all (44) - which is exactly the transform set the
///   reference hashes for the static dictionary (`IsMatch` in `static_dict.c`);
///   the copy length therefore equals the number of bytes covered, so the
///   command stream accounting stays unchanged;
/// * a dictionary reference is emitted as a distance beyond the block's
///   `maxDistance`: `distance = maxDistance + 1 + address` with
///   `address = transform << sizeBits[wordLength] | wordIndex`;
/// * dictionary copies do not touch the distance cache (RFC 7932 §8), so the
///   rewritten parse ends with the same cache state as the parse it came from.
///
/// The rewrite is an *extra* candidate: the encoder serialises it and keeps it
/// only when it is smaller, so it can never enlarge a block.
library;

import 'dart:typed_data';

import '../common/dictionary.dart';
import '../common/dictionary_data.dart';
import 'command.dart';

/// Smallest dictionary word length (`sizeBits[4] != 0`).
const int kMinDictionaryWordLength = 4;

/// Longest dictionary word length.
const int kMaxDictionaryWordLength = 24;

/// RFC transform index of uppercase first (verified against
/// 	ransformDictionaryWord: bout -> About).
const int _kUppercaseFirst = 9;

/// RFC transform index of uppercase all (bout -> ABOUT).
const int _kUppercaseAll = 44;

/// Shortest match worth emitting as a dictionary reference.
///
/// A reference costs a command symbol plus a wide distance (roughly 30 bits),
/// so words shorter than this rarely beat plain literals.
const int kMinDictionaryMatchLength = 6;

/// One dictionary reference: [length] covered bytes, [address] (word + transform).
final class DictionaryMatch {
  const DictionaryMatch(this.length, this.address);

  final int length;
  final int address;

  /// Distance to emit for this reference (never a backward distance).
  int distance(int maxBackward) => maxBackward + 1 + address;
}

/// Dictionary word index keyed by the first four bytes of each word.
final class StaticDictionaryMatcher {
  StaticDictionaryMatcher._(this._index);

  static StaticDictionaryMatcher? _instance;

  /// The lazily built singleton.
  static StaticDictionaryMatcher get instance =>
      _instance ??= StaticDictionaryMatcher._(_buildIndex());

  /// Key (first four bytes) -> packed `(length, wordIndex, transform)` entries.
  final Map<int, List<int>> _index;

  // 5 bits length, 10 bits word index (largest group is 1024), 6 bits transform.
  static int _pack(int length, int index, int transform) =>
      (length << 16) | (index << 6) | transform;

  static int _read32(Uint8List data, int offset) =>
      data[offset] |
      (data[offset + 1] << 8) |
      (data[offset + 2] << 16) |
      (data[offset + 3] << 24);

  static Map<int, List<int>> _buildIndex() {
    final index = <int, List<int>>{};
    final data = kDictionaryData;
    for (
      var length = kMinDictionaryWordLength;
      length <= kMaxDictionaryWordLength;
      length++
    ) {
      final bits = kDictionarySizeBitsByLength[length];
      if (bits == 0) continue;
      final count = 1 << bits;
      final base = dictionaryWordOffset(length, 0);
      for (var word = 0; word < count; word++) {
        final offset = base + word * length;
        final key = _read32(data, offset);
        // Identity plus the two ASCII uppercase transforms.
        _add(index, key, _pack(length, word, 0));
        var lower = data[offset] >= 0x61 && data[offset] <= 0x7A;
        var allLowerOrOther = true;
        for (var i = 0; i < length; i++) {
          final c = data[offset + i];
          if (c >= 0x61 && c <= 0x7A) {
            // lowercase: fine for both uppercase transforms
          } else if (c >= 0x80) {
            allLowerOrOther = false;
            break;
          }
          if (i == 0) lower = lower;
        }
        if (lower) _add(index, key, _pack(length, word, _kUppercaseFirst));
        if (lower && allLowerOrOther) {
          _add(index, key, _pack(length, word, _kUppercaseAll));
        }
      }
    }
    return index;
  }

  static void _add(Map<int, List<int>> index, int key, int entry) {
    index.putIfAbsent(key, () => <int>[]).add(entry);
  }

  /// Longest dictionary match at [pos] (`input[pos .. pos + length)`), or null.
  ///
  /// [maxLength] is the number of input bytes available at [pos]; the returned
  /// match never covers more than [maxLength] bytes and is at least
  /// [kMinDictionaryMatchLength] long.
  DictionaryMatch? findMatch(Uint8List input, int pos, int maxLength) {
    final limit = maxLength < kMaxDictionaryWordLength
        ? maxLength
        : kMaxDictionaryWordLength;
    if (limit < kMinDictionaryWordLength) return null;
    if (pos + 4 > input.length) return null;
    final entries = _index[_read32(input, pos)];
    if (entries == null) return null;
    final data = kDictionaryData;
    DictionaryMatch? best;
    for (final entry in entries) {
      final transform = entry & 0x3F;
      final word = (entry >> 6) & 0x3FF;
      final length = entry >> 16;
      if (length > limit) continue;
      if (best != null && length < best.length) continue;
      final offset = dictionaryWordOffset(length, word);
      var ok = true;
      for (var i = 0; i < length; i++) {
        final expected = data[offset + i];
        final actual = input[pos + i];
        final isLower = expected >= 0x61 && expected <= 0x7A;
        final uppercased = isLower && (expected ^ 32) == actual;
        switch (transform) {
          case 0:
            ok = expected == actual;
          case _kUppercaseFirst:
            // First byte is uppercased (only for a lowercase word), the rest
            // must match exactly.
            ok = i == 0 ? uppercased : expected == actual;
          case _kUppercaseAll:
            // Every ASCII lowercase letter is uppercased.
            ok = isLower ? uppercased : expected == actual;
          default:
            ok = false;
        }
        if (!ok) break;
      }
      if (!ok) continue;
      final shift = kDictionarySizeBitsByLength[length];
      final address = (transform << shift) | word;
      if (best == null ||
          length > best.length ||
          (length == best.length && address < best.address)) {
        best = DictionaryMatch(length, address);
      }
    }
    if (best == null || best.length < kMinDictionaryMatchLength) return null;
    return best;
  }
}

/// Rewrites [commands] into [out], turning dictionary words inside literal runs
/// into dictionary references.
///
/// Returns the number of dictionary references emitted. The input bytes are
/// `input[start .. start + length)`; [maxBackwardLimit] is the window bound
/// (`(1 << lgwin) - 16`). The rewritten stream covers exactly the same bytes.
/// Regular copies keep their parameter-independent distance code, and because
/// dictionary copies leave the distance cache alone the resulting parse ends
/// with the same decoder cache state as [commands].
int applyStaticDictionaryMatches(
  Uint8List input,
  int start,
  int length,
  CommandBuffer commands,
  CommandBuffer out,
  int maxBackwardLimit, {
  int compoundSize = 0,
}) {
  out.clear();
  final end = start + length;
  assert(end >= start);
  final matcher = StaticDictionaryMatcher.instance;
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
      // With a compound dictionary attached the static dictionary addresses
      // are shifted up by its size.
      final distanceCode = match.distance(maxBackward) + compoundSize + 15;
      out.addCopyWithCode(literals, match.length, distanceCode);
      references++;
      pending = 0;
      cursor += match.length;
      pos = cursor;
    }
    pending += insertEnd - pos;
    pos = insertEnd;
    if (copyLen != 0) {
      out.addCopyWithCode(pending, copyLen, commands.distCode[i]);
      pending = 0;
      pos += copyLen;
    }
  }
  if (pending > 0) {
    out.addInsertOnly(pending);
  }
  var covered = 0;
  for (var i = 0; i < out.count; i++) {
    covered += out.insertLen[i] + out.copyLen[i];
  }
  assert(covered == length, 'dictionary rewrite must cover the whole block');
  return references;
}
