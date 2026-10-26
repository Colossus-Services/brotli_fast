/// Portable 32-bit bit reader for Brotli decoding.
///
/// Brotli's bit stream is LSB-first. The reader keeps an unsigned 32-bit
/// accumulator and an input window of [BitReader.capacity] bytes followed by
/// [BitReader.slack] zero bytes that are appended once the end of the stream is
/// known. One byte value is never wider than 32 bits, so the same code is
/// correct on the VM, dart2js and dart2wasm:
///
/// * every value stays in `[0, 2^32)`;
/// * only `&` and `>>` are used - never `>>>`, never `~`, never a shift by
///   `>= 32`.
///
/// All externally visible positions ([BitReader.pos], [BitReaderMemento]) are
/// absolute stream offsets, so compacting the window never changes their
/// meaning. That is what makes the memento/restart scheme of the streaming
/// decoder safe.
///
/// The input seam is deliberately narrow ([BitReaderInput]): it hands out bytes
/// and reports whether the source is closed. The chunk queue / `Bytes` based
/// implementation can replace [Uint8ListBitReaderInput] without touching the
/// reader.
library;

import 'dart:typed_data';

import '../common/errors.dart';
import 'bit_reader_input.dart';

/// Saved [BitReader] state for cold-path restart.
///
/// The token must be released exactly once, either with [BitReader.restore]
/// (on failure, to retry the operation from its start) or with
/// [BitReader.discard] (on success). While a memento is alive the reader keeps
/// the underlying bytes around, so restoring never has to re-read input.
final class BitReaderMemento {
  BitReaderMemento._(
    this._owner,
    this._accumulator,
    this._bitOffset,
    this._absolutePosition,
  );

  final BitReader _owner;
  final int _accumulator;
  final int _bitOffset;
  final int _absolutePosition;

  bool _released = false;

  /// Absolute stream offset of the byte the accumulator position belongs to.
  int get absolutePosition => _absolutePosition;
}

/// A 32-bit portable Brotli bit reader.
final class BitReader {
  /// Size of the input window (excluding slack), in bytes.
  static const int capacity = 4096;

  /// Zero bytes appended once the end of the stream is reached.
  static const int slack = 64;

  /// Extra tail room so that wide (up to 8-byte) scratch reads stay in range.
  static const int extraSlack = 8;

  /// Total window allocation: `4096 + 64 + 8` bytes.
  static const int bufferSize = capacity + slack + extraSlack;

  /// Number of bytes that must be available ahead before a hot loop may run.
  static const int safeguard = 36;

  /// Bit masks for widths `0..32`; a table avoids the forbidden `1 << 32`.
  static const List<int> _masks = <int>[
    0x00000000, 0x00000001, 0x00000003, 0x00000007, //
    0x0000000F, 0x0000001F, 0x0000003F, 0x0000007F,
    0x000000FF, 0x000001FF, 0x000003FF, 0x000007FF,
    0x00000FFF, 0x00001FFF, 0x00003FFF, 0x00007FFF,
    0x0000FFFF, 0x0001FFFF, 0x0003FFFF, 0x0007FFFF,
    0x000FFFFF, 0x001FFFFF, 0x003FFFFF, 0x007FFFFF,
    0x00FFFFFF, 0x01FFFFFF, 0x03FFFFFF, 0x07FFFFFF,
    0x0FFFFFFF, 0x1FFFFFFF, 0x3FFFFFFF, 0x7FFFFFFF,
    0xFFFFFFFF,
  ];

  BitReader(this._input) : _buffer = Uint8List(bufferSize) {
    refill();
  }

  /// Creates a reader over a complete in-memory stream slice.
  factory BitReader.fromBytes(Uint8List bytes, {int offset = 0, int? end}) {
    return BitReader(Uint8ListBitReaderInput(bytes, offset, end));
  }

  final BitReaderInput _input;
  final Uint8List _buffer;

  /// Read cursor inside the window (bytes already pulled into the accumulator).
  int _pos = 0;

