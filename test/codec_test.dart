/// `dart:convert` codec and chunked (stream) conversion.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:test/test.dart';

import '../benchmark/corpus.dart';

/// Splits [bytes] into chunks of [size] bytes.
Stream<List<int>> _chunked(List<int> bytes, int size) async* {
  for (var i = 0; i < bytes.length; i += size) {
    yield bytes.sublist(i, i + size < bytes.length ? i + size : bytes.length);
  }
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

void main() {
  final text = makeText(400000);
  final binary = makeBinary(300000);

  group('BrotliCodec', () {
    test('brotli encodes and decodes like the functions', () {
      final packed = brotli.encode(text);
      expect(packed, orderedEquals(brotliEncode(text)));
      expect(brotli.decode(packed), orderedEquals(text));
    });

    test('settings reach both directions', () {
      final dictionary = BrotliDictionary(makeText(5000));
      final codec = BrotliCodec(quality: 9, dictionary: dictionary);
      final packed = codec.encode(text);
      expect(
        packed,
        orderedEquals(brotliEncode(text, quality: 9, dictionary: dictionary)),
      );
      expect(codec.decode(packed), orderedEquals(text));
    });

    test('a large window codec decodes its own streams', () {
      const codec = BrotliCodec(windowBits: 26);
      expect(codec.decode(codec.encode(text)), orderedEquals(text));
    });

    test('fuses with utf8 for strings', () {
      final codec = utf8.fuse(brotli);
      const message = 'Olá, Brotli! 你好 🚀';
      expect(codec.decode(codec.encode(message * 20)), message * 20);
    });

    test('maxOutputSize applies to decoding', () {
      const codec = BrotliCodec(maxOutputSize: 100);
      expect(
        () => codec.decode(brotli.encode(text)),
        throwsA(isA<BrotliException>()),
      );
    });
  });

  group('streams', () {
    for (final quality in <int>[0, 1, 5, 9]) {
      test('encode transformer round trips at quality $quality', () async {
        for (final input in [text, binary]) {
          final packed = await _collect(
            _chunked(input, 7919).transform(BrotliEncoder(quality: quality)),
          );
          expect(brotliDecode(packed), orderedEquals(input));
        }
      });
    }

    test('encoder emits output before the input ends', () async {
      final controller = StreamController<List<int>>();
      final outputs = <List<int>>[];
      final done = controller.stream
          .transform(brotli.encoder)
          .listen(outputs.add)
          .asFuture<void>();
      // Two full 128 KiB blocks: both must be emitted while still open.
      controller.add(makeText(300000));
      await Future<void>.delayed(Duration.zero);
      expect(outputs, isNotEmpty);
      await controller.close();
      await done;
    });

    test('decode transformer round trips with tiny chunks', () async {
      final packed = brotliEncode(text, quality: 9);
      for (final size in <int>[1, 13, 4096]) {
        final restored = await _collect(
          _chunked(packed, size).transform(brotli.decoder),
        );
        expect(restored, orderedEquals(text), reason: 'chunk size $size');
      }
    });

    test(
      'decode transformer handles the dictionary and large window',
      () async {
        final dictionary = BrotliDictionary(makeText(5000));
        final codec = BrotliCodec(
          quality: 9,
          windowBits: 25,
          dictionary: dictionary,
        );
        final restored = await _collect(
          _chunked(codec.encode(text), 1000).transform(codec.decoder),
        );
        expect(restored, orderedEquals(text));
      },
    );

    test('concurrent decode streams do not interfere', () async {
      final otherInput = makeBinary(300000);
      final packedA = brotliEncode(text, quality: 9);
      final packedB = brotliEncode(otherInput, quality: 9);
      // A finished one-shot decode leaves its window for reuse; both streams
      // start after it, so a shared window would corrupt them.
      brotliDecode(packedB);
      // Interleave the chunks of both streams on the event loop, with another
      // one-shot decode in between.
      final results = await Future.wait([
        _collect(_chunked(packedA, 997).transform(brotli.decoder)),
        _collect(_chunked(packedB, 1013).transform(brotli.decoder)),
        Future(() => brotliDecode(packedA)),
      ]);
      expect(results[0], orderedEquals(text));
      expect(results[1], orderedEquals(otherInput));
      expect(results[2], orderedEquals(text));
    });

    test('a truncated stream fails with BrotliException', () async {
      final packed = brotliEncode(text);
      final truncated = packed.sublist(0, packed.length - 10);
      await expectLater(
        _collect(_chunked(truncated, 1000).transform(brotli.decoder)),
        throwsA(
          isA<BrotliException>().having(
            (e) => e.code,
            'code',
            BrotliErrorCode.truncatedInput,
          ),
        ),
      );
    });

    test('trailing data is rejected however it is chunked', () async {
      final packed = brotliEncode(text);
      final withTrailer = [...packed, 1, 2, 3];
      // Trailer in the final chunk, and trailer in a chunk of its own.
      for (final size in <int>[1000, packed.length]) {
        await expectLater(
          _collect(_chunked(withTrailer, size).transform(brotli.decoder)),
          throwsA(
            isA<BrotliException>().having(
              (e) => e.code,
              'code',
              BrotliErrorCode.unusedBytesAfterEnd,
            ),
          ),
          reason: 'chunk size $size',
        );
      }
      expect(() => brotliDecode(withTrailer), throwsA(isA<BrotliException>()));
    });

    test('maxOutputSize applies while streaming', () async {
      await expectLater(
        _collect(
          _chunked(
            brotliEncode(text),
            1000,
          ).transform(const BrotliDecoder(maxOutputSize: 1000)),
        ),
        throwsA(isA<BrotliException>()),
      );
    });
  });
}
