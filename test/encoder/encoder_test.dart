@TestOn('vm')
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:brotli_fast/src/encoder/bit_writer.dart';
import 'package:brotli_fast/src/encoder/encoder.dart';
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

import '../support/brotli_cli.dart';
import '../support/encoder_round_trip.dart';
import '../support/high_ratio.dart';

const int kMaxMetaBlockLength = 1 << 24;

void main() {
  group('BitWriter', () {
    test('LSB-first within a byte', () {
      final writer = BitWriter()
        ..writeBits(3, 0x5)
        ..writeBits(5, 0x13);
      expect(writer.bitPosition, 8);
      // 101 followed by 10011 (LSB first) => 1001_1101.
      expect(writer.toBytes(), orderedEquals(<int>[0x9D]));
    });

    test('32-bit writes stay little-endian and do not alias', () {
      final writer = BitWriter()
        ..writeBits(32, 0x89ABCDEF)
        ..writeBits(31, 0x7FFFFFFF);
      expect(writer.bitPosition, 63);
      expect(
        writer.toBytes(),
        orderedEquals(<int>[0xEF, 0xCD, 0xAB, 0x89, 0xFF, 0xFF, 0xFF, 0x7F]),
      );

      final allOnes = BitWriter()..writeBits(32, 0xFFFFFFFF);
      expect(allOnes.toBytes(), orderedEquals(<int>[0xFF, 0xFF, 0xFF, 0xFF]));
    });

    test('unaligned writes cross byte boundaries', () {
      final writer = BitWriter()
        ..writeBits(1, 1)
        ..writeBits(9, 0x1FF);
      expect(writer.bitPosition, 10);
      expect(writer.toBytes(), orderedEquals(<int>[0xFF, 0x03]));
    });

    test('wide bit widths are masked correctly', () {
      final writer = BitWriter()
        ..writeBits(17, 0x1FFFF)
        ..writeBits(15, 0x7FFF);
      expect(writer.bitPosition, 32);
      expect(writer.toBytes(), orderedEquals(<int>[0xFF, 0xFF, 0xFF, 0xFF]));

      final mixed = BitWriter()
        ..writeBits(24, 0xABCDEF)
        ..writeBits(8, 0x5A);
      expect(mixed.toBytes(), orderedEquals(<int>[0xEF, 0xCD, 0xAB, 0x5A]));
    });

    test('alignToByte pads with zero bits', () {
      final writer = BitWriter()..writeBits(3, 0x5);
      expect(writer.bitPosition & 7, isNot(0));
      expect(writer.toBytes(), hasLength(1));
      writer.alignToByte();
      expect(writer.bitPosition, 8);
      expect(writer.toBytes(), orderedEquals(<int>[0x05]));
      // Aligning an aligned writer is a no-op.
      writer.alignToByte();
      expect(writer.bitPosition, 8);
    });

    test('toBytes is a snapshot and pads the final partial byte', () {
      final writer = BitWriter()..writeBits(3, 0x7);
      expect(writer.bitPosition, 3);
      expect(writer.toBytes(), orderedEquals(<int>[0x07]));
      expect(writer.bitPosition, 3, reason: 'toBytes must not mutate');
      writer.writeBits(5, 0x1F);
      expect(writer.toBytes(), orderedEquals(<int>[0xFF]));
    });

    test('mark/rewind inside the pending accumulator', () {
      final writer = BitWriter()..writeBits(5, 0x1F);
      final mark = writer.mark();
      writer.writeBits(7, 0x7F);
      expect(writer.bitPosition, 12);
      writer.rewind(mark);
      expect(writer.bitPosition, 5);
      writer.writeBits(3, 0x7);
      expect(writer.toBytes(), orderedEquals(<int>[0xFF]));
    });

    test('mark/rewind into an emitted partial byte', () {
      final writer = BitWriter()..writeBits(20, 0xABCDE);
      final mark = writer.mark();
      expect(mark, 20);
      writer.writeBits(8, 0xFF);
      writer.rewind(mark);
      expect(writer.bitPosition, 20);
      expect(writer.toBytes(), orderedEquals(<int>[0xDE, 0xBC, 0x0A]));

      // Continue writing where the rewind left off.
      writer.writeBits(4, 0x5);
      writer.alignToByte();
      expect(writer.toBytes(), orderedEquals(<int>[0xDE, 0xBC, 0x5A]));
    });

    test('rewind to a byte boundary and rewind to zero', () {
      final writer = BitWriter()
        ..writeBits(8, 0xAA)
        ..writeBits(8, 0xBB)
        ..writeBits(8, 0xFF);
      final mark = writer.mark();
      writer.writeBits(8, 0xCC);
      writer.rewind(mark);
      expect(writer.bitPosition, 24);
      writer.rewind(0);
      expect(writer.bitPosition, 0);
      expect(writer.toBytes(), isEmpty);
      writer.writeBits(2, 0x2);
      expect(writer.toBytes(), orderedEquals(<int>[0x02]));
    });

    test('rewind rejects out-of-range positions (debug assertion)', () {
      final writer = BitWriter()..writeBits(4, 0xF);
      expect(() => writer.rewind(5), throwsA(isA<AssertionError>()));
      expect(() => writer.rewind(-1), throwsA(isA<AssertionError>()));
    });

    test('writeBytes requires byte alignment and honours start/end', () {
      final writer = BitWriter()..writeBits(1, 1);
      expect(
        () => writer.writeBytes(Uint8List(1), 0, 1),
        throwsA(isA<AssertionError>()),
      );
      writer.alignToByte();
      writer.writeBytes(Uint8List.fromList(<int>[9, 1, 2, 3, 9]), 1, 4);
      expect(writer.toBytes(), orderedEquals(<int>[0x01, 1, 2, 3]));
      // An empty range writes nothing.
      writer.writeBytes(Uint8List(4), 2, 2);
      expect(writer.bitPosition, 32);
    });

    test('takeCompleteBytes keeps the pending bits', () {
      final writer = BitWriter()
        ..writeBits(8, 0xAB)
        ..writeBits(12, 0xCDE);
      expect(writer.takeCompleteBytes(), orderedEquals(<int>[0xAB, 0xDE]));
      expect(writer.bitPosition, 4);
      writer.writeBits(4, 0x1);
      expect(writer.toBytes(), orderedEquals(<int>[0x1C]));
    });

    test('grows across many writes', () {
      final writer = BitWriter(initialCapacity: 8);
      final expected = Uint8List(1000);
      for (var i = 0; i < expected.length; i++) {
        expected[i] = (i * 37 + 11) & 0xFF;
        writer.writeBits(8, expected[i]);
      }
      expect(writer.toBytes(), orderedEquals(expected));
    });
  });

  group('framing', () {
    test('empty input is the canonical [0x06] stream', () {
      expect(
        encode(Uint8List(0), const BrotliEncodeOptions()),
        orderedEquals(<int>[0x06]),
      );
      expect(brotliEncode(Uint8List(0)), orderedEquals(<int>[0x06]));
      expect(maxCompressedSize(0), 2);
    });

    test('1-byte input has the expected exact bytes (lgwin 16)', () {
      final out = highRatioEncode(
        Uint8List.fromList(<int>[0x61]),
        // Stage 0 framing (quality 2/3 and 6..11); quality 0/1 and 4/5 emit
        // compressed meta-blocks instead.
        const BrotliEncodeOptions(lgwin: 16, quality: 2),
      );
      // window(0) ISLAST(0) mnibbles(00) MLEN-1(16 zero bits) ISUNCOMPRESSED(1),
      // pad, raw 'a', final empty last block.
      expect(out, orderedEquals(<int>[0x00, 0x00, 0x10, 0x61, 0x03]));
      expect(out.length, lessThanOrEqualTo(maxCompressedSize(1)));
    });

    test('1-byte input has the expected exact bytes (default lgwin 22)', () {
      final out = highRatioEncode(
        Uint8List.fromList(<int>[0x61]),
        const BrotliEncodeOptions(quality: 2),
      );
      // window bits 0b1011, ISLAST(0), mnibbles(00), MLEN-1(0), pad.
      expect(out, orderedEquals(<int>[0x0B, 0x00, 0x80, 0x61, 0x03]));
    });

    test('maxCompressedSize follows BrotliEncoderMaxCompressedSize', () {
      expect(maxCompressedSize(1), 1 + 2 + 3 + 1);
      expect(maxCompressedSize(16383), 16383 + 2 + 3 + 1);
      expect(maxCompressedSize(16384), 16384 + 2 + 4 + 3 + 1);
      expect(maxCompressedSize(1 << 20), (1 << 20) + 2 + 4 * 64 + 3 + 1);
      expect(() => maxCompressedSize(-1), throwsArgumentError);
      for (final size in <int>[1, 100, 16383, 16384, 65536, 1 << 20]) {
        expect(maxCompressedSize(size), greaterThan(size));
      }
    });

    test('quality is clamped and aliased (0..11)', () {
      final input = _data(_DataKind.repetitive, 4096);
      Uint8List compress(int quality) =>
          highRatioEncode(input, BrotliEncodeOptions(quality: quality));
      // Qualities 2 and 3 share the chain tier.
      expect(compress(3), orderedEquals(compress(2)));
      // Qualities 10 and 11 add guided parses, so they are no longer aliases of
      // quality 9; they may only ever be smaller. Values above 11 clamp to 11.
      for (final quality in <int>[10, 11]) {
        expect(
          compress(quality).length,
          lessThanOrEqualTo(compress(9).length),
          reason: 'quality $quality should not be larger than quality 9',
        );
      }
      expect(compress(100), orderedEquals(compress(11)));
      // Quality 0 is used both by an explicit 0 and by a negative input.
      expect(compress(-100), orderedEquals(compress(0)));
      // The routed one-shot entry clamps the same way.
      expect(
        encode(input, const BrotliEncodeOptions(quality: 100)),
        orderedEquals(encode(input, const BrotliEncodeOptions(quality: 11))),
      );
      expect(
        encode(input, const BrotliEncodeOptions(quality: -100)),
        orderedEquals(encode(input, const BrotliEncodeOptions(quality: 0))),
      );
      // The public API validates instead of clamping.
      expect(() => brotliEncode(input, quality: 12), throwsRangeError);
      expect(() => brotliEncode(input, quality: -1), throwsRangeError);
      // Every quality respects the output bound and the window header. (Size
      // ordering across tiers is asserted on real text in
      // `encoder_context_test.dart`; on tiny/repetitive input a higher effort
      // tier can legitimately be a few bytes larger.)
      for (final quality in <int>[-5, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 50]) {
        for (final out in <Uint8List>[
          compress(quality),
          encode(input, BrotliEncodeOptions(quality: quality)),
        ]) {
          expect(
            out.length,
            lessThanOrEqualTo(maxCompressedSize(input.length)),
            reason: 'quality $quality',
          );
          expect(_BitReader(out).readWindowBits(), 22);
        }
      }
    });

    test('lgwin is clamped to 10..24 and appears in the header', () {
      final input = Uint8List.fromList(
        List<int>.generate(4096, (i) => i & 0xFF),
      );
      for (var lgwin = 10; lgwin <= 24; lgwin++) {
        for (final out in <Uint8List>[
          highRatioEncode(input, BrotliEncodeOptions(lgwin: lgwin)),
          encode(input, BrotliEncodeOptions(lgwin: lgwin)),
          brotliEncode(input, windowBits: lgwin),
        ]) {
          final reader = _BitReader(out);
          expect(reader.readWindowBits(), lgwin, reason: 'lgwin $lgwin header');
        }
      }
      // Out-of-range values normalize like the rest of the internal options.
      final low = highRatioEncode(input, const BrotliEncodeOptions(lgwin: 1));
      expect(_BitReader(low).readWindowBits(), 10);
      expect(
        _BitReader(encode(input, const BrotliEncodeOptions(lgwin: 1)))
            .readWindowBits(),
        10,
      );
      // The public API validates instead.
      expect(() => brotliEncode(input, windowBits: 9), throwsRangeError);
      // A window above 24 needs an explicit opt-in.
      expect(
        () => highRatioEncode(input, const BrotliEncodeOptions(lgwin: 30)),
        throwsA(isA<BrotliException>()),
      );
      expect(
        () => encode(input, const BrotliEncodeOptions(lgwin: 30)),
        throwsA(isA<BrotliException>()),
      );
    });

    test('large-window requests need the opt-in flag', () {
      // lgwin <= 24 with largeWindow set still produces a regular stream.
      final input = Uint8List.fromList(<int>[1, 2, 3]);
      final out = highRatioEncode(
        input,
        const BrotliEncodeOptions(lgwin: 22, largeWindow: true),
      );
      expect(_BitReader(out).readWindowBits(), 22);
      // lgwin 25..30 with largeWindow is a non-RFC large-window stream.
      final large = highRatioEncode(
        input,
        const BrotliEncodeOptions(lgwin: 30, largeWindow: true),
      );
      expect(large, isNotEmpty);
      expect(brotliDecode(large, allowLargeWindow: true), orderedEquals(input));
      expect(() => brotliDecode(large), throwsA(isA<BrotliException>()));
      // The public API opts in through windowBits > 24.
      final public = brotliEncode(input, windowBits: 30);
      expect(public, orderedEquals(large));
    });

    test('meta-block framing is structurally valid for boundary sizes', () {
      // Incompressible input makes every block fall back to uncompressed
      // framing, which is what this test parses directly. (Compressed blocks
      // are covered by the round-trip group.)
      for (final size in _boundarySizes) {
        final input = _data(_DataKind.random, size);
        final out = highRatioEncode(
          input,
          const BrotliEncodeOptions(quality: 2),
        );
        _expectValidFraming(out, input, lgwin: 22);
        expect(out.length, lessThanOrEqualTo(maxCompressedSize(size)));
      }
    });

    test('input larger than 2^24 is split into multiple meta-blocks', () {
      const size = kMaxMetaBlockLength + 1;
      final input = _data(_DataKind.random, size);
      final out = highRatioEncode(input, const BrotliEncodeOptions(quality: 2));
      final blocks = _parseStream(out, expectedLgwin: 22);
      expect(blocks.length, (size + kChainBlockSize - 1) ~/ kChainBlockSize);
      expect(blocks.first.length, kChainBlockSize);
      expect(blocks.last.length, 1);
      expect(out.length, lessThanOrEqualTo(maxCompressedSize(size)));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('reference round-trip', () {
    test('single byte values', () async {
      for (final value in <int>[0x00, 0x01, 0x61, 0x7F, 0x80, 0xFF]) {
        final input = Uint8List.fromList(<int>[value]);
        await expectEncodeRoundTrip(input, quality: 5, reason: 'byte $value');
      }
    });

    test('1 byte, empty and small payloads', () async {
      for (final size in <int>[0, 1, 2, 15, 16, 17, 255, 256, 300]) {
        for (final kind in _DataKind.values) {
          await expectEncodeRoundTrip(
            _data(kind, size),
            quality: 5,
            reason: '${kind.name} $size',
          );
        }
      }
    });

    test('sizes around 1024', () async {
      for (final size in <int>[1023, 1024, 1025]) {
        for (final kind in _DataKind.values) {
          await expectEncodeRoundTrip(
            _data(kind, size),
            quality: 5,
            reason: '${kind.name} $size',
          );
        }
      }
    });

    test('sizes around 65535/65536', () async {
      for (final size in <int>[65534, 65535, 65536, 65537]) {
        for (final kind in _DataKind.values) {
          await expectEncodeRoundTrip(
            _data(kind, size),
            quality: 5,
            reason: '${kind.name} $size',
          );
        }
      }
    });

    test('sizes around 1 MiB', () async {
      for (final size in <int>[1048575, 1048576, 1048577]) {
        for (final kind in _DataKind.values) {
          await expectEncodeRoundTrip(
            _data(kind, size),
            quality: 5,
            reason: '${kind.name} $size',
          );
        }
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('input larger than 2^24 round-trips', () async {
      final input = _data(_DataKind.repetitive, kMaxMetaBlockLength + 1);
      await expectEncodeRoundTrip(input, quality: 5, reason: '2^24 + 1');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('all lgwin values round-trip', () async {
      // Larger than the smallest window: uncompressed blocks do not care.
      final input = _data(_DataKind.random, 70000);
      for (var lgwin = 10; lgwin <= 24; lgwin++) {
        await expectEncodeRoundTrip(
          input,
          quality: 5,
          lgwin: lgwin,
          reason: 'lgwin $lgwin',
        );
      }
    });

    test('random lengths round-trip', () async {
      final rnd = Random(20261020);
      for (var i = 0; i < 8; i++) {
        final size = rnd.nextInt(300);
        final kind = _DataKind.values[i % _DataKind.values.length];
        await expectEncodeRoundTrip(
          _data(kind, size, seed: i),
          quality: 5,
          reason: '${kind.name} $size',
        );
      }
    });

    test('output is deterministic', () {
      final input = _data(_DataKind.random, 4096);
      for (final entry in encodePaths(input, quality: 5).entries) {
        expect(
          encodePaths(input, quality: 5)[entry.key],
          orderedEquals(entry.value),
          reason: entry.key,
        );
      }
    });
  }, skip: brotliCliSkipReason());
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const List<int> _boundarySizes = <int>[
  1,
  2,
  15,
  16,
  255,
  256,
  1023,
  1024,
  1025,
  4095,
  4096,
  65534,
  65535,
  65536,
  65537,
  1048575,
  1048576,
  1048577,
];

enum _DataKind { repetitive, random, zeros }

Uint8List _data(_DataKind kind, int size, {int seed = 0}) {
  switch (kind) {
    case _DataKind.zeros:
      return Uint8List(size);
    case _DataKind.repetitive:
      final pattern = utf8.encode(
        'brotli_fast stage-0 uncompressed meta-block framing test 0123456789 ',
      );
      final out = Uint8List(size);
      for (var i = 0; i < size; i++) {
        out[i] = pattern[i % pattern.length];
      }
      return out;
    case _DataKind.random:
      final rnd = Random(0xB07 + seed);
      final out = Uint8List(size);
      for (var i = 0; i < size; i++) {
        out[i] = rnd.nextInt(256);
      }
      return out;
  }
}

/// Minimal LSB-first bit reader used to assert the emitted framing directly.
final class _BitReader {
  _BitReader(this.bytes);

  final Uint8List bytes;
  int bitPosition = 0;

  int get bytePosition => bitPosition >> 3;

  void skipToByteBoundary() {
    bitPosition = (bitPosition + 7) & ~7;
  }

  int readBits(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      final byte = bitPosition >> 3;
      if (byte >= bytes.length) {
        throw StateError('unexpected end of stream at bit $bitPosition');
      }
      final bit = (bytes[byte] >> (bitPosition & 7)) & 1;
      value |= bit << i;
      bitPosition++;
    }
    return value;
  }

  /// Mirrors `DecodeWindowBits` from the RFC 7932 decoder.
  int readWindowBits() {
    if (readBits(1) == 0) return 16;
    final n1 = readBits(3);
    if (n1 != 0) return 17 + n1;
    final n2 = readBits(3);
    if (n2 == 1) {
      throw StateError('large-window stream in a regular encoder output');
    }
    if (n2 != 0) return 8 + n2;
    return 17;
  }
}

/// Parses and validates one stream; returns the raw bytes of each meta-block.
List<Uint8List> _parseStream(Uint8List stream, {required int expectedLgwin}) {
  final reader = _BitReader(stream);
  expect(reader.readWindowBits(), expectedLgwin, reason: 'window bits');
  final blocks = <Uint8List>[];
  while (true) {
    final isLast = reader.readBits(1) == 1;
    if (isLast) {
      expect(
        reader.readBits(1),
        1,
        reason: 'ISEMPTY must be set on last block',
      );
      reader.skipToByteBoundary();
      break;
    }
    final nibbles = reader.readBits(2) + 4;
    expect(nibbles, inInclusiveRange(4, 6), reason: 'mnibbles');
    var lengthMinusOne = 0;
    for (var i = 0; i < nibbles; i++) {
      lengthMinusOne |= reader.readBits(4) << (4 * i);
    }
    final length = lengthMinusOne + 1;
    if (nibbles > 4) {
      // RFC 7932 forbids a redundant zero top nibble.
      expect(
        lengthMinusOne >> (4 * (nibbles - 1)),
        isNonZero,
        reason: 'exuberant length nibble',
      );
    }
    expect(length, lessThanOrEqualTo(kMaxMetaBlockLength));
    expect(reader.readBits(1), 1, reason: 'ISUNCOMPRESSED');
    reader.skipToByteBoundary();
    final start = reader.bytePosition;
    expect(start + length, lessThanOrEqualTo(stream.length));
    blocks.add(Uint8List.sublistView(stream, start, start + length));
    reader.bitPosition = (start + length) * 8;
  }
  expect(
    reader.bitPosition,
    stream.length * 8,
    reason: 'trailing bytes after the last meta-block',
  );
  return blocks;
}

void _expectValidFraming(
  Uint8List stream,
  Uint8List input, {
  required int lgwin,
}) {
  final blocks = _parseStream(stream, expectedLgwin: lgwin);
  expect(
    blocks.length,
    (input.length + kChainBlockSize - 1) ~/ kChainBlockSize,
  );
  final reassembled = BytesBuilder(copy: false);
  for (final block in blocks) {
    expect(block.length, lessThanOrEqualTo(kChainBlockSize));
    reassembled.add(block);
  }
  expectSameBytes(reassembled.takeBytes(), input);
}
