/// 64-bit Brotli bit reader for the VM, AOT and dart2wasm.
///
/// Same contract as the 32-bit reader (`bit_reader_32.dart`), but the
/// accumulator holds up to 64 bits and refills 32 bits at a time with a single
/// [ByteData.getUint32]. That removes the 32-bit splitting (`readFewBits(16)`
/// + refill + `readFewBits`) from every wide read, which is the dominant
/// hot-loop cost of the 32-bit reader.
///
/// Web builds use `bit_reader_32.dart` through the conditional export in
/// `bit_reader.dart`; this file must not be compiled for dart2js/dart2wasm.
library;

import 'dart:typed_data';

import '../common/errors.dart';
import 'bit_reader_input.dart';

/// Saved [BitReader] state for cold-path restart.
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

  int get absolutePosition => _absolutePosition;
}

/// 64-bit portable Brotli bit reader (VM/AOT only).
final class BitReader {
  /// Size of the input window (excluding slack), in bytes.
  static const int capacity = 4096;

  /// Zero bytes appended once the end of the stream is reached.
  static const int slack = 64;

  /// Extra tail room so wide scratch reads stay in range.
  static const int extraSlack = 8;

  /// Total window allocation.
  static const int bufferSize = capacity + slack + extraSlack;

  /// Bytes that must be available ahead before a hot loop may run.
  static const int safeguard = 36;

