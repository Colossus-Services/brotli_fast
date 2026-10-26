/// Interoperability with the reference implementation (google/brotli CLI).
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:test/test.dart';

import '../benchmark/corpus.dart';
import 'support/brotli_cli.dart';

void main() {
  final inputs = <String, Uint8List>{
    'text': makeText(200000),
    'binary': makeBinary(200000),
    'alice29': File('test/testdata/alice29.txt').readAsBytesSync(),
    'mapsdatazrh': File('test/testdata/mapsdatazrh').readAsBytesSync(),
    'tiny': Uint8List.fromList(<int>[1, 2, 3]),
  };

  group('reference decoder reads our streams', skip: brotliCliSkipReason(), () {
    for (var quality = 0; quality <= 11; quality++) {
      test('quality $quality', () async {
        for (final MapEntry(:key, :value) in inputs.entries) {
          final packed = brotliEncode(value, quality: quality);
          expect(
            await cliDecompress(packed),
            orderedEquals(value),
            reason: key,
          );
        }
      });
    }

    test('window sizes', () async {
      final input = inputs['text']!;
      for (final windowBits in <int>[10, 16, 18, 24]) {
        for (final quality in <int>[1, 5, 9]) {
          final packed = brotliEncode(
            input,
            quality: quality,
            windowBits: windowBits,
          );
          expect(
            await cliDecompress(packed),
            orderedEquals(input),
            reason: 'w$windowBits q$quality',
          );
        }
      }
    });

    test('dictionary', () async {
      final dictionary = BrotliDictionary(makeText(20000));
      final input = makeText(60000);
      for (final quality in <int>[5, 9, 11]) {
        final packed = brotliEncode(
          input,
          quality: quality,
          dictionary: dictionary,
        );
        expect(
          await cliDecompress(packed, dictionary: dictionary.bytes),
          orderedEquals(input),
          reason: 'q$quality',
        );
      }
    });

    test('large window', () async {
      final input = inputs['text']!;
      final packed = brotliEncode(input, quality: 9, windowBits: 26);
      expect(
        await cliDecompress(packed, largeWindow: true),
        orderedEquals(input),
      );
    });
  });

  group('we read reference streams', skip: brotliCliSkipReason(), () {
    for (final quality in <int>[0, 1, 2, 4, 5, 6, 9, 11]) {
      test('quality $quality', () async {
        for (final MapEntry(:key, :value) in inputs.entries) {
          final packed = await cliCompress(value, quality: quality);
          expect(brotliDecode(packed), orderedEquals(value), reason: key);
        }
      });
    }

    test('window sizes', () async {
      final input = inputs['binary']!;
      for (final windowBits in <int>[10, 16, 24]) {
        final packed = await cliCompress(input, windowBits: windowBits);
        expect(
          brotliDecode(packed),
          orderedEquals(input),
          reason: '$windowBits',
        );
      }
    });

    test('dictionary', () async {
      final dictionary = BrotliDictionary(makeText(20000));
      final input = makeText(60000);
      final packed = await cliCompress(
        input,
        quality: 9,
        dictionary: dictionary.bytes,
      );
      expect(
        brotliDecode(packed, dictionary: dictionary),
        orderedEquals(input),
      );
    });

    test('large window', () async {
      final input = inputs['text']!;
      final packed = await cliCompress(input, quality: 9, windowBits: 26);
      expect(
        brotliDecode(packed, allowLargeWindow: true),
        orderedEquals(input),
      );
    });
  });
}
