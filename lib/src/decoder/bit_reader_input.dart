/// Narrow input seam shared by the 64-bit (VM/AOT) and 32-bit (Web) readers.
library;

import 'dart:typed_data';

/// Input source for a [BitReader].
///
/// Implementations copy at most `length` bytes per call and return `0` when no
/// bytes are available *right now*. [isClosed] distinguishes "the producer is
/// temporarily empty" (decoder should return `needMoreInput`) from "end of
/// stream".
abstract interface class BitReaderInput {
  int readInto(Uint8List destination, int offset, int length);
  bool get isClosed;
}

/// [BitReaderInput] over a `Uint8List` slice; it is always closed.
final class Uint8ListBitReaderInput implements BitReaderInput {
  Uint8ListBitReaderInput(this.bytes, [this._offset = 0, int? end])
    : _end = end ?? bytes.length {
    RangeError.checkValidRange(_offset, _end, bytes.length);
  }

  final Uint8List bytes;
  final int _end;
  int _offset;

  @override
  int readInto(Uint8List destination, int offset, int length) {
    final available = _end - _offset;
    if (available <= 0 || length <= 0) {
      return 0;
    }
    final count = available < length ? available : length;
    destination.setRange(offset, offset + count, bytes, _offset);
    _offset += count;
    return count;
  }

  @override
  bool get isClosed => true;
}
