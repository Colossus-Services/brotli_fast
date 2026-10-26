import 'dart:typed_data';

import 'package:brotli_fast/src/common/errors.dart';
import 'package:brotli_fast/src/decoder/bit_reader.dart';
import 'package:test/test.dart';

import 'decoder_helpers.dart';

int _mask(int width) => width == 32 ? 0xFFFFFFFF : (1 << width) - 1;

int _readByte(BitReader reader) {
  expect(reader.refill(), isTrue);
  reader.fillBitWindow();
  return reader.readFewBits(8);
}

void main() {
  test('fromBytes exposes stream geometry', () {
    final bytes = Uint8List.fromList(List<int>.generate(10, (i) => i * 7));
    final reader = BitReader.fromBytes(bytes);
    expect(reader.endOfStreamReached, isTrue);
    expect(reader.tailBytes, 10);
    expect(reader.filled, 10);
    expect(reader.pos, 0);
    expect(reader.accumulator, 0);
    expect(reader.unusedBits, 0);
    expect(reader.consumedBits, 0);
    expect(reader.bytesConsumed, 0);
    expect(reader.activeMementoCount, 0);
    expect(reader.sourceClosed, isTrue);
    expect(reader.refill(), isTrue);
    expect(reader.endOfStreamReached, isTrue);
    reader.checkHealth();
  });

  test('readBits decodes every width 1..32', () {
    final widths = List<int>.generate(32, (i) => i + 1);
    final sink = BitSink();
    for (final width in widths) {
      final max = _mask(width);
      sink.writeBits(0, width);
      sink.writeBits(max, width);
      sink.writeBits(0xAAAAAAAA & max, width);
    }
    final reader = BitReader.fromBytes(sink.toBytes());
    for (final width in widths) {
      final max = _mask(width);
      for (final expected in <int>[0, max, 0xAAAAAAAA & max]) {
        expect(reader.refill(), isTrue);
        reader.fillBitWindow();
        expect(reader.readBits(width), expected, reason: 'width $width');
        expect(reader.unusedBits, greaterThanOrEqualTo(0));
      }
    }
    expect(reader.bytesConsumed, sink.bitLength >> 3);
    reader.checkHealth(true);
  });

  test('peekBits does not consume and readFewBits handles widths 1..16', () {
    final widths = List<int>.generate(16, (i) => i + 1);
    final sink = BitSink();
    for (final width in widths) {
      final max = _mask(width);
      sink.writeBits(max, width);
      sink.writeBits(0x55555555 & max, width);
    }
    final reader = BitReader.fromBytes(sink.toBytes());
    for (final width in widths) {
      final max = _mask(width);
      for (final expected in <int>[max, 0x55555555 & max]) {
        expect(reader.refill(), isTrue);
        reader.fillBitWindow();
        final bitOffset = reader.bitOffset;
        final consumed = reader.bytesConsumed;
        expect(reader.peekBits(width), expected, reason: 'peek width $width');
        expect(reader.bitOffset, bitOffset);
        expect(reader.bytesConsumed, consumed);
        expect(
          reader.readFewBits(width),
          expected,
          reason: 'read width $width',
        );
      }
    }
    reader.checkHealth(true);
  });

  test('dropBits skips exactly the peeked bits', () {
    final sink = BitSink()
      ..writeBits(0x3, 2)
      ..writeBits(0x1F5, 9)
      ..writeBits(0x2A, 6);
    final reader = BitReader.fromBytes(sink.toBytes());
    reader.fillBitWindow();
    expect(reader.peekBits(2), 0x3);
    reader.dropBits(2);
    expect(reader.peekBits(9), 0x1F5);
    reader.dropBits(9);
    expect(reader.readFewBits(6), 0x2A);
    expect(reader.consumedBits, 17);
  });

  test('readBitsUpTo32 matches readBits for wide widths', () {
    final sink = BitSink();
    const values = <int>[
      0x00000001,
      0x00018000,
      0x00ABCDEF,
      0x80000001,
      0xFFFFFFFF,
      0x00000000,
    ];
    for (final value in values) {
      sink.writeBits(value, 32);
    }
    final reader = BitReader.fromBytes(sink.toBytes());
    for (final value in values) {
      expect(reader.refill(), isTrue);
      reader.fillBitWindow();
      expect(reader.readBitsUpTo32(32), value);
    }
    reader.checkHealth(true);
  });

  test('readBits splits wide reads at the accumulator boundary', () {
    // 5 + 9 + 4 + 14 bits: one full 32-bit window after a single fill.
    final sink = BitSink();
    sink.writeBits(0x1F, 5);
    sink.writeBits(0x1AB, 9);
    sink.writeBits(0xF, 4);
    sink.writeBits(0x2A5A, 14);
    final reader = BitReader.fromBytes(sink.toBytes());
    expect(reader.refill(), isTrue);
    reader.fillBitWindow();
    expect(reader.readBits(5), 0x1F);
    expect(reader.readBits(9), 0x1AB);
    expect(reader.readBits(4), 0xF);
    expect(reader.readBits(14), 0x2A5A);
  });

  test('jumpToByteBoundary aligns to the next byte', () {
    final sink = BitSink();
    sink.writeBits(0x5, 3); // 101, upper 5 bits stay zero
    sink.writeBits(0x0, 5);
    sink.writeBits(0x5A, 8);
    sink.writeBits(0x1234, 16);
    final reader = BitReader.fromBytes(sink.toBytes());
    expect(reader.refill(), isTrue);
    reader.fillBitWindow();
    expect(reader.readFewBits(3), 0x5);
    reader.jumpToByteBoundary();
    expect(reader.bytesConsumed, 1);
    expect(reader.refill(), isTrue);
    reader.fillBitWindow();
    expect(reader.readFewBits(8), 0x5A);
    reader.fillBitWindow();
    expect(reader.readFewBits(16), 0x1234);
    reader.checkHealth(true);
  });

  test('jumpToByteBoundary rejects non-zero padding', () {
    final sink = BitSink();
    sink.writeBits(0x5, 3);
    sink.writeBits(0x10, 5); // one padding bit set
    sink.writeBits(0x5A, 8);
    final reader = BitReader.fromBytes(sink.toBytes());
    expect(reader.refill(), isTrue);
    reader.fillBitWindow();
    expect(reader.readFewBits(3), 0x5);
    expect(
      reader.jumpToByteBoundary,
      throwsBrotli(BrotliErrorCode.corruptPadding),
    );
  });

  test('refill works with one-byte chunks and late input', () {
    final data = Uint8List.fromList(
      List<int>.generate(500, (i) => (i * 31 + 7) & 0xFF),
    );
    final input = ChunkedInput(bytesPerCall: 1);
    var fed = 0;
    void feed(int count) {
      final end = fed + count > data.length ? data.length : fed + count;
      input.add(data.sublist(fed, end));
      fed = end;
    }

    feed(10);
    final reader = BitReader(input);
    expect(reader.sourceClosed, isFalse);
    var index = 0;
    var starved = 0;
    while (index < data.length) {
      if (!reader.refill()) {
        starved++;
        if (fed < data.length) {
          feed(7);
        } else {
          input.close();
        }
        continue;
      }
      reader.fillBitWindow();
      expect(reader.readFewBits(8), data[index], reason: 'byte $index');
      index++;
    }
    expect(starved, greaterThan(3));
    expect(reader.endOfStreamReached, isTrue);
    expect(reader.tailBytes, data.length);
    expect(reader.bytesConsumed, data.length);
    expect(reader.filled, 0);
    reader.checkHealth(true);
  });

  test('tailBytes becomes available only once the stream ends', () {
    final data = Uint8List(5000);
    final reader = BitReader.fromBytes(data);
    expect(reader.endOfStreamReached, isFalse);
    expect(reader.tailBytes, -1);
    expect(reader.filled, BitReader.capacity);
    for (var i = 0; i < data.length; i++) {
      expect(_readByte(reader), 0);
    }
    expect(reader.endOfStreamReached, isTrue);
    expect(reader.tailBytes, data.length);
    expect(reader.bytesConsumed, data.length);
    reader.checkHealth(true);
  });

  test('copyRawBytes and skipRawBytes respect byte alignment', () {
    final bytes = Uint8List.fromList(<int>[0x05, 0x11, 0x22, 0x33, 0x44]);
    final reader = BitReader.fromBytes(bytes);
    reader.fillBitWindow();
    expect(reader.readFewBits(3), 0x5);
    reader.jumpToByteBoundary();
    final destination = Uint8List(4);
    expect(reader.copyRawBytes(destination, 0, 2), 2);
    expect(destination.sublist(0, 2), <int>[0x11, 0x22]);
    expect(reader.skipRawBytes(2), 2);
    expect(reader.filled, 0);
    expect(reader.copyRawBytes(destination, 0, 1), 0);
    expect(reader.bytesConsumed, 5);
    reader.checkHealth(true);
  });

  test('copyRawBytes makes staged progress at end of stream', () {
    final bytes = Uint8List.fromList(<int>[0x00, 0x11]);
    final reader = BitReader.fromBytes(bytes);
    reader.fillBitWindow();
    expect(reader.readFewBits(8), 0x00);
    final destination = Uint8List(4);
    expect(reader.copyRawBytes(destination, 0, 4), 1);
    expect(destination[0], 0x11);
    expect(reader.copyRawBytes(destination, 0, 1), 0);
    expect(reader.bytesConsumed, 2);
    reader.checkHealth(true);
  });

  test('copyRawBytes reads past the accumulator into the window', () {
    final bytes = Uint8List.fromList(List<int>.generate(100, (i) => i));
    final reader = BitReader.fromBytes(bytes);
    reader.fillBitWindow();
    expect(reader.readFewBits(8), 0);
    final destination = Uint8List(99);
    expect(reader.copyRawBytes(destination, 0, 99), 99);
    expect(destination, List<int>.generate(99, (i) => i + 1));
    expect(reader.bytesConsumed, 100);
    reader.checkHealth(true);
  });

  test('copyRawBytes rejects unaligned readers', () {
    final reader = BitReader.fromBytes(Uint8List(8));
    reader.fillBitWindow();
    expect(reader.readFewBits(3), 0);
    expect(
      () => reader.copyRawBytes(Uint8List(4), 0, 1),
      throwsBrotli(BrotliErrorCode.internalError),
    );
    expect(
      () => reader.skipRawBytes(1),
      throwsBrotli(BrotliErrorCode.internalError),
    );
  });

  test('checkHealth rejects reads after the end and unused bytes', () {
    final oneByte = BitReader.fromBytes(Uint8List.fromList(<int>[0xAB]));
    oneByte.fillBitWindow();
    expect(oneByte.readFewBits(8), 0xAB);
    oneByte.fillBitWindow();
    oneByte.readFewBits(8);
    expect(
      () => oneByte.checkHealth(),
      throwsBrotli(BrotliErrorCode.readAfterEnd),
    );
    expect(
      () => oneByte.refill(),
      throwsBrotli(BrotliErrorCode.truncatedInput),
    );

    final unused = BitReader.fromBytes(
      Uint8List.fromList(<int>[0x01, 0x02, 0x03]),
    );
    unused.fillBitWindow();
    expect(unused.readFewBits(8), 0x01);
    expect(
      () => unused.checkHealth(true),
      throwsBrotli(BrotliErrorCode.unusedBytesAfterEnd),
    );

    final exact = BitReader.fromBytes(
      Uint8List.fromList(<int>[0x01, 0x02, 0x03]),
    );
    exact.fillBitWindow();
    expect(exact.readBits(24), 0x030201);
    exact.checkHealth();
    exact.checkHealth(true);
  });

  test('zero-width reads do not advance the cursor', () {
    final reader = BitReader.fromBytes(Uint8List.fromList(<int>[0xAB, 0xCD]));
    reader.fillBitWindow();
    final consumed = reader.bytesConsumed;
    expect(reader.peekBits(0), 0);
    expect(reader.readFewBits(0), 0);
    expect(reader.readBits(0), 0);
    expect(reader.readBitsUpTo32(0), 0);
    expect(reader.bytesConsumed, consumed);
    expect(reader.readFewBits(8), 0xAB);
  });

  test('fromBytes honours offset and end', () {
    final bytes = Uint8List.fromList(<int>[0x11, 0x22, 0x33, 0x44]);
    final reader = BitReader.fromBytes(bytes, offset: 1, end: 3);
    expect(reader.tailBytes, 2);
    reader.fillBitWindow();
    expect(reader.readBits(16), 0x3322);
    reader.checkHealth(true);
  });

  test('reload warms the accumulator after it is drained', () {
    final bytes = Uint8List.fromList(List<int>.generate(24, (i) => i + 1));
    final reader = BitReader.fromBytes(bytes);
    reader.fillBitWindow();
    var next = 0;
    // Drain every buffered bit (the accumulator width is backend specific).
    while (reader.unusedBits > 0) {
      expect(reader.readBits(8), bytes[next++]);
    }
    expect(reader.reload(), isTrue);
    expect(reader.unusedBits, greaterThan(0));
    expect(reader.readBits(16), bytes[next] | (bytes[next + 1] << 8));
    next += 2;
    // reload() is a no-op while bits remain.
    final consumed = reader.consumedBits;
    expect(reader.reload(), isTrue);
    expect(reader.consumedBits, consumed);
    while (next < bytes.length) {
      reader.fillBitWindow();
      expect(reader.readBits(8), bytes[next++]);
    }
    reader.checkHealth(true);
  });

  test('memento/restore survives compaction of the input window', () {
    final bytes = Uint8List.fromList(
      List<int>.generate(12000, (i) => (i * 37 + 11) & 0xFF),
    );
    final reader = BitReader.fromBytes(bytes);
    final reference = BitReader.fromBytes(bytes);
    for (var i = 0; i < 3000; i++) {
      final expected = _readByte(reference);
      expect(_readByte(reader), expected);
    }
    final savedPos = reader.pos;
    final savedConsumed = reader.bytesConsumed;
    final memento = reader.save();
    expect(memento.absolutePosition, savedPos);
    expect(reader.activeMementoCount, 1);

    for (var i = 0; i < 1200; i++) {
      _readByte(reader);
    }
    // The window was compacted while the memento was alive.
    expect(reader.pos, greaterThan(BitReader.capacity));

    reader.restore(memento);
    expect(reader.activeMementoCount, 0);
    expect(reader.pos, savedPos);
    expect(reader.bytesConsumed, savedConsumed);

    for (var i = 0; i < 1200; i++) {
      expect(_readByte(reader), _readByte(reference), reason: 'replay $i');
    }
  });

  test('memento restore without compaction replays the same bits', () {
    final bytes = Uint8List.fromList(
      List<int>.generate(2000, (i) => (i * 13 + 5) & 0xFF),
    );
    final reader = BitReader.fromBytes(bytes);
    for (var i = 0; i < 10; i++) {
      _readByte(reader);
    }
    final memento = reader.save();
    final replay = <int>[];
    for (var i = 0; i < 10; i++) {
      replay.add(_readByte(reader));
    }
    reader.restore(memento);
    for (final value in replay) {
      expect(_readByte(reader), value);
    }
  });

  test('nested mementos restore independently', () {
    final bytes = Uint8List.fromList(
      List<int>.generate(9000, (i) => (i * 91 + 3) & 0xFF),
    );
    final reader = BitReader.fromBytes(bytes);
    final reference = BitReader.fromBytes(bytes);
    for (var i = 0; i < 6000; i++) {
      final expected = _readByte(reference);
      expect(_readByte(reader), expected);
    }
    final outer = reader.save();
    final outerPos = reader.pos;
    final first = <int>[];
    for (var i = 0; i < 300; i++) {
      first.add(_readByte(reader));
    }
    final inner = reader.save();
    final innerPos = reader.pos;
    final second = <int>[];
    for (var i = 0; i < 500; i++) {
      second.add(_readByte(reader));
    }
    reader.restore(inner);
    expect(reader.pos, innerPos);
    expect(reader.activeMementoCount, 1);
    for (final value in second) {
      expect(_readByte(reader), value);
    }
    reader.restore(outer);
    expect(reader.pos, outerPos);
    expect(reader.activeMementoCount, 0);
    for (final value in first) {
      expect(_readByte(reader), value);
    }
  });

  test('discard releases a memento and keeps the reader usable', () {
    final reader = BitReader.fromBytes(
      Uint8List.fromList(List<int>.generate(500, (i) => i & 0xFF)),
    );
    for (var i = 0; i < 10; i++) {
      _readByte(reader);
    }
    final memento = reader.save();
    expect(reader.activeMementoCount, 1);
    for (var i = 0; i < 10; i++) {
      _readByte(reader);
    }
    reader.discard(memento);
    expect(reader.activeMementoCount, 0);
    expect(() => reader.restore(memento), throwsStateError);
    reader.discard(memento); // idempotent
    expect(_readByte(reader), 20);
  });

  test('mementos belong to their reader', () {
    final a = BitReader.fromBytes(Uint8List(16));
    final b = BitReader.fromBytes(Uint8List(16));
    final memento = a.save();
    expect(() => b.restore(memento), throwsStateError);
    expect(() => b.discard(memento), throwsStateError);
    a.restore(memento);
  });
}
