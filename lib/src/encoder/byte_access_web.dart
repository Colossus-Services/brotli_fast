/// dart2js: byte-assembled 32-bit reads (no 64-bit `ByteData` accessors).
library;

import 'dart:typed_data';

/// Reads an unaligned little-endian 32-bit value.
@pragma('dart2js:prefer-inline')
int read32le(Uint8List data, int index) {
  final lo = data[index] | (data[index + 1] << 8);
  final hi = data[index + 2] | (data[index + 3] << 8);
  return lo | (hi << 16);
}

/// [read32le] for callers holding a `ByteData` view of [data]; dart2js keeps
/// the byte-assembled read.
@pragma('dart2js:prefer-inline')
int read32At(ByteData view, Uint8List data, int index) => read32le(data, index);

/// Length of the common prefix of `data[a..]` and `data[b..]`, capped at
/// [limit] bytes (`FindMatchLengthWithLimit`).
///
/// Overlapping ranges are fine: the input buffer already holds the bytes the
/// decoder will reproduce, so a self-referential copy compares correctly.
@pragma('dart2js:prefer-inline')
int findMatchLength(Uint8List data, int a, int b, int limit) {
  var matched = 0;
  while (limit - matched >= 4) {
    if (read32le(data, a + matched) != read32le(data, b + matched)) break;
    matched += 4;
  }
  while (matched < limit && data[a + matched] == data[b + matched]) {
    matched++;
  }
  return matched;
}