  /// Number of initialised bytes in the window (real bytes + EOF slack).
  int _limit = 0;

  /// Number of real (non-slack) bytes in the window once EOF was reached.
  int _realBytes = 0;

  /// Absolute stream bytes dropped from the front of the window.
  int _dropped = 0;

  int _accumulator = 0;
  int _bitOffset = 32;
  bool _endOfStreamReached = false;

  final List<BitReaderMemento> _mementos = <BitReaderMemento>[];
  int? _mementoFloor;

  /// The 32-bit accumulator value (bits above [bitOffset] are valid).
  int get accumulator => _accumulator;

  /// Number of consumed bits inside the accumulator, `0..32`.
  int get bitOffset => _bitOffset;

  /// Whether the source is closed and all its bytes have been seen.
  bool get endOfStreamReached => _endOfStreamReached;

  /// Absolute offset of the next byte to pull into the accumulator.
  int get pos => _dropped + _pos;

  /// Total stream length once [endOfStreamReached]; `-1` before that.
  int get tailBytes => _endOfStreamReached ? _dropped + _realBytes : -1;

  /// Real (non-slack) bytes available ahead of the read cursor.
  int get filled {
    final end = _endOfStreamReached ? _dropped + _realBytes : _dropped + _limit;
    final ahead = end - pos;
    return ahead > 0 ? ahead : 0;
  }

  /// Absolute number of bits consumed from the stream.
  ///
  /// Uses multiplication (not `<<`) so the value stays exact on dart2js even
  /// for streams larger than 512 MiB; this is a diagnostic value, not a hot
  /// loop.
  int get unusedBits => 32 - _bitOffset;

  bool get sourceClosed => _input.isClosed;

  @pragma('vm:prefer-inline')
  bool get hasSafeguard => _limit - _pos >= safeguard;

  int get consumedBits => pos * 8 - 32 + _bitOffset;

  /// Absolute number of bytes touched (rounded up) by the bit cursor.
  int get bytesConsumed => (consumedBits + 7) ~/ 8;

  /// Number of mementos that have not been restored or discarded yet.
  int get activeMementoCount => _mementos.length;

  /// Refills the input window when fewer than [safeguard] bytes are available.
  ///
  /// This is Java's `BitReader.readMoreInput`: it compacts the window (keeping
  /// any bytes an outstanding memento still needs), pulls input and appends the
  /// zero slack at end of stream.
  ///
  /// Returns `false` only while the source is still open and fewer than
  /// [safeguard] bytes could be loaded. The caller should then suspend
  /// (`needMoreInput`). At end of stream `true` is returned; reading past the
  /// real end is reported by [checkHealth] / a later [refill].
  bool refill() {
    if (_endOfStreamReached) {
      if (bytesConsumed > _dropped + _realBytes) {
        throw BrotliException(
          BrotliErrorCode.truncatedInput,
          'bit reader consumed past the end of the stream',
          inputOffset: _dropped + _realBytes,
        );
      }
      return true;
    }
    if (_limit - _pos >= safeguard) {
      return true;
    }
    _compact();
    var sourceExhausted = false;
    while (_limit < capacity) {
      final count = _input.readInto(_buffer, _limit, capacity - _limit);
      if (count <= 0) {
        sourceExhausted = true;
        break;
      }
      _limit += count;
    }
    if (sourceExhausted && _input.isClosed) {
      // All available bytes are in the window: append the zero slack now, even
      // when enough are already buffered. This makes `endOfStreamReached`
      // visible as soon as the stream is known to be complete.
      _endOfStreamReached = true;
      _realBytes = _limit;
      _limit = _realBytes + slack + extraSlack;
      _buffer.fillRange(_realBytes, _limit, 0);
      return true;
    }
    return _limit - _pos >= safeguard;
  }

