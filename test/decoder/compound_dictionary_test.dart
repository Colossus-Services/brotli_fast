/// Compound ("raw" / prepended) dictionary support.
///
/// The committed fixtures under `compound_vectors/` were produced by the Rust
/// `brotli` crate 9.0.0 with its `compress --dictionary FILE` path (see the
/// README there). `window` exercises a 6 KiB dictionary with an lgwin 10
/// stream (the ring window is 1 KiB), so the compound copy and the ring flushes
/// both matter.
///
/// The CLI tests regenerate the same kind of stream with the reference
/// `brotli -D` encoder; they are skipped when the CLI is missing.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:brotli_fast/src/decoder/decoder_metablock.dart'
    show isCompoundDictionaryDistance, staticDictionaryAddress;
import 'package:test/test.dart';

import '../support/brotli_cli.dart';
import '../support/corpus.dart';
import 'decoder_helpers.dart';

/// One compressed stream plus the dictionary/plaintext it belongs to.
final class _Vector {
  _Vector({
    required this.name,
    required this.dictionary,
    required this.raw,
    required this.compressed,
  });

  final String name;
  final Uint8List dictionary;
  final Uint8List raw;
  final Uint8List compressed;
}

Uint8List _fixture(String name) =>
    File('test/decoder/compound_vectors/$name').readAsBytesSync();

bool _equalBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

Uint8List _decode(Uint8List compressed, Uint8List? dictionary) => brotliDecode(
  compressed,
  dictionary: dictionary == null ? null : BrotliDictionary(dictionary),
);

/// Deterministic pseudo-random fixture bytes (dictionary contents).
Uint8List _deterministicBytes(int length, {required int seed}) {
  final bytes = Uint8List(length);
  var state = (seed * 2654435761 + 1) & 0xFFFFFFFF;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0xFFFFFFFF;
    bytes[i] = (state >> 16) & 0xFF;
  }
  return bytes;
}

