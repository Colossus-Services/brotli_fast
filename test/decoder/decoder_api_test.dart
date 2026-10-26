/// Decoder entry points: one-shot `brotliDecode` / `decode` and the
/// [StreamingDecoder] over chunked input and bounded output slices.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:brotli_fast/src/decoder/decoder.dart';
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

import '../support/corpus.dart';
import 'decoder_helpers.dart';

void main() {
  final corpus = Corpus.load();
  CorpusEntry entry(String name) =>
      corpus.entries.firstWhere((e) => e.name == name);

  group('brotliDecode (one-shot)', () {
    test('every corpus pair is byte-exact', () {
      for (final e in corpus.entries) {
        expectBytes(
          brotliDecode(corpus.compressedBytes(e)),
          corpus.rawBytes(e),
          e.name,
        );
      }
    });

    test('List<int> input is accepted', () {
      final e = entry('quickfox');
      expectBytes(
        brotliDecode(corpus.compressedBytes(e).toList()),
        corpus.rawBytes(e),
        'List<int>',
      );
    });

    test('empty input is reported as truncated', () {
      expect(
        () => brotliDecode(Uint8List(0)),
        throwsBrotli(BrotliErrorCode.truncatedInput),
      );
    });

    test('every proper prefix of a real stream throws', () {
      for (final name in <String>['quickfox', 'monkey', 'random_org_10k.bin']) {
        final compressed = corpus.compressedBytes(entry(name));
        final step = compressed.length > 1000 ? 97 : 1;
        for (var length = 0; length < compressed.length; length += step) {
          expect(
            () => brotliDecode(Uint8List.sublistView(compressed, 0, length)),
            throwsBrotli(),
            reason: '$name prefix of $length bytes',
          );
        }
      }
    });

    test('trailing bytes are rejected by the strict one-shot API', () {
      for (final name in <String>['empty', 'quickfox', 'alice29.txt']) {
        final compressed = corpus.compressedBytes(entry(name));
        final withGarbage = Uint8List(compressed.length + 1)
          ..setRange(0, compressed.length, compressed);
        expect(
          () => brotliDecode(withGarbage),
          throwsBrotli(BrotliErrorCode.unusedBytesAfterEnd),
          reason: name,
        );
      }
    });

    test('maxOutputSize is enforced by the one-shot API', () {
      for (final name in <String>['10x10y', 'alice29.txt', 'zeros']) {
        final e = entry(name);
        expect(
          () => brotliDecode(
            corpus.compressedBytes(e),
            maxOutputSize: e.rawBytes - 1,
          ),
          throwsBrotli(BrotliErrorCode.outputLimitExceeded),
          reason: name,
        );
        expectBytes(
          brotliDecode(corpus.compressedBytes(e), maxOutputSize: e.rawBytes),
          corpus.rawBytes(e),
          '$name exact output limit',
        );
      }
    });

    test('output larger than the first allocation grows the buffer', () {
      // decode() starts with a ~1 MiB buffer and doubles it on overflow.
      final input = Uint8List(3 << 20);
      for (var i = 0; i < input.length; i++) {
        input[i] = (i * 7 + (i >> 12)) & 0xFF;
      }
      final compressed = brotliEncode(input, quality: 1);
      expectBytes(brotliDecode(compressed), input, 'default limit');
      expectBytes(brotliDecode(compressed, maxOutputSize: null), input, 'null');
      expectBytes(
        decode(compressed, maxOutputSize: input.length),
        input,
        'exact limit',
      );
      expect(
        () => decode(compressed, maxOutputSize: input.length - 1),
        throwsBrotli(BrotliErrorCode.outputLimitExceeded),
      );
    });

    test('large window: lgwin 25 requires and honours allowLargeWindow', () {
      final source = Uint8List(256 * 1024);
      for (var i = 0; i < source.length; i++) {
        source[i] = (i * 31 + (i >> 8)) & 0xFF;
      }
      final compressed = brotliEncode(source, windowBits: 25);
      expect(
        () => brotliDecode(compressed),
        throwsBrotli(BrotliErrorCode.invalidWindowBits),
      );
      expectBytes(
        brotliDecode(compressed, allowLargeWindow: true),
        source,
        'lgwin 25',
      );
      expectBytes(
        streamDecode(
          compressed,
          inputChunk: 4096,
          outputChunk: 1000,
          allowLargeWindow: true,
        ),
        source,
        'lgwin 25 streaming',
      );
    });

    test('standard streams decode with allowLargeWindow enabled', () {
      final e = entry('alice29.txt');
      expectBytes(
        brotliDecode(corpus.compressedBytes(e), allowLargeWindow: true),
        corpus.rawBytes(e),
        'alice29 allowLargeWindow',
      );
    });
  });

  group('StreamingDecoder', () {
    const matrixVectors = <String>[
      'empty',
      'x',
      '10x10y',
      'quickfox',
      'monkey',
      'zerosukkanooa',
      'alice29.txt',
    ];

    test('chunk x output-size matrix on representative vectors', () {
      const chunkSizes = <int>[1, 2, 3, 7, 17, 4095, 4096, 4097, 65536];
      const outputSizes = <int>[1, 7, 65536, 1 << 20];
      for (final name in matrixVectors) {
        final e = entry(name);
        final compressed = corpus.compressedBytes(e);
        final raw = corpus.rawBytes(e);
        // Byte-at-a-time output on the big vector is covered by the 1-byte
        // input row and the core tests; keep the matrix fast.
        final big = raw.length > 100000;
        for (final inputChunk in chunkSizes) {
          for (final outputChunk in outputSizes) {
            if (big && outputChunk == 1 && inputChunk != 1) {
              continue;
            }
            expectBytes(
              streamDecode(
                compressed,
                inputChunk: inputChunk,
                outputChunk: outputChunk,
              ),
              raw,
              '$name input=$inputChunk output=$outputChunk',
            );
          }
        }
      }
    });

    test('matrix on the remaining vectors', () {
      for (final e in corpus.entries) {
        if (matrixVectors.contains(e.name)) {
          continue;
        }
        final compressed = corpus.compressedBytes(e);
        final raw = corpus.rawBytes(e);
        for (final inputChunk in <int>[1, 4096, 65536]) {
          for (final outputChunk in <int>[7, 65536]) {
            expectBytes(
              streamDecode(
                compressed,
                inputChunk: inputChunk,
                outputChunk: outputChunk,
              ),
              raw,
              '${e.name} input=$inputChunk output=$outputChunk',
            );
          }
        }
      }
    });

    test('decode honours the output slice', () {
      final decoder = StreamingDecoder()
        ..addInput(corpus.compressedBytes(entry('x')))
        ..closeInput();
      final out = Uint8List(8)..fillRange(0, 8, 0xEE);
      expect(decoder.decode(out, 3, 5), BrotliStatus.done);
      expect(decoder.bytesWritten, 1);
      expect(out, <int>[0xEE, 0xEE, 0xEE, 0x58, 0xEE, 0xEE, 0xEE, 0xEE]);
    });

    test('decode validates the output slice', () {
      final decoder = StreamingDecoder();
      expect(() => decoder.decode(Uint8List(8), 5, 2), throwsRangeError);
      expect(() => decoder.decode(Uint8List(8), -1), throwsRangeError);
    });

    test('needMoreInput until input arrives, done after closeInput', () {
      final compressed = corpus.compressedBytes(entry('quickfox'));
      final decoder = StreamingDecoder();
      final out = Uint8List(256);
      expect(decoder.decode(out), BrotliStatus.needMoreInput);
      expect(decoder.bytesWritten, 0);
      decoder.addInput(compressed);
      // All input is present but not closed: the decoder may still finish,
      // since the stream itself marks its end.
      final status = decoder.decode(out);
      final first = decoder.bytesWritten;
      if (status != BrotliStatus.done) {
        expect(status, BrotliStatus.needMoreInput);
        decoder.closeInput();
        expect(decoder.decode(out, first), BrotliStatus.done);
      }
      expect(decoder.consumedInput, compressed.length);
    });

    test('addInput copies the caller buffer', () {
      final compressed = corpus.compressedBytes(entry('quickfox'));
      final scratch = Uint8List.fromList(compressed);
      final decoder = StreamingDecoder()..addInput(scratch);
      scratch.fillRange(0, scratch.length, 0xFF);
      decoder.closeInput();
      final out = Uint8List(1024);
      expect(decoder.decode(out), BrotliStatus.done);
      expectBytes(
        out.sublist(0, decoder.bytesWritten),
        corpus.rawBytes(entry('quickfox')),
        'copied input',
      );
    });

    test('addInput after closeInput throws StateError', () {
      final decoder = StreamingDecoder()..closeInput();
      expect(
        () => decoder.addInput(Uint8List.fromList(<int>[0])),
        throwsStateError,
      );
    });

    test('closed input that ends early is reported as truncated', () {
      final compressed = corpus.compressedBytes(entry('alice29.txt'));
      final decoder = StreamingDecoder()
        ..addInput(Uint8List.sublistView(compressed, 0, compressed.length ~/ 2))
        ..closeInput();
      final out = Uint8List(64 * 1024);
      expect(() {
        while (decoder.decode(out) != BrotliStatus.done) {}
      }, throwsBrotli(BrotliErrorCode.truncatedInput));
    });

    test('maxOutputSize is enforced while streaming', () {
      final e = entry('zeros');
      expect(
        () => streamDecode(
          corpus.compressedBytes(e),
          inputChunk: 4096,
          outputChunk: 1024,
          maxOutputSize: e.rawBytes - 1,
        ),
        throwsBrotli(BrotliErrorCode.outputLimitExceeded),
      );
      expectBytes(
        streamDecode(
          corpus.compressedBytes(e),
          inputChunk: 4096,
          outputChunk: 1024,
          maxOutputSize: e.rawBytes,
        ),
        corpus.rawBytes(e),
        'exact streaming limit',
      );
    });

    test('done is idempotent and extra input is ignored', () {
      final decoder = StreamingDecoder()
        ..addInput(corpus.compressedBytes(entry('x')))
        ..closeInput();
      final out = Uint8List(8);
      expect(decoder.decode(out), BrotliStatus.done);
      expect(decoder.bytesWritten, 1);
      final consumedAfterDone = decoder.consumedInput;
      for (var i = 0; i < 3; i++) {
        expect(decoder.decode(out), BrotliStatus.done);
        expect(decoder.bytesWritten, 0);
      }
      expect(
        () => decoder.addInput(Uint8List.fromList(<int>[1, 2, 3])),
        throwsStateError,
      );
      expect(decoder.consumedInput, consumedAfterDone);
      expect(decoder.decode(out), BrotliStatus.done);
      expect(decoder.bytesWritten, 0);
    });

    test('interleaved decoders do not share state', () {
      final a = entry('alice29.txt');
      final b = entry('plrabn12.txt');
      // Any earlier decode leaves allocations behind; make that explicit so
      // the test does not depend on test order.
      brotliDecode(corpus.compressedBytes(entry('lcet10.txt')));
      final decoderA = StreamingDecoder()
        ..addInput(corpus.compressedBytes(a))
        ..closeInput();
      final decoderB = StreamingDecoder()
        ..addInput(corpus.compressedBytes(b))
        ..closeInput();
      final outA = BytesBuilder(copy: false);
      final outB = BytesBuilder(copy: false);
      final buffer = Uint8List(4096);
      var doneA = false;
      var doneB = false;
      while (!doneA || !doneB) {
        if (!doneA) {
          doneA = decoderA.decode(buffer) == BrotliStatus.done;
          outA.add(buffer.sublist(0, decoderA.bytesWritten));
        }
        if (!doneB) {
          doneB = decoderB.decode(buffer) == BrotliStatus.done;
          outB.add(buffer.sublist(0, decoderB.bytesWritten));
        }
      }
      expectBytes(outA.takeBytes(), corpus.rawBytes(a), a.name);
      expectBytes(outB.takeBytes(), corpus.rawBytes(b), b.name);
    });

    test('a one-shot decode between streaming calls does not disturb it', () {
      final a = entry('alice29.txt');
      brotliDecode(corpus.compressedBytes(entry('lcet10.txt')));
      final decoder = StreamingDecoder()
        ..addInput(corpus.compressedBytes(a))
        ..closeInput();
      final out = BytesBuilder(copy: false);
      final buffer = Uint8List(8192);
      var calls = 0;
      while (true) {
        final status = decoder.decode(buffer);
        out.add(buffer.sublist(0, decoder.bytesWritten));
        if (status == BrotliStatus.done) {
          break;
        }
        if (calls++ % 4 == 0) {
          brotliDecode(corpus.compressedBytes(entry('lcet10.txt')));
        }
      }
      expectBytes(out.takeBytes(), corpus.rawBytes(a), a.name);
    });
  });
}
