/// LSB-first bit writer for the encoder.
library;

import 'dart:typed_data';

import '../common/bit_utils.dart';

/// Writes bits, least significant bit first, into a growable byte buffer.
///
/// Only complete bytes are stored in the buffer; up to 7 pending bits live in
/// an accumulator. That keeps [mark]/[rewind] exact, which the encoder uses to
/// try several meta-block encodings and keep the smallest.
final class BitWriter {
  /// Creates a writer with room for [initialCapacity] bytes.
  BitWriter({int initialCapacity = 256})
    : _buffer = Uint8List(initialCapacity < 16 ? 16 : initialCapacity);

  Uint8List _buffer;
  int _length = 0; // complete bytes stored
  int _acc = 0; // pending bits, bit 0 = oldest
  int _accBits = 0; // pending bit count, 0..7 between calls

  /// Total number of bits written so far.
  int get bitPosition => _length * 8 + _accBits;

  /// Current position, for [rewind].
  int mark() => bitPosition;

  /// Writes the low [count] bits of [value]; [count] must be `0..32` and
  /// [value] must fit in [count] bits.
  @pragma('vm:prefer-inline')
  void writeBits(int count, int value) {
    if (count == 0) return;
    // dart2js shifts are 32-bit: write wide values in 16-bit pieces.
    if (jsNumbers) {
      var remaining = count;
      var consumed = 0;
      while (remaining > 0) {
        final take = remaining > 16 ? 16 : remaining;
        _push(take, (value >> consumed) & ((1 << take) - 1));
        consumed += take;
        remaining -= take;
      }
    } else {
      _push(count, value & (count >= 32 ? 0xFFFFFFFF : (1 << count) - 1));
    }
  }

  @pragma('vm:prefer-inline')
  void _push(int count, int value) {
    _acc |= value << _accBits;
    _accBits += count;
    while (_accBits >= 8) {
      _ensure(1);
      _buffer[_length++] = _acc & 0xFF;
      _acc >>= 8;
      _accBits -= 8;
    }
  }

  /// Pads with zero bits to the next byte boundary.
  void alignToByte() {
    if (_accBits == 0) return;
    _ensure(1);
    _buffer[_length++] = _acc & 0xFF;
    _acc = 0;
    _accBits = 0;
  }

  /// Appends `data[start..end)`; the writer must be byte-aligned.
  void writeBytes(Uint8List data, int start, int end) {
    assert(_accBits == 0, 'writeBytes needs a byte boundary');
    final count = end - start;
    if (count <= 0) return;
    _ensure(count);
    _buffer.setRange(_length, _length + count, data, start);
    _length += count;
  }

  /// Discards every bit written after [position] (a value from [mark]).
  void rewind(int position) {
    assert(position >= 0 && position <= bitPosition, 'rewind out of range');
    final byteIndex = position >> 3;
    final bits = position & 7;
    if (bits == 0) {
      _acc = 0;
    } else if (byteIndex < _length) {
      // The partial byte was already stored; pull back its low bits.
      _acc = _buffer[byteIndex] & ((1 << bits) - 1);
    } else {
      // The partial byte never left the accumulator.
      _acc &= (1 << bits) - 1;
    }
    _length = byteIndex;
    _accBits = bits;
  }

  /// The written bytes, zero-padded to a whole byte. A view of the internal
  /// buffer when no padding is needed: do not write afterwards.
  Uint8List toBytes() {
    if (_accBits == 0) return Uint8List.sublistView(_buffer, 0, _length);
    final out = Uint8List(_length + 1)..setRange(0, _length, _buffer);
    out[_length] = _acc & 0xFF;
    return out;
  }

  /// Removes and returns the complete bytes written so far (streaming); the
  /// pending sub-byte bits stay in the writer.
  Uint8List takeCompleteBytes() {
    final out = Uint8List.fromList(Uint8List.sublistView(_buffer, 0, _length));
    _length = 0;
    return out;
  }

  void _ensure(int extra) {
    final needed = _length + extra;
    if (needed <= _buffer.length) return;
    var capacity = _buffer.length;
    while (capacity < needed) {
      capacity *= 2;
    }
    _buffer = Uint8List(capacity)..setRange(0, _length, _buffer);
  }
}