  /// Bit masks for widths `0..32`.
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
    _view = ByteData.sublistView(_buffer);
    refill();
  }

  factory BitReader.fromBytes(Uint8List bytes, {int offset = 0, int? end}) {
    return BitReader(Uint8ListBitReaderInput(bytes, offset, end));
  }

  final BitReaderInput _input;
  final Uint8List _buffer;
  late final ByteData _view;

  int _pos = 0;
  int _limit = 0;
  int _realBytes = 0;
  int _dropped = 0;
  int _accumulator = 0;
  int _bitOffset = 64;
  bool _endOfStreamReached = false;

  final List<BitReaderMemento> _mementos = <BitReaderMemento>[];
  int? _mementoFloor;

  int get accumulator => _accumulator;
  int get bitOffset => _bitOffset;
  bool get endOfStreamReached => _endOfStreamReached;
  int get pos => _dropped + _pos;
  int get tailBytes => _endOfStreamReached ? _dropped + _realBytes : -1;

  int get filled {
    final end = _endOfStreamReached ? _dropped + _realBytes : _dropped + _limit;
    final ahead = end - pos;
    return ahead > 0 ? ahead : 0;
  }

  int get consumedBits => pos * 8 - 64 + _bitOffset;

  /// Bits already inside the accumulator and not yet consumed.
  int get unusedBits => 64 - _bitOffset;

  /// Whether the input source can never produce more bytes.
  bool get sourceClosed => _input.isClosed;

  /// Whether the window already has the hot-loop safeguard bytes.
  @pragma('vm:prefer-inline')
  bool get hasSafeguard => _limit - _pos >= safeguard;
  int get bytesConsumed => (consumedBits + 7) ~/ 8;
  int get activeMementoCount => _mementos.length;

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
      _endOfStreamReached = true;
      _realBytes = _limit;
      _limit = _realBytes + slack + extraSlack;
      _buffer.fillRange(_realBytes, _limit, 0);
      return true;
    }
    return _limit - _pos >= safeguard;
  }

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

  /// Loads 32-bit halves until fewer than 32 bits are consumed.
  ///
  /// The VM inlines this in the symbol loops.
  @pragma('vm:prefer-inline')
  void fillBitWindow() {
    while (_bitOffset >= 32) {
      if (_pos + 3 >= _limit) {
        assert(
          _endOfStreamReached,
          'fillBitWindow() without a successful refill()',
        );
        return;
      }
      final word = _view.getUint32(_pos, Endian.little);
      _pos += 4;
      _accumulator = (_accumulator >>> 32) | (word << 32);
      _bitOffset -= 32;
    }
  }

  bool reload() {
    if (_bitOffset != 64) {
      return true;
    }
    if (!refill()) {
      return false;
    }
    fillBitWindow();
    return true;
  }

  @pragma('vm:prefer-inline')
  int peekBits(int n) {
    assert(n >= 0 && n <= 32);
    assert(_bitOffset + n <= 64, 'peekBits($n) underflowed the accumulator');
    return (_accumulator >>> _bitOffset) & _masks[n];
  }

  @pragma('vm:prefer-inline')
  void dropBits(int n) {
    assert(n >= 0);
    assert(_bitOffset + n <= 64, 'dropBits($n) underflowed the accumulator');
    _bitOffset += n;
  }

  @pragma('vm:prefer-inline')
  int readFewBits(int n) {
    assert(n >= 0 && n <= 32);
    assert(_bitOffset + n <= 64, 'readFewBits($n) underflowed the accumulator');
    final value = (_accumulator >>> _bitOffset) & _masks[n];
    _bitOffset += n;
    return value;
  }

  @pragma('vm:prefer-inline')
  int readBits(int n) {
    assert(n >= 0 && n <= 32);
    return readFewBits(n);
  }

  int readBitsUpTo32(int n) => readBits(n);

  void jumpToByteBoundary() {
    final padding = (64 - _bitOffset) & 7;
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
    while (_bitOffset != 64 && written < length) {
      if (totalReal >= 0 && bytesConsumed >= totalReal) {
        break;
      }
      destination[destinationOffset + written] =
          (_accumulator >>> _bitOffset) & 0xFF;
      _bitOffset += 8;
      written++;
    }
    if (written == length) {
      return written;
    }
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
    while (_bitOffset != 64 && skipped < length) {
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

  int get _availableWindowBytes {
    final end = _endOfStreamReached ? _dropped + _realBytes : _dropped + _limit;
    final ahead = end - pos;
    return ahead > 0 ? ahead : 0;
  }

  BitReaderMemento save() {
    final memento = BitReaderMemento._(this, _accumulator, _bitOffset, pos);
    _mementos.add(memento);
    final floor = _mementoFloor;
    if (floor == null || memento.absolutePosition < floor) {
      _mementoFloor = memento.absolutePosition;
    }
    return memento;
  }

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

  /// Decodes [count] literals in one tight loop with the accumulator held in
  /// locals. The caller must have called [refill] and [fillBitWindow] and must
  /// have bounded [count] so enough bits/bytes are buffered (same contract as
  /// the fast literal run in `decoder_metablock.dart`).
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
    var accumulator = _accumulator;
    var bitOffset = _bitOffset;
    var windowPos = _pos;
    final view = _view;
    var cursor = pos;
    if (trivialContext) {
      for (var i = 0; i < count; i++) {
        while (bitOffset >= 32) {
          final word = view.getUint32(windowPos, Endian.little);
          windowPos += 4;
          accumulator = (accumulator >>> 32) | (word << 32);
          bitOffset -= 32;
        }
        final bits = (accumulator >>> bitOffset) & 0x7FFF;
        var offset = treeBase + (bits & 0xFF);
        var entry = group[offset];
        var rootLength = entry >> 16;
        var symbol = entry & 0xFFFF;
        if (rootLength > 8) {
          final mask15 = (1 << rootLength) - 1;
          offset += symbol + ((bits & mask15) >> 8);
          entry = group[offset];
          bitOffset += (entry >> 16) + 8;
          symbol = entry & 0xFFFF;
        } else {
          bitOffset += rootLength;
        }
        ring[cursor++] = symbol;
      }
    } else {
      var prev1 = ring[(pos - 1) & mask] & 0xFF;
      var prev2 = ring[(pos - 2) & mask] & 0xFF;
      var lastContext = -1;
      var lastBase = 0;
      for (var i = 0; i < count; i++) {
        final context =
            contextLookup[lookupOffset1 + prev1] |
            contextLookup[lookupOffset2 + prev2];
        final int base;
        if (context == lastContext) {
          base = lastBase;
        } else {
          base = baseByContext[context];
          lastContext = context;
          lastBase = base;
        }
        prev2 = prev1;
        while (bitOffset >= 32) {
          final word = view.getUint32(windowPos, Endian.little);
          windowPos += 4;
          accumulator = (accumulator >>> 32) | (word << 32);
          bitOffset -= 32;
        }
        final bits = (accumulator >>> bitOffset) & 0x7FFF;
        var offset = base + (bits & 0xFF);
        var entry = group[offset];
        var rootLength = entry >> 16;
        var symbol = entry & 0xFFFF;
        if (rootLength > 8) {
          final mask15 = (1 << rootLength) - 1;
          offset += symbol + ((bits & mask15) >> 8);
          entry = group[offset];
          bitOffset += (entry >> 16) + 8;
          symbol = entry & 0xFFFF;
        } else {
          bitOffset += rootLength;
        }
        prev1 = symbol;
        ring[cursor++] = symbol;
      }
    }
    _accumulator = accumulator;
    _bitOffset = bitOffset;
    _pos = windowPos;
    return cursor - pos;
  }

  @override
  String toString() {
    return 'BitReader64(pos: $pos, bitOffset: $_bitOffset, '
        'filled: $filled, eof: $_endOfStreamReached)';
  }
}