  /// Compacts the window, preserving bytes required by live mementos.
  void _compact() {
    var keep = _pos;
    final floor = _mementoFloor;
    if (floor != null) {
      final relative = floor - _dropped;
      assert(relative >= 0, 'memento position was already dropped');
      if (relative < keep) {
        keep = relative;
      }
    }
    if (keep <= 0) {
      return;
    }
    final remaining = _limit - keep;
    if (remaining > 0) {
      _buffer.setRange(0, remaining, _buffer, keep);
    }
    _pos -= keep;
    _dropped += keep;
    _limit = remaining;
  }

  /// Fills the accumulator so that [bitOffset] becomes `< 16`.
  ///
  /// Callers normally invoke [refill] first; this function only moves bytes
  /// that are already inside the window.
  void fillBitWindow() {
    assert(_bitOffset <= 32);
    while (_bitOffset >= 16) {
      if (_pos + 1 >= _limit) {
        // Only possible when the zero slack is exhausted, i.e. the reader was
        // asked to consume more bits than the stream contains.
        assert(
          _endOfStreamReached,
          'fillBitWindow() without a successful refill()',
        );
        return;
      }
      final half = _buffer[_pos] | (_buffer[_pos + 1] << 8);
      _pos += 2;
      _accumulator = ((_accumulator >> 16) | (half << 16)) & 0xFFFFFFFF;
      _bitOffset -= 16;
    }
  }

  /// Loads the accumulator and returns `false` if more input is required.
  ///
  /// Mirrors Java's `BitReader.reload`: used after a raw-byte copy to make the
  /// bit accumulator usable again.
  bool reload() {
    if (_bitOffset != 32) {
      return true;
    }
    if (!refill()) {
      return false;
    }
    fillBitWindow();
    return true;
  }

  /// Returns at most [n] bits without consuming them.
  ///
  /// The accumulator must hold the bits: call [fillBitWindow] first.
  int peekBits(int n) {
    assert(n >= 0 && n <= 32);
    assert(_bitOffset + n <= 32, 'peekBits($n) underflowed the accumulator');
    return (_accumulator >> _bitOffset) & _masks[n];
  }

  /// Consumes [n] bits.
  void dropBits(int n) {
    assert(n >= 0);
    assert(_bitOffset + n <= 32, 'dropBits($n) underflowed the accumulator');
    _bitOffset += n;
  }

  /// Reads `n <= 16` bits (the raw, unchecked primitive).
  ///
  /// The accumulator must hold at least [n] unused bits; call
  /// [fillBitWindow] first.
  int readFewBits(int n) {
    assert(n >= 0 && n <= 16);
    assert(_bitOffset + n <= 32, 'readFewBits($n) underflowed the accumulator');
    final value = (_accumulator >> _bitOffset) & _masks[n];
    _bitOffset += n;
    return value;
  }

  /// Reads [n] bits, `0..32`.
  ///
  /// For `n > 16` it uses the two-step form (`readFewBits(16)`, refill the
  /// accumulator, `readFewBits(n - 16)`). The accumulator must hold at least
  /// `min(n, 16)` bits; call [fillBitWindow] first.
  int readBits(int n) {
    assert(n >= 0 && n <= 32);
    if (n <= 16) {
      return readFewBits(n);
    }
    final low = readFewBits(16);
    fillBitWindow();
    final high = readFewBits(n - 16);
    return low | (high << 16);
  }

  /// Reads up to 32 bits; needed by large-window distances (25..32 bits).
  ///
  /// Identical to [readBits] but spells out the wide-range contract.
  int readBitsUpTo32(int n) {
    assert(n >= 0 && n <= 32);
    return readBits(n);
  }

  /// Advances to the next byte boundary and verifies zero padding bits.
  ///
  /// Throws [BrotliErrorCode.corruptPadding] when a skipped bit is set.
  void jumpToByteBoundary() {
    final padding = (32 - _bitOffset) & 7;
    if (padding != 0) {
      final paddingBits = readFewBits(padding);
      if (paddingBits != 0) {
        throw BrotliException(
          BrotliErrorCode.corruptPadding,
          'non-zero padding bits at byte boundary',
          inputOffset: bytesConsumed,
        );
      }
    }
  }

