/// Compressed metablocks: reference-encoder streams across qualities and
/// windows, block switching / context maps, chunked input and corruption.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_fast/src/common/errors.dart';
import 'package:test/test.dart';

import '../support/brotli_cli.dart';
import '../support/corpus.dart';
import 'decoder_helpers.dart';

enum _Kind { random, repeated, text, mixed }

void main() {
  final corpus = Corpus.load();

  CorpusEntry entry(String name) =>
      corpus.entries.firstWhere((e) => e.name == name);

  group('reference-encoder streams', () {
    final cases = <String, ({_Kind kind, int size})>{
      'random-1k': (kind: _Kind.random, size: 1024),
      'repeated-10k': (kind: _Kind.repeated, size: 10000),
      'text-20k': (kind: _Kind.text, size: 20000),
      'mixed-64k': (kind: _Kind.mixed, size: 65536),
      'text-200k': (kind: _Kind.text, size: 200000),
    };

    for (final testCase in cases.entries) {
      test(
        '${testCase.key} is byte-exact at q0/q1/q5/q11 and lgwin 10/16/22',
        () async {
          final raw = _data(testCase.value.kind, testCase.value.size);
          for (final quality in <int>[0, 1, 5, 11]) {
            for (final lgwin in <int>[10, 16, 22]) {
              final compressed = await cliCompress(
                raw,
                quality: quality,
                windowBits: lgwin,
              );
              expect(compressed, isNotEmpty);
              expectBytes(
                decodeCore(compressed).bytes,
                raw,
                '${testCase.key} q$quality w$lgwin',
              );
            }
          }
        },
      );
    }

    test('q5 text actually exercises compressed metablocks', () async {
      final raw = _data(_Kind.text, 20000);
      final compressed = await cliCompress(raw, quality: 5, windowBits: 22);
      expect(compressed.length, lessThan(raw.length ~/ 2));
      expectBytes(decodeCore(compressed).bytes, raw, 'q5 text-20k');
    });

    test('tiny output buffers agree with one-shot output', () async {
      final raw = _data(_Kind.repeated, 10000);
      final compressed = await cliCompress(
        raw,
        quality: 5,
        windowBits: 10, // 1 KiB window: forces ring-buffer wrap in copy loop
      );
      for (final chunkSize in <int>[1, 2, 3, 7, 17, 4096]) {
        expectBytes(
          decodeCore(compressed, chunkSize: chunkSize).bytes,
          raw,
          'chunk=$chunkSize',
        );
      }
    });

    test('maxOutputSize stops a compressed stream at the limit', () async {
      final raw = _data(_Kind.text, 20000);
      final compressed = await cliCompress(raw, quality: 5, windowBits: 22);
      expect(
        () => decodeCore(compressed, maxOutputSize: raw.length - 1),
        throwsBrotli(BrotliErrorCode.outputLimitExceeded),
      );
      expectBytes(
        decodeCore(compressed, maxOutputSize: raw.length).bytes,
        raw,
        'exact output limit',
      );
    });

    test(
      'transcoding survives a 1-byte output buffer with wrap-around',
      () async {
        final raw = _data(_Kind.mixed, 65536);
        final compressed = await cliCompress(raw, quality: 1, windowBits: 10);
        expectBytes(
          decodeCore(compressed, chunkSize: 1).bytes,
          raw,
          'mixed-64k w10 chunk=1',
        );
      },
    );

    test(
      '1-byte input chunks resume header, context map and hot loops',
      () async {
        // The compressed-header step machine and the hot loops must suspend and
        // resume without corrupting state.
        final raw = _data(_Kind.text, 20000);
        final compressed = await cliCompress(raw, quality: 5, windowBits: 22);
        for (final inputChunk in <int>[1, 3, 17]) {
          for (final outputChunk in <int>[1, 7, 4096]) {
            expectBytes(
              decodeCoreChunked(
                compressed,
                inputChunk: inputChunk,
                outputChunk: outputChunk,
              ).bytes,
              raw,
              'input=$inputChunk output=$outputChunk',
            );
          }
        }
      },
    );

    test('large-window compressed streams decode when enabled', () async {
      final raw = _data(_Kind.text, 20000);
      final compressed = await cliCompress(raw, quality: 5, windowBits: 26);
      final decoded = decodeCore(compressed, allowLargeWindow: true);
      expectBytes(decoded.bytes, raw, 'large-window q5 w26');
      expect(decoded.state.largeWindow, isTrue);
      expect(decoded.state.windowBits, 26);
      expect(
        () => decodeCore(compressed),
        throwsBrotli(BrotliErrorCode.invalidWindowBits),
      );
    });
  }, skip: brotliCliSkipReason());

  group('block switching and context maps (corpus)', () {
    test('mapsdatazrh uses multiple block types, trees and context maps', () {
      final decoded = decodeCore(corpus.compressedBytes(entry('mapsdatazrh')));
      expectBytes(
        decoded.bytes,
        corpus.rawBytes(entry('mapsdatazrh')),
        'mapsdatazrh',
      );
      final state = decoded.state;
      expect(state.numLiteralBlockTypes, greaterThan(1));
      expect(state.numCommandBlockTypes, greaterThan(1));
      expect(state.numDistanceBlockTypes, greaterThan(1));
      expect(state.numLiteralTrees, greaterThan(1));
      expect(state.numDistTrees, greaterThan(1));
      expect(state.trivialLiteralContext, isFalse);
    });

    test('zerosukkanooa exercises distance postfix/direct codes', () {
      final decoded = decodeCore(
        corpus.compressedBytes(entry('zerosukkanooa')),
      );
      expectBytes(
        decoded.bytes,
        corpus.rawBytes(entry('zerosukkanooa')),
        'zerosukkanooa',
      );
      expect(decoded.state.numDistTrees, greaterThan(1));
      expect(decoded.state.numDirectDistanceCodes, greaterThan(0));
    });

    test('block-switch heavy streams decode with tiny output buffers', () {
      for (final name in <String>['mapsdatazrh', 'compressed_repeated']) {
        final e = entry(name);
        final raw = corpus.rawBytes(e);
        final compressed = corpus.compressedBytes(e);
        for (final chunkSize in <int>[7, 4096]) {
          expectBytes(
            decodeCore(compressed, chunkSize: chunkSize).bytes,
            raw,
            '$name chunk=$chunkSize',
          );
        }
      }
    });

    test('chunked input resumes multi-tree headers and block switches', () {
      // compressed_repeated has 2 literal block types and 4 literal trees;
      // mapsdatazrh has 14/6/9 block types and 19/9 trees. Feeding the
      // compressed header a few bytes at a time exercises memento restarts in
      // the tree-group loops and the resumable context-map cursors.
      final repeated = entry('compressed_repeated');
      expectBytes(
        decodeCoreChunked(
          corpus.compressedBytes(repeated),
          inputChunk: 3,
          outputChunk: 7,
        ).bytes,
        corpus.rawBytes(repeated),
        'compressed_repeated chunked input',
      );
      final maps = entry('mapsdatazrh');
      expectBytes(
        decodeCoreChunked(
          corpus.compressedBytes(maps),
          inputChunk: 64,
          outputChunk: 4096,
        ).bytes,
        corpus.rawBytes(maps),
        'mapsdatazrh chunked input',
      );
    });

    test('every corpus vector survives 7-byte input / 13-byte output', () {
      for (final e in corpus.entries) {
        expectBytes(
          decodeCoreChunked(
            corpus.compressedBytes(e),
            inputChunk: 7,
            outputChunk: 13,
          ).bytes,
          corpus.rawBytes(e),
          e.name,
        );
      }
    });
  });

  group('malformed and truncated streams', () {
    test('every truncation of a valid stream throws BrotliException', () async {
      final raw = _data(_Kind.repeated, 300);
      final compressed = await cliCompress(raw, quality: 5, windowBits: 22);
      for (var length = 0; length < compressed.length; length++) {
        expect(
          () => decodeCore(Uint8List.sublistView(compressed, 0, length)),
          throwsBrotli(),
          reason: 'truncated at $length bytes',
        );
      }
    }, skip: brotliCliSkipReason());

    test(
      'sampled truncations of a larger stream throw BrotliException',
      () async {
        final raw = _data(_Kind.text, 20000);
        final compressed = await cliCompress(raw, quality: 1, windowBits: 22);
        final lengths = <int>{
          0,
          1,
          2,
          3,
          4,
          5,
          7,
          11,
          13,
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
      },
      skip: brotliCliSkipReason(),
    );

    test('bit-flipped streams never escape as non-Brotli exceptions', () async {
      final raw = _data(_Kind.text, 5000);
      final compressed = await cliCompress(raw, quality: 5, windowBits: 22);
      final random = Random(0xD3);
      for (var i = 0; i < 600; i++) {
        final mutated = Uint8List.fromList(compressed);
        final index = random.nextInt(mutated.length);
        mutated[index] ^= 1 << random.nextInt(8);
        try {
          decodeCore(mutated, maxOutputSize: 1 << 20);
        } on BrotliException {
          // Expected for most mutations; a mutation that still decodes is a
          // valid stream by definition, so it is not an error either.
        }
      }
    }, skip: brotliCliSkipReason());

    test('corrupt header bytes always raise BrotliException', () {
      // First bytes of a real compressed vector: corrupting the window-bits /
      // metablock header must not reach a Dart RangeError or hang.
      final base = corpus.compressedBytes(entry('zeros'));
      for (var index = 0; index < 8 && index < base.length; index++) {
        for (var bit = 0; bit < 8; bit++) {
          final mutated = Uint8List.fromList(base);
          mutated[index] ^= 1 << bit;
          try {
            decodeCore(mutated, maxOutputSize: 1 << 20);
          } on BrotliException {
            // Expected.
          }
        }
      }
    });
  });
}

/// Deterministic test data (no fixtures on disk, no dependency on encoders).
Uint8List _data(_Kind kind, int size) {
  switch (kind) {
    case _Kind.random:
      final random = Random(0xB07 + size);
      final bytes = Uint8List(size);
      for (var i = 0; i < size; i++) {
        bytes[i] = random.nextInt(256);
      }
      return bytes;
    case _Kind.repeated:
      final bytes = Uint8List(size);
      for (var i = 0; i < size; i++) {
        bytes[i] = i % 97;
      }
      return bytes;
    case _Kind.text:
      const words = <String>[
        'the ',
        'quick ',
        'brown ',
        'fox ',
        'jumps ',
        'over ',
        'lazy ',
        'dog ',
        'and ',
        'then ',
        'runs ',
        'away. ',
      ];
      final builder = StringBuffer();
      var seed = 12345;
      while (builder.length < size) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        builder.write(words[seed % words.length]);
      }
      final encoded = utf8.encode(builder.toString());
      return Uint8List.fromList(encoded.sublist(0, size));
    case _Kind.mixed:
      final random = Random(99);
      final bytes = Uint8List(size);
      for (var i = 0; i < size; i++) {
        bytes[i] = i % 1024 < 512 ? random.nextInt(256) : (i * 7) & 0xFF;
      }
      return bytes;
  }
}
