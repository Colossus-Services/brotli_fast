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
const int _kMiB = 1 << 20;

void main() {
  final cliSkip = brotliCliSkipReason();
  final dictBytes = aliceText(64 * _kKiB);
  final dict = BrotliDictionary(dictBytes);

  group('compound dictionary encoding', () {
    test(
      'payload built from the dictionary round-trips',
      () async {
        final input = payloadFrom(dictBytes, 1 * _kMiB);
        for (final quality in <int>[5, 8, 11]) {
          for (final windowBits in <int>[10, 16, 22, 24]) {
            final stream = brotliEncode(
              input,
              quality: quality,
              windowBits: windowBits,
              dictionary: dict,
            );
            expectSameBytes(
              brotliDecode(stream, dictionary: dict),
              input,
              reason: 'q$quality w$windowBits',
            );
            expectSameBytes(
              await cliDecompress(stream, dictionary: dictBytes),
              input,
              reason: 'reference CLI q$quality w$windowBits',
            );
            expect(
              stream.length,
              lessThanOrEqualTo(maxCompressedSize(input.length)),
            );
          }
        }
      },
      skip: cliSkip,
      timeout: const Timeout(Duration(minutes: 12)),
    );

    test('dictionary sizes 0/1/4 KiB/64 KiB and dictionary > window', () {
      final cases = <String, Uint8List>{
        'empty': Uint8List(0),
        'one': Uint8List.fromList(<int>[7]),
        '4k': aliceText(4 * _kKiB),
        '64k': dictBytes,
      };
      for (final entry in cases.entries) {
        final input = entry.value.length < 1024
            ? aliceText(50000)
            : payloadFrom(entry.value, 200000);
        final dictionary = BrotliDictionary(entry.value);
        final stream = brotliEncode(
          input,
          // window far smaller than the 64 KiB dictionary
          windowBits: 10,
          dictionary: dictionary,
        );
        expectSameBytes(
          brotliDecode(stream, dictionary: dictionary),
          input,
          reason: entry.key,
        );
      }
    });

    test('without the dictionary the stream does not decode to the input', () {
      final input = payloadFrom(dictBytes, 300000);
      final stream = brotliEncode(input, dictionary: dict);
      var rejectedOrDifferent = false;
      try {
        final decoded = brotliDecode(stream);
        rejectedOrDifferent =
            decoded.length != input.length || !_equal(decoded, input);
      } catch (_) {
        rejectedOrDifferent = true;
      }
      expect(rejectedOrDifferent, isTrue);
    });

    test('streaming encoder supports a compound dictionary', () {
      final input = payloadFrom(dictBytes, 500000);
      final encoder = StreamingEncoder(
        BrotliEncodeOptions(quality: 8, dictionary: dict),
      );
      final output = BytesBuilder(copy: false);
      for (var offset = 0; offset < input.length; offset += 40000) {
        final end = min(offset + 40000, input.length);
        encoder.add(Uint8List.sublistView(input, offset, end));
        encoder.flush();
        output.add(encoder.takeOutput());
      }
      encoder.finish();
      output.add(encoder.takeOutput());
      final stream = output.takeBytes();
      expect(encoder.isFinished, isTrue);
      expectSameBytes(brotliDecode(stream, dictionary: dict), input);
    });

    test('chunked conversion supports a compound dictionary', () async {
      final input = payloadFrom(dictBytes, 300000);
      final chunks = <List<int>>[
        for (var offset = 0; offset < input.length; offset += 40000)
          Uint8List.sublistView(
            input,
            offset,
            min(offset + 40000, input.length),
          ),
      ];
      final stream = await Stream<List<int>>.fromIterable(chunks)
          .transform(BrotliEncoder(quality: 8, dictionary: dict))
          .fold<BytesBuilder>(BytesBuilder(), (b, chunk) => b..add(chunk));
      expectSameBytes(
        brotliDecode(stream.takeBytes(), dictionary: dict),
        input,
      );
    });

    test('deterministic and produces dictionary references', () {
      final input = payloadFrom(dictBytes, 300000);
      final first = brotliEncode(input, dictionary: dict);
      expect(brotliEncode(input, dictionary: dict), orderedEquals(first));
      // Telemetry through the internal rewrite.
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
        dictionaryMatcher(dict),
        Int32List.fromList(<int>[4, 11, 15, 16]),
      );
      expect(references, greaterThan(0));
      // An index-less matcher over the same bytes finds the same references.
      final unshared = CommandBuffer(input.length);
      expect(
        applyCompoundDictionaryMatches(
          input,
          0,
          input.length,
          chain,
          unshared,
          (1 << 22) - 16,
          CompoundDictionaryMatcher(dictBytes),
          Int32List.fromList(<int>[4, 11, 15, 16]),
        ),
        references,
      );
    });

    test('the dictionary payload is smaller than without it', () {
      final input = payloadFrom(dictBytes, 1 * _kMiB);
      for (final quality in <int>[5, 8]) {
        final withDictionary = brotliEncode(
          input,
          quality: quality,
          dictionary: dict,
        );
        final without = brotliEncode(input, quality: quality);
        expect(
          withDictionary.length,
          lessThan(without.length),
          reason: 'q$quality should profit from the dictionary',
        );
      }
    });
  });

  group('ratio versus the reference CLI', () {
    test('report compound-dictionary sizes', () async {
      final input = payloadFrom(dictBytes, 1 * _kMiB);
      final report = StringBuffer(
        'compound dictionary report (ours / reference):\n',
      );
      for (final quality in <int>[5, 8]) {
        final ours = brotliEncode(input, quality: quality, dictionary: dict);
        final reference = await cliCompress(
          input,
          quality: quality,
          dictionary: dictBytes,
        );
        report.writeln(
          '  q$quality in=${input.length} ours=${ours.length} '
          'ref=${reference.length} '
          'ratio=${(ours.length / reference.length).toStringAsFixed(4)}',
        );
        // The ratio is reported for information: the reference
        // compound-dictionary parser finds longer matches on this synthetic
        // payload. The hard requirement is that attaching the dictionary
        // never makes our output larger.
        final without = brotliEncode(input, quality: quality);
        expect(ours.length, lessThan(without.length), reason: 'q$quality');
        // The reference stream decodes with our decoder.
        expectSameBytes(
          brotliDecode(reference, dictionary: dict),
          input,
          reason: 'reference q$quality',
        );
      }
      print(report.toString().trimRight());
    }, timeout: const Timeout(Duration(minutes: 10)));
  }, skip: cliSkip);
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