  /// Copies raw (uncompressed) bytes out of the stream.
  ///
  /// This is a staged raw copy: only bytes that are already available are
  /// copied, so the caller can resume after [refill] returns. Returns the
  /// number of bytes copied (`0` when nothing is available right now).
  ///
  /// The reader must be byte-aligned (see [jumpToByteBoundary]), otherwise a
  /// [BrotliErrorCode.internalError] is thrown.
  int copyRawBytes(Uint8List destination, int destinationOffset, int length) {
    if (length == 0) {
      return 0;
    }
    if ((_bitOffset & 7) != 0) {
      throw BrotliException(
        BrotliErrorCode.internalError,
        'copyRawBytes requires a byte-aligned bit reader',
      );
    }
    RangeError.checkValidRange(
      destinationOffset,
      destinationOffset + length,
      destination.length,
    );
    final totalReal = _endOfStreamReached ? _dropped + _realBytes : -1;
    var written = 0;
    // Drain whole bytes sitting in the accumulator.
    while (_bitOffset != 32 && written < length) {
      if (totalReal >= 0 && bytesConsumed >= totalReal) {
        break;
      }
      destination[destinationOffset + written] =
          (_accumulator >> _bitOffset) & 0xFF;
      _bitOffset += 8;
      written++;
    }
    if (written == length) {
      return written;
    }
    // Copy from the window.
    final available = _availableWindowBytes;
    final wanted = length - written;
    final count = wanted < available ? wanted : available;
    if (count > 0) {
      destination.setRange(
        destinationOffset + written,
        destinationOffset + written + count,
        _buffer,
        _pos,
      );
      _pos += count;
      written += count;
    }
    return written;
  }

  /// Skips [length] raw bytes without copying them.
  ///
  /// Like [copyRawBytes], only currently available bytes are skipped.
  int skipRawBytes(int length) {
    if (length == 0) {
      return 0;
    }
    if ((_bitOffset & 7) != 0) {
      throw BrotliException(
        BrotliErrorCode.internalError,
        'skipRawBytes requires a byte-aligned bit reader',
      );
    }
    final totalReal = _endOfStreamReached ? _dropped + _realBytes : -1;
    var skipped = 0;
    while (_bitOffset != 32 && skipped < length) {
      if (totalReal >= 0 && bytesConsumed >= totalReal) {
        break;
      }
      _bitOffset += 8;
      skipped++;
    }
    if (skipped == length) {
      return skipped;
    }
    final available = _availableWindowBytes;
    final wanted = length - skipped;
    final count = wanted < available ? wanted : available;
    _pos += count;
    return skipped + count;
  }

  /// Real bytes in the window that start at [pos] (never includes EOF slack).
  int get _availableWindowBytes {
    final end = _endOfStreamReached ? _dropped + _realBytes : _dropped + _limit;
    final ahead = end - pos;
    return ahead > 0 ? ahead : 0;
  }

  /// Saves the reader state for a cold-path restart.
  ///
  /// Operations that use a memento must be side-effect free until they commit
  /// and must consume less than [capacity] bytes of input, otherwise the
  /// reader may be unable to compact while the memento is alive.
  BitReaderMemento save() {
    final memento = BitReaderMemento._(this, _accumulator, _bitOffset, pos);
    _mementos.add(memento);
    final floor = _mementoFloor;
    if (floor == null || memento.absolutePosition < floor) {
      _mementoFloor = memento.absolutePosition;
    }
    return memento;
  }

  /// Restores the state saved by [save] and releases the memento.
  ///
  /// Throws [StateError] if the token was already released or if the bytes the
  /// memento needs are no longer in the window (a reader bug).
  void restore(BitReaderMemento memento) {
    if (!identical(memento._owner, this)) {
      throw StateError('memento belongs to a different BitReader');
    }
    if (memento._released) {
      throw StateError('memento was already released');
    }
    _release(memento);
    final relative = memento._absolutePosition - _dropped;
    if (relative < 0 || relative > _limit) {
      throw StateError(
        'memento position ${memento._absolutePosition} is outside the window',
      );
    }
    _accumulator = memento._accumulator;
    _bitOffset = memento._bitOffset;
    _pos = relative;
  }

