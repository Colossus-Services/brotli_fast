@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:brotli_fast/src/encoder/backward_references.dart';
import 'package:brotli_fast/src/encoder/command.dart';
import 'package:brotli_fast/src/encoder/cost_model.dart';
import 'package:brotli_fast/src/encoder/encoder.dart' show maxCompressedSize;
import 'package:brotli_fast/src/encoder/guided_parse.dart';
import 'package:brotli_fast/src/encoder/match_finder.dart';
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

import '../support/brotli_cli.dart';
import '../support/encoder_fixtures.dart';
import '../support/high_ratio.dart';

const int _kKiB = 1024;
const int _kMiB = 1 << 20;

void main() {
  final cliSkip = brotliCliSkipReason();

  group('cost model and parser primitives', () {
    test('symbol costs are non-negative and discourage unseen symbols', () {
      expect(symbolCost(100, 100), lessThan(symbolCost(100, 10)));
      expect(symbolCost(100, 10), lessThan(symbolCost(100, 1)));
      expect(symbolCost(100, 0), kRareSymbolCost);
      expect(symbolCost(0, 0), kRareSymbolCost);
      // A single-symbol histogram still charges something for literals.
      expect(symbolCost(10000, 10000), greaterThanOrEqualTo(kMinSymbolCost));
    });

    test('copy costs are finite and positive', () {
      final model = _modelFor(_data(_DataKind.text, 20000));
      for (final length in <int>[2, 3, 4, 8, 16, 64, 200]) {
        for (final distanceCode in <int>[0, 4, 16, 40, 200]) {
          final cost = model.copyCost(0, length, distanceCode);
          expect(
            cost,
            greaterThan(0),
            reason: 'len $length code $distanceCode',
          );
          expect(cost, lessThan(200), reason: 'len $length code $distanceCode');
        }
      }
      // A very long insert run costs at least as much as a short one: the
      // insert length code and its extra bits grow.
      expect(
        model.copyCost(0, 8, 40),
        lessThanOrEqualTo(model.copyCost(30000, 8, 40)),
      );
    });

    test('cost model can be built from a real block', () {
      final model = _modelFor(_data(_DataKind.text, 32768));
      expect(model.literalCost, hasLength(256));
      expect(model.commandCost, hasLength(numCommandSymbols));
      expect(model.distanceCost, hasLength(numDistanceSymbols));
      for (final cost in model.literalCost) {
        expect(cost, greaterThan(0));
      }
    });

    test('guided parse covers the block and is deterministic', () {
      final input = _data(_DataKind.text, 20000);
      final first = _guidedCommands(input);
      final second = _guidedCommands(input);
      expect(first.count, second.count);
      var covered = 0;
      for (var i = 0; i < first.count; i++) {
        covered += first.insertLen[i] + first.copyLen[i];
        expect(first.cmdPrefix[i], second.cmdPrefix[i]);
        expect(first.distCode[i], second.distCode[i]);
      }
      expect(covered, input.length);
    });
  });

  group('numeric round-trip', () {
    for (final quality in <int>[10, 11]) {
      test(
        'quality $quality: boundary sizes and data kinds',
        () async {
          const sizes = <int>[
            0, 1, 2, 3, 4, 5, 15, 16, 17, 63, 64, 65, 255, 256, 1023, 4095, //
            65536, 131071, 131072, 131073,
          ];
          for (final kind in _DataKind.values) {
            for (final size in sizes) {
              final input = _data(kind, size);
              final output = highRatioEncode(
                input,
                BrotliEncodeOptions(quality: quality),
              );
              await _expectRoundTrip(
                input,
                output,
                reason: 'q$quality ${kind.name} $size',
              );
            }
          }
        },
        skip: cliSkip,
        timeout: const Timeout(Duration(minutes: 8)),
      );

      test(
        'quality $quality: 1 MiB and 2 MiB round-trip',
        () async {
          for (final kind in <_DataKind>[
            _DataKind.text,
            _DataKind.cjkVaried,
            _DataKind.alternating,
            _DataKind.binary,
          ]) {
            for (final size in <int>[1 * _kMiB, 2 * _kMiB]) {
              final input = _data(kind, size);
              final output = highRatioEncode(
                input,
                BrotliEncodeOptions(quality: quality),
              );
              await _expectRoundTrip(
                input,
                output,
                reason: 'q$quality ${kind.name} $size',
              );
            }
          }
        },
        skip: cliSkip,
        timeout: const Timeout(Duration(minutes: 12)),
      );

      test(
        'quality $quality: every window size round-trips',
        () async {
          final input = _data(_DataKind.alternating, 70000);
          for (var lgwin = 10; lgwin <= 24; lgwin++) {
            final output = highRatioEncode(
              input,
              BrotliEncodeOptions(quality: quality, lgwin: lgwin),
            );
            await _expectRoundTrip(
              input,
              output,
              reason: 'q$quality lgwin $lgwin',
            );
          }
        },
        skip: cliSkip,
        timeout: const Timeout(Duration(minutes: 6)),
      );

      test('quality $quality: deterministic and bounded', () {
        final input = _data(_DataKind.alternating, 100000);
        final first = highRatioEncode(
          input,
          BrotliEncodeOptions(quality: quality),
        );
        expect(
          highRatioEncode(input, BrotliEncodeOptions(quality: quality)),
          orderedEquals(first),
        );
        expect(
          first.length,
          lessThanOrEqualTo(maxCompressedSize(input.length)),
        );
        // The public one-shot encoder takes the same path at q10/q11.
        expect(brotliEncode(input, quality: quality), orderedEquals(first));
      });
    }

    test('a q11 stream decodes with the reference CLI', () async {
      final input = _data(_DataKind.cjkVaried, 150000);
      final compressed = highRatioEncode(
        input,
        const BrotliEncodeOptions(quality: 11),
      );
      expectSameBytes(await cliDecompress(compressed), input);
      expectSameBytes(brotliDecode(compressed), input);
    }, skip: cliSkip);
  });

  group('quality ladder', () {
    test('q10 <= q9 and q11 <= q10 on text', () {
      // English text: the guided parses usually tie with quality 9 (the parse
      // it finds is already the cheapest serialisation); they must never be
      // larger. Varied CJK is where the guided parse wins, asserted separately.
      final sources = <String, Uint8List>{
        'alice29.txt': alice,
        'plrabn12.txt': plrabn12,
        'text-1m': _data(_DataKind.text, _kMiB),
        'text-2m': _data(_DataKind.text, 2 * _kMiB),
      };
      for (final entry in sources.entries) {
        int size(int quality) => highRatioEncode(
          entry.value,
          BrotliEncodeOptions(quality: quality),
        ).length;
        final q9 = size(9);
        final q10 = size(10);
        final q11 = size(11);
        // The bounded DP parse makes quality 10/11 strictly better on English
        // text; on the two classic corpora a tie is acceptable.
        if (entry.key.startsWith('text-')) {
          expect(q10, lessThan(q9), reason: 'q10 must beat q9 (${entry.key})');
          expect(
            q11,
            lessThan(q10),
            reason: 'q11 must beat q10 (${entry.key})',
          );
        } else {
          expect(q10, lessThanOrEqualTo(q9), reason: 'q10 ${entry.key}');
          expect(q11, lessThanOrEqualTo(q10), reason: 'q11 ${entry.key}');
        }
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('q10 and q11 are distinct from q9 on mixed UTF-8 text', () {
      final input = _data(_DataKind.cjkVaried, 100000);
      final q9 = highRatioEncode(input, const BrotliEncodeOptions(quality: 9));
      final q10 = highRatioEncode(
        input,
        const BrotliEncodeOptions(quality: 10),
      );
      final q11 = highRatioEncode(
        input,
        const BrotliEncodeOptions(quality: 11),
      );
      expect(q10, isNot(orderedEquals(q9)), reason: 'q10 is a distinct parse');
      expect(q10.length, lessThan(q9.length));
      expect(q11.length, lessThanOrEqualTo(q10.length));
    });

    test('a 1 MiB text stays bounded in time', () {
      final input = _data(_DataKind.text, _kMiB);
      final stopwatch = Stopwatch()..start();
      highRatioEncode(input, const BrotliEncodeOptions(quality: 11));
      stopwatch.stop();
      // Measured ~1.2 s on the development VM for this 1 MiB text (two DP
      // passes, the second reusing the first pass's match cache); keep a
      // generous bound so slow CI machines do not produce false failures.
      expect(stopwatch.elapsedMilliseconds, lessThan(6000));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('ratio versus the reference CLI', () {
    test('report q10/q11 sizes and ratios', () async {
      final cases = <String, Uint8List>{
        'alice-152k': alice,
        'plrabn12-482k': plrabn12,
        'text-1m': _data(_DataKind.text, _kMiB),
        'cjk-varied-256k': _data(_DataKind.cjkVaried, 256 * _kKiB),
        'alt-text-bin-256k': _data(_DataKind.alternating, 256 * _kKiB),
        'binary-256k': _data(_DataKind.binary, 256 * _kKiB),
      };
      final report = StringBuffer(
        'q9/q10/q11 report (sizes vs reference brotli CLI):\n',
      );
      for (final entry in cases.entries) {
        final input = entry.value;
        final sizes = <int>[];
        final times = <int>[];
        for (final quality in <int>[9, 10, 11]) {
          final stopwatch = Stopwatch()..start();
          sizes.add(
            highRatioEncode(
              input,
              BrotliEncodeOptions(quality: quality),
            ).length,
          );
          times.add(stopwatch.elapsedMilliseconds);
        }
        final ref10 = await cliCompress(input, quality: 10);
        final ref11 = await cliCompress(input, quality: 11);
        report.writeln(
          '  ${entry.key.padRight(18)} '
          'in=${input.length.toString().padLeft(8)} '
          'q9=${sizes[0].toString().padLeft(8)} '
          'q10=${sizes[1].toString().padLeft(8)} '
          'q11=${sizes[2].toString().padLeft(8)} '
          'ref10=${ref10.length.toString().padLeft(8)} '
          'ref11=${ref11.length.toString().padLeft(8)} '
          'q10/r10=${(sizes[1] / ref10.length).toStringAsFixed(4)} '
          'q11/r11=${(sizes[2] / ref11.length).toStringAsFixed(4)} '
          'ms=${times[0]}/${times[1]}/${times[2]}',
        );
        expect(sizes[1], lessThanOrEqualTo(sizes[0]));
        expect(sizes[2], lessThanOrEqualTo(sizes[1]));
        if (entry.key == 'binary-256k') {
          expect(sizes[2], lessThanOrEqualTo(input.length + 64));
        } else {
          expect(sizes[2], lessThan(input.length));
        }
        expect(sizes[2] / ref11.length, lessThan(1.3));
        // The reference q11 stream decodes with our decoder.
        expectSameBytes(
          brotliDecode(ref11),
          input,
          reason: 'reference q11 ${entry.key}',
        );
      }
      print(report.toString().trimRight());
    }, timeout: const Timeout(Duration(minutes: 15)));
  }, skip: cliSkip);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

HashChainMatcher _matcher() =>
    HashChainMatcher(bucketBits: 15, blockBits: 8, numLastDistances: 16);

ParseCostModel _modelFor(Uint8List input) {
  final commands = CommandBuffer(input.length);
  createBackwardReferences(
    input,
    0,
    input.length,
    _matcher(),
    commands,
    createSearchDistanceCache(),
    (1 << 22) - 16,
    extensiveSearch: true,
  );
  return ParseCostModel.fromCommands(input, 0, input.length, commands);
}

CommandBuffer _guidedCommands(Uint8List input) {
  final hasher = _matcher();
  final commands = CommandBuffer(input.length);
  final cache = createSearchDistanceCache();
  createBackwardReferences(
    input,
    0,
    input.length,
    hasher,
    commands,
    cache,
    (1 << 22) - 16,
    extensiveSearch: true,
  );
  final model = ParseCostModel.fromCommands(input, 0, input.length, commands);
  final guided = CommandBuffer(input.length);
  final guidedCache = createSearchDistanceCache();
  prepareDistanceCache(guidedCache, hasher.numLastDistances);
  hasher.beginJournal(input.length + 4);
  createGuidedBackwardReferences(
    input,
    0,
    input.length,
    hasher,
    guided,
    guidedCache,
    (1 << 22) - 16,
    model,
    lazySteps: 1,
  );
  hasher.rollbackJournal();
  hasher.endJournal();
  return guided;
}

enum _DataKind { text, cjkVaried, alternating, binary, zeros }

Uint8List _data(_DataKind kind, int size, {int seed = 0}) {
  switch (kind) {
    case _DataKind.text:
      return aliceText(size);
    case _DataKind.cjkVaried:
      return variedCjk(size, seed + 1);
    case _DataKind.alternating:
      return alternatingTextBinary(size, seed + 2);
    case _DataKind.binary:
      return randomBytes(size, 0xB07 + seed);
    case _DataKind.zeros:
      return Uint8List(size);
  }
}

/// Checks the size bound, then decodes [compressed] with the reference CLI
/// and with our decoder.
Future<void> _expectRoundTrip(
  Uint8List input,
  Uint8List compressed, {
  required String reason,
}) async {
  expect(
    compressed.length,
    lessThanOrEqualTo(maxCompressedSize(input.length)),
    reason: '$reason: output exceeds maxCompressedSize',
  );
  expectSameBytes(
    await cliDecompress(compressed),
    input,
    reason: '$reason: reference CLI',
  );
  expectSameBytes(brotliDecode(compressed), input, reason: '$reason: ours');
}
