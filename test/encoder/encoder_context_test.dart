@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:brotli_fast/src/encoder/backward_references.dart';
import 'package:brotli_fast/src/encoder/bit_writer.dart';
import 'package:brotli_fast/src/encoder/block_split.dart';
import 'package:brotli_fast/src/encoder/command.dart';
import 'package:brotli_fast/src/encoder/context_modeling.dart';
import 'package:brotli_fast/src/encoder/encoder.dart';
import 'package:brotli_fast/src/encoder/match_finder.dart';
import 'package:brotli_fast/src/encoder/metablock_writer.dart';
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

import '../support/brotli_cli.dart';
import '../support/encoder_round_trip.dart';
import '../support/high_ratio.dart';

const int _kKiB = 1024;
const int _kMiB = 1 << 20;

void main() {
  group('context entropy utilities', () {
    test('deterministicLog2 matches log2 for representative values', () {
      const cases = <int, double>{
        0: 0.0,
        1: 0.0,
        2: 1.0,
        3: 1.584962500721156,
        4: 2.0,
        7: 2.807354922057604,
        8: 3.0,
        255: 7.994353436858858,
        256: 8.0,
        1000: 9.965784284662087,
        65536: 16.0,
        1 << 20: 20.0,
      };
      for (final entry in cases.entries) {
        expect(
          deterministicLog2(entry.key),
          closeTo(entry.value, 1e-9),
          reason: 'log2(${entry.key})',
        );
      }
    });

    test('estimateEntropy is total bits, not bits per symbol', () {
      // 200 symbols over two equiprobable values is exactly 200 bits.
      expect(
        estimateEntropy(Uint32List.fromList(<int>[100, 100]), 2),
        closeTo(200.0, 1e-6),
      );
      // 400 symbols over four equiprobable values is exactly 800 bits.
      expect(
        estimateEntropy(Uint32List.fromList(<int>[100, 100, 100, 100]), 4),
        closeTo(800.0, 1e-6),
      );
      // A single value carries no information.
      expect(
        estimateEntropy(Uint32List.fromList(<int>[1000, 0, 0]), 3),
        closeTo(0.0, 1e-9),
      );
    });
  });

  group('literal context selection', () {
    test('pure ASCII text keeps a single literal tree', () {
      // The heuristic samples UTF-8 *prefix* classes: ASCII is one class, so
      // no conditional histograms can be inferred from it. (The 13-context
      // complex map that covers ASCII needs a >= 1 MiB size hint; see
      // `encoder_complex_context_test.dart`.)
      for (final quality in <int>[6, 7, 11]) {
        expect(
          chooseLiteralContextCount(_textAlice, 0, _textAlice.length, quality),
          1,
          reason: 'quality $quality',
        );
        expect(
          chooseLiteralContextModel(_textAlice, 0, _textAlice.length, quality),
          isNull,
        );
      }
    });

    test('mixed UTF-8 text selects 2 contexts at quality 6 and 3 at quality 7', () {
      // Cyrillic UTF-8: splitting literals on "previous byte is a continuation
      // byte" already pays off, so quality 6 picks the 2-context map while
      // quality 7 (where 3 contexts become affordable) picks the 3-context one.
      final cyrillic = _data(_DataKind.cyrillic, 60000);
      expect(chooseLiteralContextCount(cyrillic, 0, cyrillic.length, 6), 2);
      expect(chooseLiteralContextCount(cyrillic, 0, cyrillic.length, 7), 3);
      final model6 = chooseLiteralContextModel(cyrillic, 0, cyrillic.length, 6);
      final model7 = chooseLiteralContextModel(cyrillic, 0, cyrillic.length, 7);
      expect(model6, same(kSimpleUtf8Contexts));
      expect(model7, same(kContinuationContexts));
      expect(model6!.contextMap, orderedEquals(kStaticContextMapSimpleUtf8));
      expect(model7!.contextMap, orderedEquals(kStaticContextMapContinuation));
      for (final model in <LiteralContextModel>[model6, model7]) {
        expect(model.contextMap, hasLength(kNumLiteralContexts));
        for (final value in model.contextMap) {
          expect(value, lessThan(model.numClusters));
        }
      }
      // CJK text needs the 3-context split; quality 6 never picks 3 contexts.
      final utf8Text = _variedCjk(60000, 1);
      expect(chooseLiteralContextCount(utf8Text, 0, utf8Text.length, 6), 1);
      expect(chooseLiteralContextCount(utf8Text, 0, utf8Text.length, 7), 3);
      expect(chooseLiteralContextCount(utf8Text, 0, utf8Text.length, 11), 3);
    });

    test('short blocks and low qualities never use contexts', () {
      final utf8Text = _variedCjk(60000, 2);
      expect(chooseLiteralContextCount(utf8Text, 0, 63, 7), 1);
      expect(chooseLiteralContextCount(utf8Text, 0, 60000, 4), 1);
      expect(chooseLiteralContextCount(utf8Text, 0, 60000, 5), 1);
      // A block starting halfway through the sample still sees UTF-8 bytes.
      expect(chooseLiteralContextCount(utf8Text, 30000, 30000, 7), 3);
    });

    test('literalContextId follows the UTF-8 context lookup table', () {
      // Values taken from c/common/context.c (CONTEXT_UTF8 slices).
      expect(kUtf8ContextLookup[0x20], 8); // space, last byte
      expect(kUtf8ContextLookup[0x61], 56); // 'a', last byte
      expect(kUtf8ContextLookup[256 + 0x41], 2); // 'A', second last byte
      expect(kUtf8ContextLookup[256 + 0x20], 0); // space, second last byte
      final input = Uint8List.fromList(<int>[0x41, 0x20, 0x61, 0x62]);
      expect(literalContextId(input, 0), 0);
      expect(literalContextId(input, 1), 48); // p1 = 'A', p2 = 0
      expect(literalContextId(input, 2), 8 | 2); // p1 = ' ', p2 = 'A'
      expect(literalContextId(input, 3), 56 | 0); // p1 = 'a', p2 = ' '
      for (var pos = 0; pos < input.length; pos++) {
        expect(literalContextId(input, pos), inInclusiveRange(0, 63));
      }
    });
  });

  group('context map serialisation', () {
    final ascii = Uint8List.sublistView(_textAlice, 0, 4096);
    final utf8Text = _variedCjk(4096, 3);

    final cases = <String, LiteralContextModel>{
      '2 clusters, all zero': LiteralContextModel(2, Uint8List(64)),
      '3 clusters, all zero': LiteralContextModel(3, Uint8List(64)),
      '2 clusters, alternating': LiteralContextModel(
        2,
        _mapPattern(<int>[0, 1]),
      ),
      '3 clusters, alternating': LiteralContextModel(
        3,
        _mapPattern(<int>[0, 1, 2]),
      ),
      // MTF of [1,0,1,0,...] has no zeros, so the RLEMAX flag stays 0.
      '2 clusters, no zero runs': LiteralContextModel(
        2,
        _mapPattern(<int>[1, 0]),
      ),
      '2 clusters, leading runs': LiteralContextModel(
        2,
        Uint8List.fromList(<int>[...List<int>.filled(60, 0), 1, 1, 1, 1]),
      ),
      '3 clusters, trailing runs': LiteralContextModel(
        3,
        Uint8List.fromList(<int>[1, 1, 2, 2, ...List<int>.filled(60, 0)]),
      ),
      'static simple UTF-8': kSimpleUtf8Contexts,
      'static continuation': kContinuationContexts,
    };

    for (final entry in cases.entries) {
      test('${entry.key}: header and decode', () async {
        final model = entry.value;
        final compressed = _compressSingleBlock(ascii, model);
        final header = _MetablockHeader.parse(compressed);
        expect(header.lgwin, 22);
        expect(header.isLast, isTrue);
        expect(header.isUncompressed, isFalse);
        expect(header.numLiteralBlockTypes, 1);
        expect(header.numCommandBlockTypes, 1);
        expect(header.numDistanceBlockTypes, 1);
        expect(header.literalContextMode, kLiteralContextModeUtf8);
        expect(header.numLiteralTrees, model.numClusters);
        await expectDecodes(compressed, ascii, reason: entry.key);
      });
    }

    test('context-conditioned blocks decode for UTF-8 payloads', () async {
      final compressed2 = _compressSingleBlock(utf8Text, kSimpleUtf8Contexts);
      final compressed3 = _compressSingleBlock(utf8Text, kContinuationContexts);
      await expectDecodes(compressed2, utf8Text, reason: '2 clusters');
      await expectDecodes(compressed3, utf8Text, reason: '3 clusters');
    });

    test(
      'context serialisation is smaller than one tree on UTF-8 data',
      () async {
        // This is the actual win of the feature: 2/3 conditional literal trees
        // beat a single tree on UTF-8 text by several percent.
        final plain = _compressSingleBlock(utf8Text, null);
        final ctx2 = _compressSingleBlock(utf8Text, kSimpleUtf8Contexts);
        final ctx3 = _compressSingleBlock(utf8Text, kContinuationContexts);
        expect(ctx2.length, lessThan(plain.length));
        expect(ctx3.length, lessThan(plain.length));
        // Repeating the earlier measurement: ~5% on 64 KiB of varied CJK.
        final big = _variedCjk(64 * _kKiB, 4);
        final plainBig = _compressSingleBlock(big, null);
        final ctxBig = _compressSingleBlock(big, kContinuationContexts);
        expect(
          ctxBig.length,
          lessThan((plainBig.length * 97) ~/ 100),
          reason: 'context modeling should win by at least 3% on UTF-8 text',
        );
        await expectDecodes(plainBig, big, reason: 'plain big');
        await expectDecodes(ctxBig, big, reason: 'context big');
      },
    );
  }, skip: brotliCliSkipReason());

  group('quality 2/3 reference round-trip', () {
    for (final quality in <int>[2, 3]) {
      test('quality $quality: boundary sizes and data kinds', () async {
        const sizes = <int>[
          0, 1, 2, 3, 4, 5, 15, 16, 17, 63, 64, 65, 255, 256, 1023, 4095, //
          65535, 65536, 65537, 131071, 131072, 131073,
        ];
        for (final kind in _DataKind.values) {
          for (final size in sizes) {
            await expectEncodeRoundTrip(
              _data(kind, size),
              quality: quality,
              reason: 'q$quality ${kind.name} $size',
            );
          }
        }
      });

      test('quality $quality: sizes around 1 MiB and 2 MiB', () async {
        for (final kind in <_DataKind>[
          _DataKind.text,
          _DataKind.cjkVaried,
          _DataKind.repetitive,
        ]) {
          for (final size in <int>[_kMiB - 1, _kMiB, _kMiB + 1, 2 * _kMiB]) {
            await expectEncodeRoundTrip(
              _data(kind, size),
              quality: quality,
              reason: 'q$quality ${kind.name} $size',
            );
          }
        }
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('quality $quality: every window size round-trips', () async {
        final input = _data(_DataKind.cjkVaried, 70000);
        for (var lgwin = 10; lgwin <= 24; lgwin++) {
          await expectEncodeRoundTrip(
            input,
            quality: quality,
            lgwin: lgwin,
            reason: 'q$quality lgwin $lgwin',
          );
        }
      });

      test('quality $quality: deterministic and bounded', () {
        final input = _data(_DataKind.cjkVaried, 100000);
        final first = encodePaths(input, quality: quality);
        final second = encodePaths(input, quality: quality);
        for (final key in first.keys) {
          expect(second[key], orderedEquals(first[key]!), reason: key);
          expect(
            first[key]!.length,
            lessThanOrEqualTo(maxCompressedSize(input.length)),
            reason: key,
          );
        }
        for (final kind in _DataKind.values) {
          for (final size in <int>[1, 17, 1000, 65536]) {
            final plain = _data(kind, size);
            for (final entry in encodePaths(plain, quality: quality).entries) {
              expect(
                entry.value.length,
                lessThanOrEqualTo(maxCompressedSize(size)),
                reason: 'q$quality ${kind.name} $size ${entry.key}',
              );
            }
          }
        }
      });
    }

    test('qualities 2..4 share the fast 8-candidate configuration', () {
      final input = _data(_DataKind.text, 64 * _kKiB);
      // On the high-ratio path qualities 2..4 run exactly the same parser
      // (they are separate dispatch entries for later tuning).
      expect(_highRatio(input, 2), orderedEquals(_highRatio(input, 4)));
      expect(_highRatio(input, 3), orderedEquals(_highRatio(input, 4)));
      // Quality 5 raises the effort and must produce a different (smaller)
      // stream on text.
      expect(_highRatio(input, 5), isNot(orderedEquals(_highRatio(input, 4))));
      expect(
        _highRatio(input, 5).length,
        lessThan(_highRatio(input, 4).length),
      );
    });

    test('quality 2/3 beat quality 1 on text', () {
      final sources = <String, Uint8List>{
        'alice29.txt': _textAlice,
        'plrabn12.txt': _textPlrabn12,
        'text-256k': _data(_DataKind.text, 256 * _kKiB),
        'cjk-varied-256k': _data(_DataKind.cjkVaried, 256 * _kKiB),
      };
      for (final entry in sources.entries) {
        final q1 = _highRatio(entry.value, 1).length;
        for (final quality in <int>[2, 3]) {
          final ours = _highRatio(entry.value, quality).length;
          expect(
            ours,
            lessThanOrEqualTo((q1 * 99) ~/ 100),
            reason: 'q$quality ${entry.key}',
          );
        }
      }
    });
  }, skip: brotliCliSkipReason());

  group('quality 6/7 literal contexts', () {
    for (final quality in <int>[6, 7]) {
      test('quality $quality: boundary sizes and data kinds', () async {
        const sizes = <int>[
          0, 1, 2, 3, 4, 5, 15, 16, 17, 63, 64, 65, 255, 256, 1023, 4095, //
          65535, 65536, 65537, 131071, 131072, 131073,
        ];
        for (final kind in _DataKind.values) {
          for (final size in sizes) {
            await expectEncodeRoundTrip(
              _data(kind, size),
              quality: quality,
              reason: 'q$quality ${kind.name} $size',
            );
          }
        }
      });

      test('quality $quality: sizes around 1 MiB and 2 MiB', () async {
        for (final kind in _DataKind.values) {
          for (final size in <int>[1 * _kMiB, 2 * _kMiB]) {
            await expectEncodeRoundTrip(
              _data(kind, size),
              quality: quality,
              reason: 'q$quality ${kind.name} $size',
            );
          }
        }
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('quality $quality: every window size round-trips', () async {
        final input = _data(_DataKind.cjkVaried, 70000);
        for (var lgwin = 10; lgwin <= 24; lgwin++) {
          await expectEncodeRoundTrip(
            input,
            quality: quality,
            lgwin: lgwin,
            reason: 'q$quality lgwin $lgwin',
          );
        }
      });

      test('quality $quality: deterministic', () {
        final input = _data(_DataKind.cjkVaried, 100000);
        final first = brotliEncode(input, quality: quality);
        expect(brotliEncode(input, quality: quality), orderedEquals(first));
      });
    }

    test('qualities 10/11 beat quality 9 on varied CJK', () {
      // The guided (cost-model) parse pays off on UTF-8 mixed-script literals:
      // quality 10 must be strictly smaller than quality 9, quality 11 must not
      // be larger than quality 10.
      final input = _data(_DataKind.cjkVaried, 100000);
      final q9 = _highRatio(input, 9);
      final q10 = _highRatio(input, 10);
      final q11 = _highRatio(input, 11);
      expect(q10, isNot(orderedEquals(q9)), reason: 'q10 is a distinct path');
      expect(q10.length, lessThan(q9.length), reason: 'q10 < q9 on CJK');
      expect(q11.length, lessThanOrEqualTo(q10.length), reason: 'q11 <= q10');
    });

    test('quality 6/7 select context modeling for UTF-8 blocks', () async {
      // Cyrillic UTF-8: quality 6 picks 2 contexts, quality 7 picks 3.
      final input = _data(_DataKind.cyrillic, 256 * _kKiB);
      final commands = _commandsFor(input);
      final split6 = buildMetaBlockSplit(
        input,
        0,
        input.length,
        commands,
        chooseLiteralContextModel(input, 0, input.length, 6),
      );
      final split7 = buildMetaBlockSplit(
        input,
        0,
        input.length,
        commands,
        chooseLiteralContextModel(input, 0, input.length, 7),
      );
      expect(split6.numLiteralContexts, 2);
      expect(split7.numLiteralContexts, 3);
      // Literal histograms are clustered, so the number of literal trees is
      // between 1 and (block types x contexts); every context map entry must
      // select a valid tree.
      for (final split in <MetaBlockSplit>[split6, split7]) {
        expect(split.numLiteralTrees, greaterThanOrEqualTo(1));
        expect(
          split.numLiteralTrees,
          lessThanOrEqualTo(
            split.literalSplit.numTypes * split.numLiteralContexts,
          ),
        );
        for (final tree in split.literalContextMap) {
          expect(tree, lessThan(split.numLiteralTrees));
        }
      }
      await expectEncodeRoundTrip(input, quality: 6, reason: 'q6 utf8');
      await expectEncodeRoundTrip(input, quality: 7, reason: 'q7 utf8');
      // (On this repetitive Cyrillic sample the extra context tree costs a few
      // bytes, so no size ordering is asserted between the two tiers.)
      // CJK needs the 3-context split, so quality 6 keeps one context and
      // quality 7 switches context modeling on.
      final cjk = _data(_DataKind.cjkVaried, 256 * _kKiB);
      final cjkCommands = _commandsFor(cjk);
      expect(
        buildMetaBlockSplit(
          cjk,
          0,
          cjk.length,
          cjkCommands,
          chooseLiteralContextModel(cjk, 0, cjk.length, 6),
        ).numLiteralContexts,
        1,
      );
      expect(
        buildMetaBlockSplit(
          cjk,
          0,
          cjk.length,
          cjkCommands,
          chooseLiteralContextModel(cjk, 0, cjk.length, 7),
        ).numLiteralContexts,
        3,
      );
    });

    test('ASCII text keeps a single literal context end to end', () {
      final input = _data(_DataKind.text, 256 * _kKiB);
      final commands = _commandsFor(input);
      for (final quality in <int>[6, 7]) {
        final split = buildMetaBlockSplit(
          input,
          0,
          input.length,
          commands,
          chooseLiteralContextModel(input, 0, input.length, quality),
        );
        expect(split.numLiteralContexts, 1, reason: 'q$quality');
        // Every context of every block type maps into the literal tree set.
        expect(
          split.literalContextMap.length,
          split.literalSplit.numTypes * 64,
        );
      }
    });

    test('literal context tiers never lose to the tier below on text', () {
      final sources = <String, Uint8List>{
        'alice29.txt': _textAlice,
        'plrabn12.txt': _textPlrabn12,
        'cjk-varied-256k': _data(_DataKind.cjkVaried, 256 * _kKiB),
        'text-1m': _data(_DataKind.text, _kMiB),
      };
      for (final entry in sources.entries) {
        final sizes = <int>[
          for (final quality in <int>[4, 5, 6, 7])
            _highRatio(entry.value, quality).length,
        ];
        expect(
          sizes[1],
          lessThanOrEqualTo(sizes[0]),
          reason: 'q5 ${entry.key}',
        );
        expect(
          sizes[2],
          lessThanOrEqualTo(sizes[1]),
          reason: 'q6 ${entry.key}',
        );
        expect(
          sizes[3],
          lessThanOrEqualTo(sizes[2]),
          reason: 'q7 ${entry.key}',
        );
        expect(sizes[3], lessThan(entry.value.length));
      }
    });
  }, skip: brotliCliSkipReason());

  group('ratio versus the reference encoder', () {
    test('report size ratios at quality 2/3/6/7', () async {
      final cases = <String, Uint8List>{
        'alice-152k': _textAlice,
        'plrabn12-482k': _textPlrabn12,
        'text-1m': _data(_DataKind.text, _kMiB),
        'cjk-varied-256k': _data(_DataKind.cjkVaried, 256 * _kKiB),
        'repetitive-256k': _data(_DataKind.repetitive, 256 * _kKiB),
        'zeros-1m': _data(_DataKind.zeros, _kMiB),
        'random-256k': _data(_DataKind.random, 256 * _kKiB),
      };
      final report = StringBuffer(
        'ratio report (ours / brotli CLI, quality 2/3/6/7):\n',
      );
      for (final quality in <int>[2, 3, 6, 7]) {
        for (final entry in cases.entries) {
          final input = entry.value;
          final reference = await cliCompress(input, quality: quality);
          final paths = encodePaths(input, quality: quality);
          for (final path in paths.entries) {
            final ours = path.value;
            final ratio = ours.length / reference.length;
            final label = 'q$quality ${entry.key} ${path.key}';
            report.writeln(
              '  ${label.padRight(32)} '
              'in=${input.length.toString().padLeft(8)} '
              'ours=${ours.length.toString().padLeft(8)} '
              'ref=${reference.length.toString().padLeft(8)} '
              'ratio=${ratio.toStringAsFixed(4)}',
            );
            if (entry.key == 'random-256k') {
              expect(ours.length, lessThanOrEqualTo(input.length + 64));
              expect(ratio, lessThan(1.001), reason: label);
            } else if (entry.key.startsWith('zeros') ||
                entry.key.startsWith('repetitive')) {
              // Very short copies dominate; absolute size stays tiny.
              expect(ours.length, lessThan(input.length ~/ 100), reason: label);
            } else if (paths.length == 1 || path.key == 'high-ratio') {
              // Within a few percent of the reference at the same quality.
              // (The one-shot fast tier at q2/3 trades a little ratio for
              // speed; its numbers are reported only.)
              expect(
                ratio,
                lessThan(1.08),
                reason: '$label is unexpectedly large',
              );
            }
          }
        }
      }
      print(report.toString().trimRight());
    });
  }, skip: brotliCliSkipReason());
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Uint8List _highRatio(Uint8List input, int quality) =>
    highRatioEncode(input, BrotliEncodeOptions(quality: quality));

/// Builds the LZ77 command stream for [input] with the quality-8 matcher.
CommandBuffer _commandsFor(Uint8List input) {
  final hasher = HashChainMatcher(
    bucketBits: 15,
    blockBits: 7,
    numLastDistances: 10,
  );
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
  return commands;
}

/// Compresses [input] as a single compressed meta-block (a complete stream).
///
/// Used to exercise [MetaBlockWriter]'s context-map path directly, including
/// models the heuristic would not choose.
Uint8List _compressSingleBlock(Uint8List input, LiteralContextModel? model) {
  final writer = BitWriter();
  writer.writeBits(4, 0xB); // lgwin 22
  final hasher = HashChainMatcher(
    bucketBits: 14,
    blockBits: 3,
    numLastDistances: 4,
  );
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
  MetaBlockWriter().store(
    writer,
    input,
    0,
    input.length,
    commands,
    isLast: true,
    contexts: model,
  );
  writer.alignToByte();
  return Uint8List.fromList(writer.toBytes());
}

Uint8List _mapPattern(List<int> pattern) {
  final map = Uint8List(kNumLiteralContexts);
  for (var i = 0; i < map.length; i++) {
    map[i] = pattern[i % pattern.length];
  }
  return map;
}

/// Header fields of the first meta-block, parsed LSB-first.
final class _MetablockHeader {
  _MetablockHeader._({
    required this.lgwin,
    required this.isLast,
    required this.isUncompressed,
    required this.numLiteralBlockTypes,
    required this.numCommandBlockTypes,
    required this.numDistanceBlockTypes,
    required this.literalContextMode,
    required this.numLiteralTrees,
  });

  final int lgwin;
  final bool isLast;
  final bool isUncompressed;
  final int numLiteralBlockTypes;
  final int numCommandBlockTypes;
  final int numDistanceBlockTypes;
  final int literalContextMode;
  final int numLiteralTrees;

  static _MetablockHeader parse(Uint8List stream) {
    var bitPosition = 0;
    int readBits(int count) {
      var value = 0;
      for (var i = 0; i < count; i++) {
        final byte = stream[bitPosition >> 3];
        final bit = (byte >> (bitPosition & 7)) & 1;
        value |= bit << i;
        bitPosition++;
      }
      return value;
    }

    int readVarLenUint8() {
      if (readBits(1) == 0) return 0;
      final nbits = readBits(3);
      if (nbits == 0) return 1;
      return (1 << nbits) + readBits(nbits);
    }

    final windowFlag = readBits(1);
    final int lgwin;
    if (windowFlag == 0) {
      lgwin = 16;
    } else {
      final n1 = readBits(3);
      if (n1 != 0) {
        lgwin = 17 + n1;
      } else {
        final n2 = readBits(3);
        lgwin = n2 == 0 ? 17 : 8 + n2;
      }
    }
    final isLast = readBits(1) == 1;
    var isUncompressed = false;
    if (isLast) {
      final isEmpty = readBits(1) == 1;
      if (isEmpty) {
        return _MetablockHeader._(
          lgwin: lgwin,
          isLast: true,
          isUncompressed: false,
          numLiteralBlockTypes: 0,
          numCommandBlockTypes: 0,
          numDistanceBlockTypes: 0,
          literalContextMode: 0,
          numLiteralTrees: 0,
        );
      }
    }
    final nibbles = readBits(2) + 4;
    for (var i = 0; i < nibbles * 4; i++) {
      readBits(1);
    }
    if (!isLast) isUncompressed = readBits(1) == 1;
    if (isUncompressed) {
      return _MetablockHeader._(
        lgwin: lgwin,
        isLast: isLast,
        isUncompressed: true,
        numLiteralBlockTypes: 0,
        numCommandBlockTypes: 0,
        numDistanceBlockTypes: 0,
        literalContextMode: 0,
        numLiteralTrees: 0,
      );
    }
    final numLiteralTypes = readVarLenUint8() + 1;
    final numCommandTypes = readVarLenUint8() + 1;
    final numDistanceTypes = readVarLenUint8() + 1;
    // The helper below always writes NPOSTFIX = NDIRECT = 0.
    readBits(2);
    readBits(4);
    final modes = <int>[];
    for (var i = 0; i < numLiteralTypes; i++) {
      modes.add(readBits(2));
    }
    // The literal context map follows; it is not parsed here (both decoders
    // validate it), only the tree count is needed.
    final numLiteralTrees = readVarLenUint8() + 1;
    return _MetablockHeader._(
      lgwin: lgwin,
      isLast: isLast,
      isUncompressed: isUncompressed,
      numLiteralBlockTypes: numLiteralTypes,
      numCommandBlockTypes: numCommandTypes,
      numDistanceBlockTypes: numDistanceTypes,
      literalContextMode: modes.isEmpty ? 0 : modes.first,
      numLiteralTrees: numLiteralTrees,
    );
  }
}

// ---------------------------------------------------------------------------
// Data fixtures
// ---------------------------------------------------------------------------

final Uint8List _textAlice = File('test/testdata/alice29.txt')
    .readAsBytesSync();
final Uint8List _textPlrabn12 = File('test/testdata/plrabn12.txt')
    .readAsBytesSync();

enum _DataKind { text, cjkVaried, cyrillic, repetitive, random, zeros }

/// Deterministic UTF-8 text: random CJK code points with occasional spaces.
Uint8List _variedCjk(int size, int seed) {
  final random = Random(seed);
  final builder = StringBuffer();
  while (builder.length < size) {
    builder.writeCharCode(0x4E00 + random.nextInt(2000));
    if (random.nextInt(8) == 0) builder.write(' ');
  }
  final bytes = utf8.encode(builder.toString());
  return Uint8List.fromList(bytes.take(size).toList());
}

Uint8List _data(_DataKind kind, int size, {int seed = 0}) {
  switch (kind) {
    case _DataKind.text:
      return _repeatToSize(_textAlice, size);
    case _DataKind.cjkVaried:
      return _variedCjk(size, seed + 1);
    case _DataKind.cyrillic:
      return _repeatToSize(
        utf8.encode(
          'Съешь ещё этих мягких французских булок, да выпей чаю. '
          'Широкая электрификация южных губерний даст мощный толчок. ',
        ),
        size,
      );
    case _DataKind.repetitive:
      final pattern = utf8.encode(
        'brotli_fast stage-2b literal context modeling 0123456789 abcdefghij ',
      );
      return _repeatToSize(pattern, size);
    case _DataKind.random:
      final random = Random(0xB07 + seed);
      final out = Uint8List(size);
      for (var i = 0; i < size; i++) {
        out[i] = random.nextInt(256);
      }
      return out;
    case _DataKind.zeros:
      return Uint8List(size);
  }
}

Uint8List _repeatToSize(List<int> pattern, int size) {
  final out = Uint8List(size);
  if (pattern.isEmpty) return out;
  for (var i = 0; i < size; i++) {
    out[i] = pattern[i % pattern.length];
  }
  return out;
}