void main() {
  final text = _Vector(
    name: 'text',
    dictionary: _fixture('text.dict'),
    raw: _fixture('text.raw'),
    compressed: _fixture('text.br'),
  );
  final windowed = _Vector(
    name: 'window',
    dictionary: _fixture('window.dict'),
    raw: _fixture('window.raw'),
    compressed: _fixture('window.br'),
  );
  final vectors = <_Vector>[text, windowed];

  group('fixtures: one-shot', () {
    for (final vector in vectors) {
      test('${vector.name} decodes byte-exactly with its dictionary', () {
        expectBytes(
          _decode(vector.compressed, vector.dictionary),
          vector.raw,
          vector.name,
        );
      });
    }

    test('dictionary is larger than the lgwin 10 ring window', () {
      expect(windowed.dictionary.length, greaterThan(1 << 10));
      expect(windowed.compressed.length, lessThan(64));
    });

    test('dictionary references are actually exercised', () {
      final run = decodeCore(
        text.compressed,
        compoundDictionary: text.dictionary,
      );
      expectBytes(run.bytes, text.raw, 'text compound refs');
      expect(run.state.compoundDictionaryReferenceCount, greaterThan(0));
    });
  });

  group('chunked input and output', () {
    for (final vector in vectors) {
      test('${vector.name}: input 1/2/3/7/4096 x output 1/3/17/4096', () {
        for (final inputChunk in <int>[1, 2, 3, 7, 4096]) {
          for (final outputChunk in <int>[1, 3, 17, 4096]) {
            final label = '${vector.name} in=$inputChunk out=$outputChunk';
            final result = decodeCoreChunked(
              vector.compressed,
              inputChunk: inputChunk,
              outputChunk: outputChunk,
              compoundDictionary: vector.dictionary,
            );
            expectBytes(result.bytes, vector.raw, label);
            expect(
              result.state.compoundDictionaryReferenceCount,
              greaterThan(0),
              reason: label,
            );
          }
        }
        expectBytes(
          streamDecode(
            vector.compressed,
            inputChunk: 3,
            outputChunk: 5,
            compoundDictionary: vector.dictionary,
          ),
          vector.raw,
          '${vector.name} StreamingDecoder',
        );
      });
    }
  });

  group('missing / wrong dictionary', () {
    for (final vector in vectors) {
      test('${vector.name}: missing, empty and 1-byte dictionaries throw', () {
        for (final (label, dictionary) in <(String, Uint8List?)>[
          ('missing', null),
          ('empty', Uint8List(0)),
          ('one byte', Uint8List.fromList(<int>[0x42])),
        ]) {
          expect(
            () => _decode(vector.compressed, dictionary),
            throwsBrotli(),
            reason: '${vector.name}/$label',
          );
        }
      });
    }

    test('streaming decoder throws for a missing dictionary, not crashes', () {
      expect(
        () => streamDecode(text.compressed, inputChunk: 4096, outputChunk: 64),
        throwsBrotli(),
      );
    });

    test('truncated dictionary with changed addressing throws', () {
      final half = Uint8List.sublistView(
        text.dictionary,
        0,
        text.dictionary.length ~/ 2,
      );
      expect(() => _decode(text.compressed, half), throwsBrotli());
    });

    test('maxOutputSize still caps compound-dictionary output', () {
      expect(
        () => brotliDecode(
          windowed.compressed,
          dictionary: BrotliDictionary(windowed.dictionary),
          maxOutputSize: 128,
        ),
        throwsBrotli(BrotliErrorCode.outputLimitExceeded),
      );
    });

    test(
      'same-length wrong dictionary changes output (no integrity check)',
      () {
        for (final vector in vectors) {
          final wrong = Uint8List.fromList(
            List<int>.generate(
              vector.dictionary.length,
              (i) => (i * 131 + 29) & 0xFF,
            ),
          );
          final decoded = _decode(vector.compressed, wrong);
          expect(decoded.length, vector.raw.length, reason: vector.name);
          expect(
            _equalBytes(decoded, vector.raw),
            isFalse,
            reason: '${vector.name}: wrong dictionary must change the bytes',
          );
        }
      },
    );
  });

  group('non-dictionary streams are unaffected', () {
    final corpus = Corpus.load();
    final quickfox = corpus.entries.firstWhere((e) => e.name == 'quickfox');

    test('attached dictionary is harmless for streams that ignore it', () {
      final plain = _decode(corpus.compressedBytes(quickfox), null);
      expectBytes(plain, corpus.rawBytes(quickfox), 'quickfox');
      for (final dictionary in <Uint8List>[
        Uint8List(0),
        Uint8List.fromList(<int>[0x42]),
        text.dictionary,
      ]) {
        expectBytes(
          _decode(corpus.compressedBytes(quickfox), dictionary),
          plain,
          'quickfox + ${dictionary.length}-byte dictionary',
        );
      }
    });

    test('our encoder output round-trips with a dictionary attached', () {
      final input = Uint8List.fromList(
        List<int>.generate(4096, (i) => (i * 17 + 3 + (i >> 4)) & 0xFF),
      );
      final compressed = brotliEncode(input, quality: 5);
      for (final dictionary in <Uint8List?>[
        null,
        Uint8List(0),
        text.dictionary,
      ]) {
        expectBytes(_decode(compressed, dictionary), input, 'self round-trip');
      }
    });
  });

  group('API plumbing', () {
    test('BrotliCodec one-shot and chunked conversion honour the option', () {
      final codec = BrotliCodec(dictionary: BrotliDictionary(text.dictionary));
      expectBytes(codec.decode(text.compressed), text.raw, 'codec.decode');
      expectBytes(
        codec.decoder.convert(text.compressed),
        text.raw,
        'decoder.convert',
      );

      final output = BytesBuilder(copy: false);
      final conversion = codec.decoder.startChunkedConversion(
        ByteConversionSink.withCallback(output.add),
      );
      for (var i = 0; i < text.compressed.length; i++) {
        conversion.add(<int>[text.compressed[i]]);
      }
      conversion.close();
      expectBytes(output.takeBytes(), text.raw, 'codec chunked');
    });
  });

  group('reference-encoder streams', () {
    test('brotli -D then decode byte-exactly', () async {
      final dictionary = _deterministicBytes(3000, seed: 7);
      final raw = Uint8List.fromList(<int>[
        ...dictionary.sublist(800, 2000),
        ...'tail that is not in the dictionary'.codeUnits,
        ...dictionary.sublist(2400, 3000),
      ]);
      final compressed = await cliCompress(raw, dictionary: dictionary);
      // The reference decoder must agree with the raw input first.
      expectBytes(
        await cliDecompress(compressed, dictionary: dictionary),
        raw,
        'reference decompress',
      );

      expectBytes(_decode(compressed, dictionary), raw, 'default window');
      expect(() => _decode(compressed, null), throwsBrotli());
      final streamed = decodeCoreChunked(
        compressed,
        inputChunk: 3,
        outputChunk: 5,
        compoundDictionary: dictionary,
      );
      expectBytes(streamed.bytes, raw, 'default window streaming');
      expect(streamed.state.compoundDictionaryReferenceCount, greaterThan(0));
    });

    test('lgwin 10 with a dictionary larger than the ring window', () async {
      final dictionary = _deterministicBytes(6144, seed: 11);
      final raw = Uint8List.fromList(<int>[
        for (var i = 0; i < 5; i++) ...dictionary.sublist(5244, 6144),
        ...'END'.codeUnits,
      ]);
      final compressed = await cliCompress(
        raw,
        windowBits: 10,
        dictionary: dictionary,
      );
      expectBytes(
        await cliDecompress(compressed, dictionary: dictionary),
        raw,
        'reference decompress',
      );

      expectBytes(_decode(compressed, dictionary), raw, 'lgwin 10');
      final streamed = decodeCoreChunked(
        compressed,
        inputChunk: 1,
        outputChunk: 7,
        compoundDictionary: dictionary,
      );
      expectBytes(streamed.bytes, raw, 'lgwin 10 streaming');
      expect(streamed.state.compoundDictionaryReferenceCount, greaterThan(0));
    });

    test('text dictionary with static-dictionary words at q5/q11', () async {
      // Unlike the Rust encoder, the reference encoder keeps the RFC static
      // dictionary when a raw dictionary is attached, so both address ranges
      // (compound, then static shifted by the compound size) are exercised.
      final dictionary = Uint8List.fromList(
        utf8.encode(
          List<String>.generate(
            60,
            (i) => '{"id": $i, "name": "item-$i", "tags": ["alpha", "beta"]}',
          ).join('\n'),
        ),
      );
      final raw = Uint8List.fromList(
        utf8.encode(
          '${List<String>.generate(40, (i) => '{"id": ${i * 3}, "name": '
              '"item-${i * 7}", "tags": ["beta"]} because the government '
              'announced information about international development').join(',')}\n',
        ),
      );
      for (final quality in <int>[5, 11]) {
        final compressed = await cliCompress(
          raw,
          quality: quality,
          dictionary: dictionary,
        );
        final run = decodeCore(compressed, compoundDictionary: dictionary);
        expectBytes(run.bytes, raw, 'q$quality');
        expect(run.state.compoundDictionaryReferenceCount, greaterThan(0));
        expect(run.state.dictionaryReferenceCount, greaterThan(0));
        expectBytes(
          streamDecode(
            compressed,
            inputChunk: 5,
            outputChunk: 11,
            compoundDictionary: dictionary,
          ),
          raw,
          'q$quality streaming',
        );
      }
    });
  }, skip: brotliCliSkipReason());

  group('dictionary address arithmetic', () {
    test('compound range is (maxDistance, maxDistance + size]', () {
      expect(isCompoundDictionaryDistance(100, 100, 10), isFalse);
      expect(isCompoundDictionaryDistance(101, 100, 10), isTrue);
      expect(isCompoundDictionaryDistance(110, 100, 10), isTrue);
      expect(isCompoundDictionaryDistance(111, 100, 10), isFalse);
      expect(isCompoundDictionaryDistance(101, 100, 0), isFalse);
      expect(isCompoundDictionaryDistance(101, 99, 2), isTrue);
    });

    test('static word address subtracts the compound size', () {
      expect(staticDictionaryAddress(101, 100, 0), 0);
      expect(staticDictionaryAddress(150, 100, 0), 49);
      expect(staticDictionaryAddress(101, 100, 50), -50);
      expect(staticDictionaryAddress(150, 100, 50), -1);
      expect(staticDictionaryAddress(151, 100, 50), 0);
      expect(staticDictionaryAddress(152, 100, 50), 1);
      expect(staticDictionaryAddress(0x7FFFFFFC, 0, 0), 0x7FFFFFFB);
    });

    test('compound and static regions cannot overlap', () {
      const compoundSize = 4096;
      const maxDistance = 0;
      for (final distance in <int>[1, 2, 100, 4095, 4096]) {
        expect(
          isCompoundDictionaryDistance(distance, maxDistance, compoundSize),
          isTrue,
          reason: 'distance $distance',
        );
        expect(
          staticDictionaryAddress(distance, maxDistance, compoundSize),
          lessThan(0),
          reason: 'distance $distance',
        );
      }
      expect(
        isCompoundDictionaryDistance(4097, maxDistance, compoundSize),
        isFalse,
      );
      expect(staticDictionaryAddress(4097, maxDistance, compoundSize), 0);
      // The vector dictionary has exactly this size.
      expect(text.dictionary.length, compoundSize);
    });
  });
}
