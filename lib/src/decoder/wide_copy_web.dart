/// Web wide copy: 32-bit `ByteData` accesses (dart2js supports these).
library;

import 'dart:typed_data';

/// Copies [length] bytes in [ring] from [src] to [dst].
///
/// The caller guarantees `dst > src` and `dst - src >= 8`, so 4-byte forward
/// accesses never read unwritten bytes.
void copyOverlappingWide(
  ByteData data,
  Uint8List ring,
  int dst,
  int src,
  int length,
) {
  var i = 0;
  while (i + 16 <= length) {
    final d0 = dst + i;
    final s0 = src + i;
    data.setUint32(d0, data.getUint32(s0, Endian.little), Endian.little);
    data.setUint32(
      d0 + 4,
      data.getUint32(s0 + 4, Endian.little),
      Endian.little,
    );
    data.setUint32(
      d0 + 8,
      data.getUint32(s0 + 8, Endian.little),
      Endian.little,
    );
    data.setUint32(
      d0 + 12,
      data.getUint32(s0 + 12, Endian.little),
      Endian.little,
    );
    i += 16;
  }
  while (i + 4 <= length) {
    data.setUint32(
      dst + i,
      data.getUint32(src + i, Endian.little),
      Endian.little,
    );
    i += 4;
  }
  while (i < length) {
    ring[dst + i] = ring[src + i];
    i++;
  }
}
