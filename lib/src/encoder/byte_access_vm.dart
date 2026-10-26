/// VM, AOT and dart2wasm: unaligned `ByteData` loads and 8-byte comparison.
library;

import 'dart:typed_data';

// The encoder reads the same input buffer millions of times; keep one view of
// the most recent buffer instead of creating a view per call.
Uint8List? _viewed;
ByteData _view = ByteData(0);

@pragma('vm:prefer-inline')
ByteData _viewOf(Uint8List data) {
  if (!identical(data, _viewed)) {
    _viewed = data;
    _view = ByteData.sublistView(data);
  }
  return _view;
}

/// Reads an unaligned little-endian 32-bit value.
///
/// Byte loads: for one-off reads at arbitrary positions they beat looking up
/// a `ByteData` view per call. Loops that own a view use [read32At].
@pragma('vm:prefer-inline')
int read32le(Uint8List data, int index) =>
    (data[index] | (data[index + 1] << 8)) |
    ((data[index + 2] | (data[index + 3] << 8)) << 16);

/// [read32le] through [view], a `ByteData` view of [data] held by the caller:
/// one unaligned load.
@pragma('vm:prefer-inline')
int read32At(ByteData view, Uint8List data, int index) =>
    view.getUint32(index, Endian.little);

/// Length of the common prefix of `data[a..]` and `data[b..]`, capped at
/// [limit] bytes (`FindMatchLengthWithLimit`).
///
/// Overlapping ranges are fine: the input buffer already holds the bytes the
/// decoder will reproduce, so a self-referential copy compares correctly.
@pragma('vm:prefer-inline')
int findMatchLength(Uint8List data, int a, int b, int limit) {
  final view = _viewOf(data);
  var matched = 0;
  while (limit - matched >= 8) {
    final diff =
        view.getUint64(a + matched, Endian.little) ^
        view.getUint64(b + matched, Endian.little);
    if (diff != 0) {
      // Index of the lowest differing byte. `diff & -diff` isolates the
      // lowest set bit; for bit 63 it is negative and `bitLength` reports 62,
      // which is still byte 7.
      return matched + (((diff & -diff).bitLength - 1) >> 3);
    }
    matched += 8;
  }
  while (matched < limit && data[a + matched] == data[b + matched]) {
    matched++;
  }
  return matched;
}
