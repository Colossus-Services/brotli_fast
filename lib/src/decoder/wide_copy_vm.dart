/// VM/AOT wide copy: 64-bit `ByteData` accesses.
library;

import 'dart:typed_data';

/// Copies [length] bytes in [ring] from [src] to [dst].
///
/// The caller guarantees `dst > src` and `dst - src >= 8`, so an 8-byte forward
/// load never reads a byte that has not been written yet.
void copyOverlappingWide(
  ByteData data,
  Uint8List ring,
  int dst,
  int src,
  int length,
) {
  var i = 0;
  while (i + 32 <= length) {
    final d0 = dst + i;
    final s0 = src + i;
    data.setUint64(d0, data.getUint64(s0, Endian.little), Endian.little);
    data.setUint64(
      d0 + 8,
      data.getUint64(s0 + 8, Endian.little),
      Endian.little,
    );
    data.setUint64(
      d0 + 16,
      data.getUint64(s0 + 16, Endian.little),
      Endian.little,
    );
    data.setUint64(
      d0 + 24,
      data.getUint64(s0 + 24, Endian.little),
      Endian.little,
    );
    i += 32;
  }
  while (i + 8 <= length) {
    data.setUint64(
      dst + i,
      data.getUint64(src + i, Endian.little),
      Endian.little,
    );
    i += 8;
  }
  while (i < length) {
    ring[dst + i] = ring[src + i];
    i++;
  }
}
