/// Public one-shot API: `brotliEncode` / `brotliDecode` / `BrotliDictionary`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:test/test.dart';

import '../benchmark/corpus.dart';

void main() {
  final text = makeText(200000);
  final binary = makeBinary(200000);

  group('round trip', () {
    for (var quality = 0; quality <= 11; quality++) {
      test('quality $quality on text and binary', () {
        for (final input in [text, binary]) {
          final packed = brotliEncode(input, quality: quality);
          expect(packed.length, lessThan(input.length));
          expect(brotliDecode(packed), orderedEquals(input));
        }
      });
    }

    test('window sizes 10..24', () {
      final input = makeText(50000);
      for (var windowBits = 10; windowBits <= 24; windowBits++) {
        final packed = brotliEncode(input, windowBits: windowBits);
        expect(
          brotliDecode(packed),
          orderedEquals(input),
          reason: '$windowBits',
        );
      }
    });

    test('empty and tiny inputs', () {
      for (final input in <List<int>>[
        <int>[],
        <int>[0],
        <int>[1, 2, 3],
        List<int>.filled(17, 0x41),
      ]) {
        for (final quality in <int>[0, 1, 5, 9, 11]) {
          final packed = brotliEncode(input, quality: quality);
          expect(brotliDecode(packed), orderedEquals(input));
        }
      }
      expect(brotliEncode(const <int>[]), orderedEquals(<int>[0x06]));
    });

    test('accepts any List<int>, not only Uint8List', () {
      final input = utf8.encode('hello brotli ' * 50).toList();
      expect(input, isNot(isA<Uint8List>()));
      expect(brotliDecode(brotliEncode(input).toList()), orderedEquals(input));
    });

    test('incompressible input stays close to its size', () {
      var seed = 1;
      final noise = Uint8List.fromList(
        List<int>.generate(100000, (_) {
          seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
          return (seed >> 16) & 0xFF;
        }),
      );
      for (final quality in <int>[0, 5, 9]) {
        final packed = brotliEncode(noise, quality: quality);
        expect(packed.length, lessThan(noise.length + 64));
        expect(brotliDecode(packed), orderedEquals(noise));
      }
    });

    test('higher qualities compress text at least as well as quality 5', () {
      final q5 = brotliEncode(text, quality: 5).length;
      expect(brotliEncode(text, quality: 9).length, lessThanOrEqualTo(q5));
      expect(brotliEncode(text, quality: 11).length, lessThanOrEqualTo(q5));
    });
  });

  group('arguments', () {
    test('quality must be 0..11', () {
      expect(() => brotliEncode(text, quality: -1), throwsRangeError);
      expect(() => brotliEncode(text, quality: 12), throwsRangeError);
    });

    test('windowBits must be 10..30', () {
      expect(() => brotliEncode(text, windowBits: 9), throwsRangeError);
      expect(() => brotliEncode(text, windowBits: 31), throwsRangeError);
    });
  });

  group('decoding errors', () {
    final packed = brotliEncode(text);

    test('truncated stream', () {
      expect(
        () =>
            brotliDecode(Uint8List.sublistView(packed, 0, packed.length ~/ 2)),
        throwsA(isA<BrotliException>()),
      );
    });

    test('garbage input', () {
      expect(
        () => brotliDecode(Uint8List.fromList(List<int>.filled(64, 0xFF))),
        throwsA(isA<BrotliException>()),
      );
    });

    test('BrotliException is a FormatException', () {
      expect(
        () => brotliDecode(const <int>[0xFF, 0xFF]),
        throwsA(isA<FormatException>()),
      );
    });

    test('maxOutputSize guards against oversized output', () {
      expect(
        () => brotliDecode(packed, maxOutputSize: 1000),
        throwsA(
          isA<BrotliException>().having(
            (e) => e.code,
            'code',
            BrotliErrorCode.outputLimitExceeded,
          ),
        ),
      );
      expect(
        brotliDecode(packed, maxOutputSize: text.length),
        orderedEquals(text),
      );
    });

    test('decodes output larger than the initial buffer guess', () {
      final big = makeText(3 << 20);
      expect(brotliDecode(brotliEncode(big, quality: 1)), orderedEquals(big));
    });
  });

  group('dictionary', () {
    final dictionary = BrotliDictionary(
      utf8.encode('{"id":0,"name":"","email":"","active":true,"roles":[]}' * 4),
    );
    final record = Uint8List.fromList(
      utf8.encode(
        '{"id":42,"name":"Ada","email":"ada@example.com",'
        '"active":true,"roles":["admin"]}',
      ),
    );

    test('round trips and shrinks small records', () {
      for (final quality in <int>[5, 9, 11]) {
        final plain = brotliEncode(record, quality: quality);
        final withDict = brotliEncode(
          record,
          quality: quality,
          dictionary: dictionary,
        );
        expect(withDict.length, lessThan(plain.length), reason: 'q$quality');
        expect(
          brotliDecode(withDict, dictionary: dictionary),
          orderedEquals(record),
        );
      }
    });

    test('one instance can be reused for many encodes', () {
      for (var i = 0; i < 5; i++) {
        final input = Uint8List.fromList(
          utf8.encode('{"id":$i,"name":"user$i","active":true,"roles":[]}'),
        );
        final packed = brotliEncode(input, quality: 9, dictionary: dictionary);
        expect(
          brotliDecode(packed, dictionary: dictionary),
          orderedEquals(input),
        );
      }
    });

    test('copies non-Uint8List bytes and exposes its length', () {
      final source = <int>[1, 2, 3, 4];
      final d = BrotliDictionary(source);
      source[0] = 9;
      expect(d.bytes, orderedEquals(<int>[1, 2, 3, 4]));
      expect(d.length, 4);
    });
  });

  group('large window', () {
    final input = makeText(100000);

    test('needs an explicit opt-in to decode', () {
      final packed = brotliEncode(input, windowBits: 25);
      expect(() => brotliDecode(packed), throwsA(isA<BrotliException>()));
      expect(
        brotliDecode(packed, allowLargeWindow: true),
        orderedEquals(input),
      );
    });

    test('regular streams decode with the opt-in too', () {
      expect(
        brotliDecode(brotliEncode(input), allowLargeWindow: true),
        orderedEquals(input),
      );
    });
  });
}
