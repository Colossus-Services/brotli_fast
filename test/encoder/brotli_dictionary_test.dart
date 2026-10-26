@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:brotli_fast/src/dictionary.dart' show dictionaryMatcher;
import 'package:brotli_fast/src/encoder/backward_references.dart';
import 'package:brotli_fast/src/encoder/command.dart';
import 'package:brotli_fast/src/encoder/compound_dictionary.dart';
import 'package:brotli_fast/src/encoder/encoder.dart';
import 'package:brotli_fast/src/encoder/match_finder.dart';
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

import '../support/brotli_cli.dart';
import '../support/encoder_fixtures.dart';

const int _kKiB = 1024;

void main() {
  final cliSkip = brotliCliSkipReason();
  final bytes = aliceText(64 * _kKiB);
  final dictionary = BrotliDictionary(bytes);

  Uint8List payload(int size) => payloadFrom(bytes, size, seed: 11);

  group('BrotliDictionary', () {
    test('holds the bytes', () {
      expect(dictionary.length, bytes.length);
      // A Uint8List is taken by reference; any other list is copied.
      expect(identical(dictionary.bytes, bytes), isTrue);
      final source = <int>[1, 2, 3, 4, 5];
      final copied = BrotliDictionary(source);
      expect(copied.length, 5);
      expect(copied.bytes, orderedEquals(<int>[1, 2, 3, 4, 5]));
      source[0] = 9;
      expect(copied.bytes[0], 1);
      expect(
        () => BrotliDictionary(Uint8List(maxDictionarySize + 1)),
        throwsArgumentError,
      );
    });

    test('a reused instance is byte-identical to a fresh one', () {
      final input = payload(300000);
      for (final quality in <int>[5, 8, 11]) {
        // [dictionary] has been used by earlier encodes (cached index); the
        // fresh instance builds its index now.
        final viaReused = brotliEncode(
          input,
          quality: quality,
          dictionary: dictionary,
        );
        final viaFresh = brotliEncode(
          input,
          quality: quality,
          dictionary: BrotliDictionary(Uint8List.fromList(bytes)),
        );
        expect(
          viaReused,
          orderedEquals(viaFresh),
          reason: 'q$quality reused vs fresh',
        );
        expectSameBytes(
          brotliDecode(viaReused, dictionary: BrotliDictionary(bytes)),
          input,
        );
      }
    });

    test('one instance is reusable and stateless', () {
      final inputs = <Uint8List>[
        payload(50000),
        payload(120000),
        aliceText(20000),
      ];
      final first = <List<int>>[
        for (final input in inputs)
          brotliEncode(input, quality: 8, dictionary: dictionary),
      ];
      for (var round = 0; round < 3; round++) {
        for (var i = 0; i < inputs.length; i++) {
          final stream = brotliEncode(
            inputs[i],
            quality: 8,
            dictionary: dictionary,
          );
          expect(stream, orderedEquals(first[i]), reason: 'round $round #$i');
          expectSameBytes(
            brotliDecode(stream, dictionary: dictionary),
            inputs[i],
          );
        }
      }
    });

    test('streaming encoder accepts a dictionary', () {
      final input = payload(400000);
      final encoder = StreamingEncoder(
        BrotliEncodeOptions(quality: 8, dictionary: dictionary),
      );
      final output = BytesBuilder(copy: false);
      for (var offset = 0; offset < input.length; offset += 50000) {
        final end = min(offset + 50000, input.length);
        encoder.add(Uint8List.sublistView(input, offset, end));
        encoder.flush();
        output.add(encoder.takeOutput());
      }
      encoder.finish();
      output.add(encoder.takeOutput());
      expectSameBytes(
        brotliDecode(output.takeBytes(), dictionary: dictionary),
        input,
      );
    });

    test('small and oversized dictionaries behave', () {
      for (final entry in <String, Uint8List>{
        'empty': Uint8List(0),
        'one': Uint8List.fromList(<int>[42]),
        '64k': bytes,
      }.entries) {
        final caseDictionary = BrotliDictionary(entry.value);
        final input = entry.value.length < 1024
            ? aliceText(40000)
            : payloadFrom(entry.value, 150000, seed: 11);
        final stream = brotliEncode(
          input,
          windowBits: 10,
          dictionary: caseDictionary,
        );
        expect(stream.length, lessThan(input.length));
        expectSameBytes(
          brotliDecode(stream, dictionary: caseDictionary),
          input,
          reason: entry.key,
        );
      }
    });

    test('dictionary indexes are reused (telemetry)', () {
      final input = payload(200000);
      final hasher = HashChainMatcher(
        bucketBits: 15,
        blockBits: 8,
        numLastDistances: 16,
      );
      final chain = CommandBuffer(input.length);
      createBackwardReferences(
        input,
        0,
        input.length,
        hasher,
        chain,
        createSearchDistanceCache(),
        (1 << 22) - 16,
        extensiveSearch: true,
      );
      final rewritten = CommandBuffer(input.length);
      final references = applyCompoundDictionaryMatches(
        input,
        0,
        input.length,
        chain,
        rewritten,
        (1 << 22) - 16,
        dictionaryMatcher(dictionary),
        Int32List.fromList(<int>[4, 11, 15, 16]),
      );
      expect(references, greaterThan(0));
      // Two matchers created from one dictionary share its bytes.
      final a = dictionaryMatcher(dictionary);
      final b = dictionaryMatcher(dictionary);
      expect(identical(a.dictionary, b.dictionary), isTrue);
      // Building the index costs a pass over the dictionary; reusing it does
      // not, so a matcher from the cached index is much cheaper to create.
      final large = BrotliDictionary(aliceText(4 << 20));
      dictionaryMatcher(large); // builds and caches the index
      final cached = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        dictionaryMatcher(large);
      }
      cached.stop();
      final rebuilt = Stopwatch()..start();
      CompoundDictionaryMatcher(large.bytes);
      rebuilt.stop();
      expect(cached.elapsedMicroseconds, lessThan(rebuilt.elapsedMicroseconds));
    });

    test('reference CLI decodes dictionary streams with -D', () async {
      final input = payload(300000);
      for (final quality in <int>[5, 8, 11]) {
        final stream = brotliEncode(
          input,
          quality: quality,
          dictionary: dictionary,
        );
        expectSameBytes(
          await cliDecompress(stream, dictionary: bytes),
          input,
          reason: 'q$quality',
        );
      }
    }, skip: cliSkip);

    test('our decoder decodes reference CLI streams made with -D', () async {
      final input = payload(300000);
      for (final quality in <int>[5, 8, 11]) {
        final stream = await cliCompress(
          input,
          quality: quality,
          dictionary: bytes,
        );
        expectSameBytes(
          brotliDecode(stream, dictionary: dictionary),
          input,
          reason: 'q$quality',
        );
      }
    }, skip: cliSkip);
  });
}
