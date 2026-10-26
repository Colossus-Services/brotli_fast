/// Regressions found while measuring and optimizing the codec.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:brotli_fast/src/encoder/bit_writer.dart';
import 'package:brotli_fast/src/encoder/command.dart';
import 'package:brotli_fast/src/encoder/encoder.dart';
import 'package:brotli_fast/src/encoder/metablock_writer.dart';
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

import '../benchmark/corpus.dart';
import 'support/brotli_cli.dart';

Uint8List _random(int seed, int length) => Uint8List.fromList(
  List<int>.generate(length, (_) {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return (seed >> 16) & 0xFF;
  }),
);

void main() {
  test('long insert lengths (24 extra bits) decode in the fast path', () {
    // Incompressible data repeated: the parse emits a 94128-byte literal run
    // (insert code 23, 24 extra bits) followed by a long copy. The fused
    // decoder used to read those extra bits without refilling its window.
    final input = File('test/testdata/compressed_repeated').readAsBytesSync();
    for (var quality = 0; quality <= 5; quality++) {
      expect(
        brotliDecode(brotliEncode(input, quality: quality)),
        orderedEquals(input),
        reason: 'q$quality',
      );
    }
  });

  test('one-shot decoding of small, wrapping windows', () {
    // The fused fast path ignored ring wrap-around: copy sources crossing the
    // end of a small window read slack bytes, and distances past the wrapped
    // `pos` were taken for dictionary references.
    final alice = File('test/testdata/alice29.txt').readAsBytesSync();
    final input = Uint8List.sublistView(alice, 0, 66000);
    for (var windowBits = 10; windowBits <= 17; windowBits++) {
      for (final quality in <int>[0, 1, 5, 9]) {
        final packed = brotliEncode(
          input,
          quality: quality,
          windowBits: windowBits,
        );
        expect(
          brotliDecode(packed),
          orderedEquals(input),
          reason: 'w$windowBits q$quality',
        );
      }
    }
  });

  test('one-shot decoding of a copy whose source wraps the ring end', () async {
    // Window 10 (a 1024-byte ring). Meta-block 1 stores 1024 raw bytes and
    // fills the ring exactly, so `pos` wraps to 0. Meta-block 2 inserts 5
    // literals and copies 20 bytes from distance 10: the source starts at
    // ring byte 1019 and runs past the ring end. Such small meta-blocks take
    // the fused fast path, which used to read the bytes past the window.
    final input = Uint8List(1024 + 25);
    for (var i = 0; i < 1029; i++) {
      input[i] = (i * 151 + 7) & 0xFF;
    }
    for (var i = 1029; i < input.length; i++) {
      input[i] = input[i - 10];
    }
    final writer = BitWriter()..writeBits(7, ((10 - 8) << 4) | 1); // WBITS = 10
    writeUncompressedMetaBlock(writer, input, 0, 1024);
    final commands = CommandBuffer(4)
      ..addCopy(5, 20, 10, 1024 - 16, createInitialDistanceCache());
    MetaBlockWriter().store(writer, input, 1024, 25, commands, isLast: false);
    writer
      ..writeBits(1, 1) // ISLAST
      ..writeBits(1, 1) // ISLASTEMPTY
      ..alignToByte();
    final stream = writer.toBytes();
    expect(brotliDecode(stream), orderedEquals(input));
    expect(
      await cliDecompress(stream),
      orderedEquals(input),
      reason: 'the hand-built stream is valid for the reference decoder',
    );
  }, skip: brotliCliSkipReason());

  test('chain search tolerates sub-4-byte candidates near position 0', () {
    // Seed 43 hits a candidate at position 0 after a 1-byte match; the cheap
    // rejection window used to read index -2.
    final input = _random(43, 65536);
    for (var quality = 2; quality <= 5; quality++) {
      expect(
        brotliDecode(brotliEncode(input, quality: quality)),
        orderedEquals(input),
        reason: 'q$quality',
      );
    }
  });

  group('the reused hash-chain table', () {
    test('output does not depend on what was encoded before', () {
      final text = makeText(200000);
      final binary = makeBinary(200000);
      for (final quality in <int>[6, 9, 11]) {
        final first = brotliEncode(text, quality: quality);
        // Leave a table full of other positions behind, then re-encode.
        brotliEncode(binary, quality: quality);
        expect(
          brotliEncode(text, quality: quality),
          orderedEquals(first),
          reason: 'q$quality',
        );
      }
    });

    test('a streaming encoder keeps its own table across one-shot calls', () {
      // The second half repeats the first, so it can only be matched through
      // the table entries the first chunk left behind.
      final half = _random(3, 150000);
      final input = Uint8List(300000)
        ..setRange(0, 150000, half)
        ..setRange(150000, 300000, half);
      // Random bytes hash into nearly every bucket of the one-shot's table.
      final noise = _random(7, 150000);
      const options = BrotliEncodeOptions(quality: 9);

      Uint8List stream({required bool interleave}) {
        final encoder = StreamingEncoder(options)
          ..add(Uint8List.sublistView(input, 0, 150000))
          ..flush();
        if (interleave) brotliEncode(noise, quality: 9);
        encoder
          ..add(Uint8List.sublistView(input, 150000))
          ..finish();
        return encoder.takeOutput();
      }

      final undisturbed = stream(interleave: false);
      // A shared table would still yield a valid stream (candidates are
      // verified against the input), just a different one: compare bytes.
      final interleaved = stream(interleave: true);
      expect(interleaved, orderedEquals(undisturbed));
      expect(brotliDecode(interleaved), orderedEquals(input));
    });
  });
}
