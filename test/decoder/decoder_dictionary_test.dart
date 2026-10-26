/// RFC 7932 static dictionary: corpus coverage, hand-built references at the
/// ring boundary, transform goldens and robustness of dictionary-heavy streams.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:brotli_fast/src/common/dictionary.dart';
import 'package:brotli_fast/src/common/dictionary_data.dart';
import 'package:brotli_fast/src/common/errors.dart';
import 'package:brotli_fast/src/common/transforms.dart';
import 'package:test/test.dart';

import '../support/corpus.dart';
import 'decoder_helpers.dart';

/// Dictionary word 0 of length 4.
const List<int> _wordTime = <int>[116, 105, 109, 101]; // "time"

/// Transform 73 applied to dictionary word 0 of length 24:
/// `" the " + <script type="text/javas + " of the "` (37 bytes).
final List<int> _overflowWord =
    ' the <script type="text/javas of the '.codeUnits;

List<int> _fill(int length, int byte) => List<int>.filled(length, byte);

/// One static-dictionary reference after [insertLength] literals `'A'`.
Uint8List _buildDictionaryStream({
  required int insertLength,
  required int copyLength,
  required int wordIndex,
  required int transformIndex,
  int windowBits = 10,
}) {
  // Invalid word lengths / transform indices are used by the negative tests:
  // keep the framing valid (a positive metablock length) without calling into
  // the transform tables out of range.
  final validWord = copyLength >= 4 && copyLength <= 24 && transformIndex < 121;
  final transformedLength = validWord
      ? transformDictionaryWord(
          Uint8List(maxTransformedWordLength),
          0,
          kDictionaryData,
          dictionaryWordOffset(copyLength, wordIndex),
          copyLength,
          transformIndex,
        )
      : copyLength;
  return buildDictionaryReferenceStream(
    insertLength: insertLength,
    copyLength: copyLength,
    sizeBits: kDictionarySizeBitsByLength[copyLength],
    wordIndex: wordIndex,
    transformIndex: transformIndex,
    transformedLength: transformedLength,
    windowBits: windowBits,
  );
}

