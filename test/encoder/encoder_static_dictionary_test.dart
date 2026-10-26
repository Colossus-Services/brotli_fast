@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:brotli_fast/src/encoder/backward_references.dart';
import 'package:brotli_fast/src/encoder/bit_writer.dart';
import 'package:brotli_fast/src/encoder/command.dart';
import 'package:brotli_fast/src/encoder/encoder.dart' show maxCompressedSize;
import 'package:brotli_fast/src/encoder/match_finder.dart';
import 'package:brotli_fast/src/encoder/metablock_writer.dart';
import 'package:brotli_fast/src/encoder/static_dictionary.dart';
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

import '../support/brotli_cli.dart';
import '../support/encoder_fixtures.dart';
import '../support/high_ratio.dart';

const int _kKiB = 1024;
const int _kMiB = 1 << 20;

/// English text built from words that are in the RFC dictionary.
const String _dictionaryHeavy =
    'The information about the transformation of the dictionary and the '
    'compression of the information is available from the server. They were '
    'thinking about the performance of the implementation. ';

void main() {
  final cliSkip = brotliCliSkipReason();

  group('dictionary matcher', () {
    test('finds dictionary words at literal positions', () {
      final input = Uint8List.fromList(utf8.encode(_dictionaryHeavy));
      final matcher = StaticDictionaryMatcher.instance;
      // "information" starts at index 4.
      final match = matcher.findMatch(input, 4, input.length - 4);
      expect(match, isNotNull);
      expect(match!.length, greaterThanOrEqualTo(kMinDictionaryMatchLength));
      // The distance is always beyond the backward window.
      expect(match.distance(1000), greaterThan(1000));
      // Random bytes never match.
      final random = randomBytes(4096, 3);
      var hits = 0;
      for (var i = 0; i + 8 < random.length; i++) {
        if (matcher.findMatch(random, i, random.length - i) != null) hits++;
      }
      expect(hits, lessThan(8));
    });

    test('rewrites literal runs into dictionary references', () {
      final input = Uint8List.fromList(utf8.encode(_dictionaryHeavy));
      final chain = _chainCommands(input);
      final rewritten = CommandBuffer(input.length);
      final references = applyStaticDictionaryMatches(
        input,
        0,
        input.length,
        chain,
        rewritten,
        (1 << 22) - 16,
      );
      expect(references, greaterThan(0));
      expect(rewritten.count, greaterThan(chain.count));
      var covered = 0;
      for (var i = 0; i < rewritten.count; i++) {
        covered += rewritten.insertLen[i] + rewritten.copyLen[i];
        // Dictionary references use a distance code far beyond the window.
        if (rewritten.copyLen[i] > 0 && rewritten.distCode[i] > 0) {
          final distance = rewritten.distCode[i] - 15;
          if (distance > (1 << 22) - 16) {
            expect(rewritten.copyLen[i], inInclusiveRange(4, 24));
          }
        }
      }
      expect(covered, input.length);
    });

    test('the rewritten parse serialises smaller on dictionary text', () {
      final input = Uint8List.fromList(utf8.encode(_dictionaryHeavy));
      final chain = _chainCommands(input);
      final rewritten = CommandBuffer(input.length);
      final references = applyStaticDictionaryMatches(
        input,
        0,
        input.length,
        chain,
        rewritten,
        (1 << 22) - 16,
      );
      expect(references, greaterThan(0));
      final chainBits = _serialisedBits(input, chain);
      final dictionaryBits = _serialisedBits(input, rewritten);
      expect(dictionaryBits, lessThanOrEqualTo(chainBits));
    });
  });

  group('numeric round-trip', () {
    test(
      'reference CLI and our decoder round-trip at q5/q8/q11',
      () async {
        final cases = <String, Uint8List>{
          'dictionary-phrase': Uint8List.fromList(
            utf8.encode(_dictionaryHeavy * 40),
          ),
          'short-phrase': Uint8List.fromList(utf8.encode(_dictionaryHeavy)),
          'english-1m': aliceText(1 * _kMiB),
          'cjk-200k': variedCjk(200 * _kKiB, 3),
          'mixed-200k': alternatingTextBinary(200 * _kKiB, 5, period: 8192),
          'binary-200k': randomBytes(200 * _kKiB, 7),
        };
        for (final entry in cases.entries) {
          for (final quality in <int>[5, 8, 11]) {
            final input = entry.value;
            final stream = highRatioEncode(
              input,
              BrotliEncodeOptions(quality: quality),
            );
            expectSameBytes(
              await cliDecompress(stream),
              input,
              reason: 'reference CLI ${entry.key} q$quality',
            );
            expectSameBytes(
              brotliDecode(stream),
              input,
              reason: 'our decoder ${entry.key} q$quality',
            );
            expect(
              stream.length,
              lessThanOrEqualTo(maxCompressedSize(input.length)),
            );
          }
        }
      },
      skip: cliSkip,
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test('dictionary-heavy input produces dictionary references', () {
      final input = Uint8List.fromList(utf8.encode(_dictionaryHeavy * 40));
      final chain = _chainCommands(input);
      final rewritten = CommandBuffer(input.length);
      final references = applyStaticDictionaryMatches(
        input,
        0,
        input.length,
        chain,
        rewritten,
        (1 << 22) - 16,
      );
      expect(references, greaterThan(0));
    });

    test('deterministic', () {
      final input = Uint8List.fromList(utf8.encode(_dictionaryHeavy * 40));
      final first = highRatioEncode(
        input,
        const BrotliEncodeOptions(quality: 5),
      );
      expect(
        highRatioEncode(input, const BrotliEncodeOptions(quality: 5)),
        orderedEquals(first),
      );
    });
  });

  group('ratio versus the reference CLI', () {
    test('report small/short text sizes', () async {
      final cases = <String, Uint8List>{
        'phrase': Uint8List.fromList(utf8.encode(_dictionaryHeavy)),
        'phrase-x40': Uint8List.fromList(utf8.encode(_dictionaryHeavy * 40)),
        'english-1m': aliceText(1 * _kMiB),
      };
      final report = StringBuffer(
        'static dictionary report (ours / reference):\n',
      );
      for (final entry in cases.entries) {
        for (final quality in <int>[5, 8]) {
          final ours = highRatioEncode(
            entry.value,
            BrotliEncodeOptions(quality: quality),
          );
          final reference = await cliCompress(entry.value, quality: quality);
          report.writeln(
            '  ${entry.key.padRight(12)} q$quality in='
            '${entry.value.length} ours=${ours.length} '
            'ref=${reference.length} '
            'ratio=${(ours.length / reference.length).toStringAsFixed(4)}',
          );
          expect(ours.length / reference.length, lessThan(1.5));
          // The reference stream decodes with our decoder.
          expectSameBytes(
            brotliDecode(reference),
            entry.value,
            reason: 'reference ${entry.key} q$quality',
          );
        }
      }
      print(report.toString().trimRight());
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: cliSkip);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

CommandBuffer _chainCommands(Uint8List input) {
  final hasher = HashChainMatcher(
    bucketBits: 15,
    blockBits: 5,
    numLastDistances: 4,
  );
  final commands = CommandBuffer(input.length);
  createBackwardReferences(
    input,
    0,
    input.length,
    hasher,
    commands,
    createSearchDistanceCache(),
    (1 << 22) - 16,
    extensiveSearch: true,
  );
  return commands;
}

/// Serialises one parse with the plain writer (single meta-block).
int _serialisedBits(Uint8List input, CommandBuffer commands) {
  final writer = BitWriter();
  writer.writeBits(4, 0xB); // lgwin 22
  MetaBlockWriter().store(
    writer,
    input,
    0,
    input.length,
    commands,
    isLast: true,
  );
  writer.alignToByte();
  return writer.bitPosition;
}