  /// Releases a memento without restoring (the operation succeeded).
  void discard(BitReaderMemento memento) {
    if (!identical(memento._owner, this)) {
      throw StateError('memento belongs to a different BitReader');
    }
    if (memento._released) {
      return;
    }
    _release(memento);
  }

  void _release(BitReaderMemento memento) {
    memento._released = true;
    _mementos.remove(memento);
    int? floor;
    for (final active in _mementos) {
      final position = active._absolutePosition;
      if (floor == null || position < floor) {
        floor = position;
      }
    }
    _mementoFloor = floor;
  }

  /// Validates that the reader stayed inside the real stream.
  ///
  /// Call at every committed boundary while [endOfStreamReached] is known; with
  /// [endOfStream] set the stream must also be fully consumed. Throws
  /// [BrotliErrorCode.readAfterEnd] or
  /// [BrotliErrorCode.unusedBytesAfterEnd].
  void checkHealth([bool endOfStream = false]) {
    if (!_endOfStreamReached) {
      return;
    }
    final total = _dropped + _realBytes;
    final consumed = bytesConsumed;
    if (consumed > total) {
      throw BrotliException(
        BrotliErrorCode.readAfterEnd,
        'read past end of stream: consumed $consumed of $total bytes',
        inputOffset: total,
      );
    }
    if (endOfStream && consumed != total) {
      throw BrotliException(
        BrotliErrorCode.unusedBytesAfterEnd,
        'stream ended with ${total - consumed} unused bytes',
        inputOffset: consumed,
      );
    }
  }

  /// 32-bit fallback of the literal run (no accumulator locals because the
  /// Web backend keeps the portable 32-bit contract).
  int decodeLiteralRun(
    Uint8List ring,
    int mask,
    int pos,
    int count,
    Uint32List group,
    int treeBase,
    bool trivialContext,
    Uint32List baseByContext,
    int lookupOffset1,
    int lookupOffset2,
    Uint8List contextLookup,
  ) {
    var cursor = pos;
    if (trivialContext) {
      for (var i = 0; i < count; i++) {
        fillBitWindow();
        var bits = peekBits(15);
        var offset = treeBase + (bits & 0xFF);
        var entry = group[offset];
        var rootLength = entry >> 16;
        var symbol = entry & 0xFFFF;
        if (rootLength > 8) {
          final mask15 = (1 << rootLength) - 1;
          offset += symbol + ((bits & mask15) >> 8);
          entry = group[offset];
          dropBits((entry >> 16) + 8);
          symbol = entry & 0xFFFF;
        } else {
          dropBits(rootLength);
        }
        ring[cursor++] = symbol;
      }
    } else {
      var prev1 = ring[(pos - 1) & mask] & 0xFF;
      var prev2 = ring[(pos - 2) & mask] & 0xFF;
      for (var i = 0; i < count; i++) {
        final context =
            contextLookup[lookupOffset1 + prev1] |
            contextLookup[lookupOffset2 + prev2];
        final base = baseByContext[context];
        prev2 = prev1;
        fillBitWindow();
        var bits = peekBits(15);
        var offset = base + (bits & 0xFF);
        var entry = group[offset];
        var rootLength = entry >> 16;
        var symbol = entry & 0xFFFF;
        if (rootLength > 8) {
          final mask15 = (1 << rootLength) - 1;
          offset += symbol + ((bits & mask15) >> 8);
          entry = group[offset];
          dropBits((entry >> 16) + 8);
          symbol = entry & 0xFFFF;
        } else {
          dropBits(rootLength);
        }
        prev1 = symbol;
        ring[cursor++] = symbol;
      }
    }
    return cursor - pos;
  }

  @override
  String toString() {
    return 'BitReader(pos: $pos, bitOffset: $_bitOffset, '
        'filled: $filled, eof: $_endOfStreamReached)';
  }
}