void main() {
  final corpus = Corpus.load();

  CorpusEntry entry(String name) =>
      corpus.entries.firstWhere((e) => e.name == name);

  const dictionaryVectors = <String>{
    'alice29.txt',
    'asyoulik.txt',
    'cp852-utf8',
    'lcet10.txt',
    'monkey',
    'plrabn12.txt',
    'quickfox_repeated',
  };

  group('corpus', () {
    test('dictionary references are used by exactly the expected vectors', () {
      // Both the whole-metablock fast path (large output) and the resumable
      // per-command path (small output slices) must agree.
      for (final chunkSize in <int>[1 << 24, 4096]) {
        final withDictionary = <String>{};
        for (final e in corpus.entries) {
          final decoded = decodeCore(
            corpus.compressedBytes(e),
            chunkSize: chunkSize,
          );
          expectBytes(decoded.bytes, corpus.rawBytes(e), e.name);
          if (decoded.state.dictionaryReferenceCount > 0) {
            withDictionary.add(e.name);
          }
        }
        expect(withDictionary, dictionaryVectors, reason: 'chunk=$chunkSize');
      }
    });

    test('the small dictionary vectors stream with 1-byte chunks', () {
      for (final name in <String>[
        'monkey',
        'quickfox_repeated',
        'cp852-utf8',
      ]) {
        final decoded = decodeCoreChunked(
          corpus.compressedBytes(entry(name)),
          inputChunk: 1,
          outputChunk: 1,
        );
        expectBytes(decoded.bytes, corpus.rawBytes(entry(name)), name);
        expect(decoded.state.dictionaryReferenceCount, greaterThan(0));
      }
    });

    test(
      'all dictionary vectors stream with 7-byte input / 13-byte output',
      () {
        for (final name in dictionaryVectors) {
          final decoded = decodeCoreChunked(
            corpus.compressedBytes(entry(name)),
            inputChunk: 7,
            outputChunk: 13,
          );
          expectBytes(decoded.bytes, corpus.rawBytes(entry(name)), name);
        }
      },
    );
  });

  group('synthetic dictionary boundary', () {
    test('a dictionary word ending exactly at the ring end is flushed', () {
      final stream = _buildDictionaryStream(
        insertLength: 1020,
        copyLength: 4,
        wordIndex: 0,
        transformIndex: 0,
      );
      final expected = <int>[..._fill(1020, 0x41), ..._wordTime];
      for (final chunkSize in <int>[64 * 1024, 7, 1]) {
        final decoded = decodeCore(stream, chunkSize: chunkSize);
        expectBytes(decoded.bytes, expected, 'ring-end chunk=$chunkSize');
        expect(decoded.state.ringBufferSize, 1024);
        expect(decoded.state.dictionaryReferenceCount, 1);
      }
    });

    test('a transformed word overflowing the ring window wraps correctly', () {
      final stream = _buildDictionaryStream(
        insertLength: 1020,
        copyLength: 24,
        wordIndex: 0,
        transformIndex: 73,
      );
      final expected = <int>[..._fill(1020, 0x41), ..._overflowWord];
      for (final chunkSize in <int>[64 * 1024, 7, 1]) {
        final decoded = decodeCore(stream, chunkSize: chunkSize);
        expectBytes(decoded.bytes, expected, 'overflow chunk=$chunkSize');
        expect(decoded.state.ringBufferSize, 1024);
        expect(decoded.state.dictionaryReferenceCount, 1);
      }
      expectBytes(
        decodeCoreChunked(stream, inputChunk: 1, outputChunk: 5).bytes,
        expected,
        'overflow streaming',
      );
    });

    test('transformed-word overflow also works with a 64 KiB window', () {
      final stream = _buildDictionaryStream(
        insertLength: 65530,
        copyLength: 24,
        wordIndex: 0,
        transformIndex: 73,
        windowBits: 16,
      );
      final expected = <int>[..._fill(65530, 0x41), ..._overflowWord];
      for (final chunkSize in <int>[64 * 1024, 7]) {
        final decoded = decodeCore(stream, chunkSize: chunkSize);
        expectBytes(decoded.bytes, expected, 'w16 overflow chunk=$chunkSize');
        expect(decoded.state.ringBufferSize, 65536);
        expect(decoded.state.dictionaryReferenceCount, 1);
      }
    });

    test('invalid dictionary word lengths are rejected', () {
      for (final copyLength in <int>[3, 25]) {
        final stream = _buildDictionaryStream(
          insertLength: 0,
          copyLength: copyLength,
          wordIndex: 0,
          transformIndex: 0,
        );
        expect(
          () => decodeCore(stream),
          throwsBrotli(BrotliErrorCode.invalidDictionaryWord),
          reason: 'copyLength=$copyLength',
        );
      }
    });

    test('transform index 121 is rejected', () {
      final stream = _buildDictionaryStream(
        insertLength: 0,
        copyLength: 4,
        wordIndex: 0,
        transformIndex: 121,
      );
      expect(
        () => decodeCore(stream),
        throwsBrotli(BrotliErrorCode.invalidTransform),
      );
    });
  });

  group('transform goldens', () {
    test('dictionary word 0 of length 4 is "time"', () {
      final out = Uint8List(maxTransformedWordLength);
      final n = transformDictionaryWord(
        out,
        0,
        kDictionaryData,
        dictionaryWordOffset(4, 0),
        4,
        0,
      );
      expect(out.sublist(0, n), _wordTime);
    });

    test('transform 73 grows the length-24 word to 37 bytes', () {
      final out = Uint8List(maxTransformedWordLength);
      final n = transformDictionaryWord(
        out,
        0,
        kDictionaryData,
        dictionaryWordOffset(24, 0),
        24,
        73,
      );
      expect(n, 37);
      expect(out.sublist(0, n), _overflowWord);
    });

    test('all 121 transforms fit the documented 2259-byte aggregate', () {
      final input = Uint8List.fromList('o123456789abcdef'.codeUnits);
      final out = Uint8List(2259);
      var offset = 0;
      for (var i = 0; i < 121; i++) {
        offset += transformDictionaryWord(
          out,
          offset,
          input,
          0,
          input.length,
          i,
        );
        out[offset++] = 0xFF;
      }
      expect(offset, 2259);
    });

    test('transform 44 capitalizes multibyte UTF-8', () {
      final input = Uint8List.fromList(<int>[113, 195, 166, 224, 164, 170]);
      final out = Uint8List(maxTransformedWordLength);
      final n = transformDictionaryWord(out, 0, input, 0, input.length, 44);
      expect(out.sublist(0, n), <int>[81, 195, 134, 224, 164, 175]);
    });
  });

  group('robustness', () {
    test('every truncation of a dictionary-heavy stream throws', () {
      final compressed = corpus.compressedBytes(entry('monkey'));
      for (var length = 0; length < compressed.length; length++) {
        expect(
          () => decodeCore(Uint8List.sublistView(compressed, 0, length)),
          throwsBrotli(),
          reason: 'truncated at $length bytes',
        );
      }
    });

    test('sampled truncations of alice29.txt throw BrotliException', () {
      final compressed = corpus.compressedBytes(entry('alice29.txt'));
      final lengths = <int>{
        0,
        1,
        2,
        3,
        5,
        8,
        13,
        21,
        34,
        compressed.length ~/ 4,
        compressed.length ~/ 2,
        compressed.length - 2,
        compressed.length - 1,
      };
      for (final length in lengths) {
        expect(
          () => decodeCore(Uint8List.sublistView(compressed, 0, length)),
          throwsBrotli(),
          reason: 'truncated at $length bytes',
        );
      }
    });

    test(
      'bit-flipped dictionary streams never escape as non-Brotli errors',
      () {
        final compressed = corpus.compressedBytes(entry('monkey'));
        var seed = 0xD4;
        for (var i = 0; i < 600; i++) {
          final mutated = Uint8List.fromList(compressed);
          seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
          final index = seed % mutated.length;
          mutated[index] ^= 1 << ((seed >> 16) & 7);
          try {
            decodeCore(mutated, maxOutputSize: 1 << 20);
          } on BrotliException {
            // Expected for most mutations; some mutations decode to a different
            // valid stream, which is not an error.
          }
        }
      },
    );
  });
}
