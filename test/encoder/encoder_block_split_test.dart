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
import 'package:brotli_fast/src/encoder/encoder.dart';
import 'package:brotli_fast/src/encoder/match_finder.dart';
import 'package:brotli_fast/src/encoder/metablock_writer.dart';
import 'package:brotli_fast/src/encoder/split_metablock_writer.dart';
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

import '../support/brotli_cli.dart';
import '../support/encoder_round_trip.dart';
import '../support/high_ratio.dart';

const int _kKiB = 1024;
const int _kMiB = 1 << 20;

void main() {
  group('block split primitives', () {
    test('block length prefix codes cover the RFC ranges', () {
      expect(blockLengthPrefixCode(1), 0);
      expect(blockLengthPrefixCode(4), 0);
      expect(blockLengthPrefixCode(5), 1);
      expect(blockLengthPrefixCode(8), 1);
      expect(blockLengthPrefixCode(9), 2);
      expect(blockLengthPrefixCode(16), 3);
      expect(blockLengthPrefixCode(17), 4);
      expect(blockLengthPrefixCode(40), 6);
      expect(blockLengthPrefixCode(41), 7);
      expect(blockLengthPrefixCode(176), 13);
      expect(blockLengthPrefixCode(177), 14);
      expect(blockLengthPrefixCode(752), 19);
      expect(blockLengthPrefixCode(753), 20);
      expect(blockLengthPrefixCode(16624), 24);
      expect(blockLengthPrefixCode(16625), 25);
      expect(blockLengthPrefixCode(kChainBlockSize), 25); // 131072
      for (var code = 0; code < kNumBlockLengthCodes; code++) {
        final base = kBlockLengthCodeOffset[code];
        expect(
          blockLengthPrefixCode(base),
          code,
          reason: 'base $base -> code $code',
        );
        final top = code == kNumBlockLengthCodes - 1
            ? kMaxMetaBlockLength
            : kBlockLengthCodeOffset[code + 1] - 1;
        expect(
          blockLengthPrefixCode(top),
          code,
          reason: 'top $top -> code $code',
        );
      }
    });

    test('block type codes follow the reference calculator', () {
      // Initial state mirrors the encoder (last = 1, second-last = 0); the
      // first block (type 0) is never coded but advances the state.
      final calculator = BlockTypeCodeCalculator();
      expect(calculator.next(0), 0);
      expect(calculator.next(1), 1); // last + 1
      expect(calculator.next(0), 0); // second-to-last
      expect(calculator.next(2), 4); // type + 2
      // A fresh sequence is identical (no hidden state).
      final second = BlockTypeCodeCalculator();
      expect(
        <int>[second.next(0), second.next(1), second.next(0), second.next(2)],
        <int>[0, 1, 0, 4],
      );
    });

    test('histogramCost is entropy plus a small symbol penalty', () {
      final single = Uint32List.fromList(<int>[1000, 0, 0, 0]);
      expect(histogramCost(single, 4), closeTo(4.0, 1e-9));
      final two = Uint32List.fromList(<int>[500, 500, 0, 0]);
      // 1000 bits of entropy (500 * 1 bit twice) plus 2 symbols * 4 bits.
      expect(histogramCost(two, 4), closeTo(1000.0 + 8.0, 1e-6));
      final four = Uint32List.fromList(<int>[250, 250, 250, 250]);
      // 1000 symbols over four equiprobable values = 2000 bits + 4*4.
      expect(histogramCost(four, 4), closeTo(2000.0 + 16.0, 1e-6));
      expect(histogramCost(Uint32List(4), 4), 0.0);
    });

    test('clustering merges identical histograms and keeps distinct ones', () {
      final identical = <Uint32List>[
        for (var i = 0; i < 4; i++) Uint32List.fromList(<int>[100, 100, 0, 0]),
      ];
      final clusterOf = Uint8List(4);
      final merged = Uint32List(2 * 4);
      final clusters = clusterHistograms(
        identical,
        4,
        2,
        96.0,
        clusterOf,
        merged,
      );
      expect(clusters, 1);
      expect(clusterOf, orderedEquals(<int>[0, 0, 0, 0]));
      expect(merged.sublist(0, 4), orderedEquals(<int>[400, 400, 0, 0]));

      final distinct = <Uint32List>[
        Uint32List.fromList(<int>[200, 0, 0, 0]),
        Uint32List.fromList(<int>[0, 200, 0, 0]),
        Uint32List.fromList(<int>[0, 0, 200, 0]),
        Uint32List.fromList(<int>[0, 0, 0, 200]),
      ];
      final clusterOf2 = Uint8List(4);
      final merged2 = Uint32List(4 * 4);
      final clusters2 = clusterHistograms(
        distinct,
        4,
        4,
        96.0,
        clusterOf2,
        merged2,
      );
      expect(clusters2, 4);
      expect(clusterOf2, orderedEquals(<int>[0, 1, 2, 3]));
      for (var c = 0; c < 4; c++) {
        expect(merged2.sublist(c * 4, c * 4 + 4)[c], 200);
      }
    });

    test('splitSymbols keeps short and homogeneous vectors unsplit', () {
      final short = Uint16List.fromList(List<int>.generate(100, (i) => i % 4));
      final shortSplit = splitSymbols(short, 100, 4, 544, 100, 16);
      expect(shortSplit.numTypes, 1);
      expect(shortSplit.numBlocks, 1);
      expect(shortSplit.lengths[0], 100);

      // A periodic vector has indistinguishable chunks: one block type.
      final periodic = Uint16List.fromList(
        List<int>.generate(20000, (i) => i % 3),
      );
      final periodicSplit = splitSymbols(periodic, 20000, 4, 544, 100, 16);
      expect(periodicSplit.numTypes, 1);
      expect(periodicSplit.numBlocks, 1);
      expect(periodicSplit.lengths[0], 20000);
    });

    test('splitSymbols finds the two populations of a mixed vector', () {
      final random = Random(11);
      final symbols = Uint16List(20000);
      // First half: symbols 0..3, second half: symbols 200..203.
      for (var i = 0; i < 20000; i++) {
        symbols[i] = i < 10000 ? random.nextInt(4) : 200 + random.nextInt(4);
      }
      final split = splitSymbols(symbols, 20000, 256, 544, 100, 16);
      // Pure chunks collapse to two clusters; the chunk that straddles the
      // boundary may stay a third cluster.
      expect(split.numTypes, greaterThanOrEqualTo(2));
      expect(split.types.first, 0);
      expect(split.types[split.numBlocks - 1], isNot(0));
      // Blocks always partition the symbol vector.
      var total = 0;
      for (var i = 0; i < split.numBlocks; i++) {
        total += split.lengths[i];
      }
      expect(total, 20000);
    });

    test(
      'splitSymbols renumbers types by first appearance and merges runs',
      () {
        // Three stripes: symbols from populations A, B, A. The last stripe
        // must reuse type 0 and the middle one gets type 1.
        final random = Random(5);
        final symbols = Uint16List(30000);
        for (var i = 0; i < 30000; i++) {
          final stripe = i ~/ 10000;
          symbols[i] = stripe == 1
              ? 100 + random.nextInt(4)
              : random.nextInt(4);
        }
        final split = splitSymbols(symbols, 30000, 256, 544, 100, 16);
        expect(split.types.first, 0);
        expect(split.numTypes, greaterThanOrEqualTo(2));
        expect(split.numBlocks, greaterThanOrEqualTo(2));
        for (var i = 1; i < split.numBlocks; i++) {
          expect(split.types[i], isNot(split.types[i - 1]));
        }
        var total = 0;
        for (var i = 0; i < split.numBlocks; i++) {
          total += split.lengths[i];
        }
        expect(total, 30000);
      },
    );

    test('buildMetaBlockSplit reports consistent structures', () {
      final input = _alternatingTextBinary(64 * _kKiB, 3);
      final commands = _commandsFor(input);
      final split = buildMetaBlockSplit(input, 0, input.length, commands, null);
      expect(split.hasSplits, isTrue);
      expect(split.literalSplit.numTypes, greaterThan(1));
      expect(
        split.literalContextMap,
        hasLength(split.literalSplit.numTypes * 64),
      );
      expect(split.literalHistograms, hasLength(split.numLiteralTrees * 256));
      expect(
        split.commandHistograms,
        hasLength(split.commandSplit.numTypes * numCommandSymbols),
      );
      expect(
        split.distanceHistograms,
        hasLength(split.distanceSplit.numTypes * numDistanceSymbols),
      );
      var literalSplitTotal = 0;
      for (var i = 0; i < split.literalSplit.numBlocks; i++) {
        literalSplitTotal += split.literalSplit.lengths[i];
      }
      expect(split.literalBlockTypesByIndex.length, literalSplitTotal);
      for (final tree in split.literalContextMap) {
        expect(tree, lessThan(split.numLiteralTrees));
      }
      // Histograms add up to the number of symbols in each category.
      final literalCount = split.literalBlockTypesByIndex.length;
      var literalSum = 0;
      for (var i = 0; i < split.numLiteralTrees; i++) {
        for (var s = 0; s < 256; s++) {
          literalSum += split.literalHistograms[i * 256 + s];
        }
      }
      expect(literalSum, literalCount);
      final commandCount = commands.count;
      var commandSum = 0;
      for (
        var i = 0;
        i < split.commandSplit.numTypes * numCommandSymbols;
        i++
      ) {
        commandSum += split.commandHistograms[i];
      }
      expect(commandSum, commandCount);
    });
  });

  group('block-split stream structure', () {
    test('a split meta-block round-trips through both decoders', () async {
      final input = _alternatingTextBinary(64 * _kKiB, 7);
      final compressed = _compressSingleSplitBlock(input);
      final counts = _blockTypeCounts(compressed);
      expect(counts[0], greaterThan(1), reason: 'literals must be split');
      await expectDecodes(compressed, input, reason: 'split block');
    });

    test('the encoder uses block switching where it wins', () async {
      final alternating = _alternatingTextBinary(256 * _kKiB, 9);
      final q8 = brotliEncode(alternating, quality: 8);
      expect(
        q8,
        orderedEquals(
          highRatioEncode(alternating, const BrotliEncodeOptions(quality: 8)),
        ),
        reason: 'quality 8 has a single (high-ratio) path',
      );
      final counts = _blockTypeCounts(q8);
      expect(
        counts.any((count) => count > 1),
        isTrue,
        reason: 'alternating text/binary should use block types',
      );
      await expectRoundTrip(alternating, q8, reason: 'q8 alternating');

      // Quality 5 never splits: homogeneous meta-blocks only, on every path.
      for (final entry in encodePaths(alternating, quality: 5).entries) {
        expect(
          _blockTypeCounts(entry.value),
          orderedEquals(<int>[1, 1, 1]),
          reason: entry.key,
        );
      }
    });
  }, skip: brotliCliSkipReason());

  group('q6..q9 reference round-trip', () {
    for (final quality in <int>[6, 7, 8, 9]) {
      test('quality $quality: boundary sizes and data kinds', () async {
        const sizes = <int>[
          0, 1, 2, 3, 4, 5, 15, 16, 17, 63, 64, 65, 127, 128, 255, 256, //
          1023, 4095, 65535, 65536, 65537, 131071, 131072, 131073,
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
          _DataKind.alternating,
        ]) {
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
        final input = _data(_DataKind.alternating, 70000);
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
        final input = _data(_DataKind.alternating, 100000);
        final first = brotliEncode(input, quality: quality);
        expect(brotliEncode(input, quality: quality), orderedEquals(first));
        expect(
          first.length,
          lessThanOrEqualTo(maxCompressedSize(input.length)),
        );
      });
    }

    test('qualities 10/11 never lose to quality 9', () {
      // English text: the guided parses may tie with quality 9 here; they
      // must never be larger.
      final input = _data(_DataKind.text, 100000);
      final q9 = _highRatio(input, 9).length;
      final q10 = _highRatio(input, 10).length;
      final q11 = _highRatio(input, 11).length;
      expect(q10, lessThanOrEqualTo(q9));
      expect(q11, lessThanOrEqualTo(q10));
    });

    test('q8 <= q7 and q9 <= q8 on text', () {
      final sources = <String, Uint8List>{
        'alice29.txt': _textAlice,
        'plrabn12.txt': _textPlrabn12,
        'text-1m': _data(_DataKind.text, _kMiB),
      };
      for (final entry in sources.entries) {
        final sizes = <int>[
          for (final quality in <int>[7, 8, 9])
            _highRatio(entry.value, quality).length,
        ];
        expect(
          sizes[1],
          lessThanOrEqualTo(sizes[0]),
          reason: 'q8 ${entry.key}',
        );
        expect(
          sizes[2],
          lessThanOrEqualTo(sizes[1]),
          reason: 'q9 ${entry.key}',
        );
      }
      // Mixed UTF-8 content: the larger search wins, but a wider chain can
      // occasionally lose a byte or two to a different parse, so allow a tiny
      // tolerance there.
      final cjk = _data(_DataKind.cjkVaried, 256 * _kKiB);
      final q8 = _highRatio(cjk, 8).length;
      final q9 = _highRatio(cjk, 9).length;
      expect(q9, lessThanOrEqualTo((q8 * 1005) ~/ 1000));
    });
  }, skip: brotliCliSkipReason());

  group('ratio versus the reference encoder', () {
    test('report size ratios at quality 8 and 9', () async {
      final cases = <String, Uint8List>{
        'alice-152k': _textAlice,
        'plrabn12-482k': _textPlrabn12,
        'text-1m': _data(_DataKind.text, _kMiB),
        'text-2m': _data(_DataKind.text, 2 * _kMiB),
        'cjk-varied-256k': _data(_DataKind.cjkVaried, 256 * _kKiB),
        'alt-text-bin-256k': _alternatingTextBinary(256 * _kKiB, 13),
        'alt-text-bin-1m': _alternatingTextBinary(_kMiB, 14),
        'random-256k': _data(_DataKind.random, 256 * _kKiB),
      };
      final report = StringBuffer(
        'ratio report (ours / brotli CLI, quality 8/9):\n',
      );
      for (final quality in <int>[8, 9]) {
        for (final entry in cases.entries) {
          final input = entry.value;
          final ours = brotliEncode(input, quality: quality);
          final reference = await cliCompress(input, quality: quality);
          final ratio = ours.length / reference.length;
          report.writeln(
            '  q$quality ${entry.key.padRight(18)} '
            'in=${input.length.toString().padLeft(8)} '
            'ours=${ours.length.toString().padLeft(8)} '
            'ref=${reference.length.toString().padLeft(8)} '
            'ratio=${ratio.toStringAsFixed(4)}',
          );
          if (entry.key == 'random-256k') {
            expect(ours.length, lessThanOrEqualTo(input.length + 64));
          } else {
            // Block splitting + clustering is expected to stay within a few
            // percent of the reference; alternating content can even win.
            expect(
              ratio,
              lessThan(1.08),
              reason: 'q$quality ${entry.key} is unexpectedly large',
            );
            expect(ours.length, lessThan(input.length));
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

/// Compresses [input] as a single split meta-block (a complete stream).
Uint8List _compressSingleSplitBlock(Uint8List input) {
  final writer = BitWriter();
  writer.writeBits(4, 0xB); // lgwin 22
  final commands = _commandsFor(input);
  final split = buildMetaBlockSplit(input, 0, input.length, commands, null);
  SplitMetaBlockWriter().store(
    writer,
    input,
    0,
    input.length,
    commands,
    split,
    isLast: true,
  );
  writer.alignToByte();
  return Uint8List.fromList(writer.toBytes());
}

/// Reads the three `NBLTYPES` varints of the first compressed meta-block.
List<int> _blockTypeCounts(Uint8List stream) {
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

  // Window bits.
  if (readBits(1) == 0) {
    // lgwin 16.
  } else {
    final n1 = readBits(3);
    if (n1 == 0) {
      final n2 = readBits(3);
      if (n2 == 1) throw StateError('large-window stream');
    }
  }
  final isLast = readBits(1) == 1;
  if (isLast) {
    final isEmpty = readBits(1) == 1;
    if (isEmpty) return <int>[0, 0, 0];
  }
  final nibbles = readBits(2) + 4;
  for (var i = 0; i < nibbles * 4; i++) {
    readBits(1);
  }
  if (!isLast) {
    final isUncompressed = readBits(1) == 1;
    if (isUncompressed) return <int>[0, 0, 0];
  }
  return <int>[
    readVarLenUint8() + 1,
    readVarLenUint8() + 1,
    readVarLenUint8() + 1,
  ];
}

// ---------------------------------------------------------------------------
// Data fixtures
// ---------------------------------------------------------------------------

final Uint8List _textAlice = File('test/testdata/alice29.txt')
    .readAsBytesSync();
final Uint8List _textPlrabn12 = File('test/testdata/plrabn12.txt')
    .readAsBytesSync();

enum _DataKind { text, cjkVaried, alternating, random }

Uint8List _data(_DataKind kind, int size, {int seed = 0}) {
  switch (kind) {
    case _DataKind.text:
      return _repeatToSize(_textAlice, size);
    case _DataKind.cjkVaried:
      return _variedCjk(size, seed + 1);
    case _DataKind.alternating:
      return _alternatingTextBinary(size, seed + 2);
    case _DataKind.random:
      final random = Random(0xB07 + seed);
      final out = Uint8List(size);
      for (var i = 0; i < size; i++) {
        out[i] = random.nextInt(256);
      }
      return out;
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

/// Alternating 32 KiB text / 32 KiB pseudo-random stripes.
Uint8List _alternatingTextBinary(int size, int seed) {
  final out = Uint8List(size);
  final random = Random(seed);
  var pos = 0;
  var inText = true;
  var left = 32768;
  while (pos < size) {
    if (left == 0) {
      inText = !inText;
      left = 32768;
    }
    out[pos] = inText
        ? _textAlice[pos % _textAlice.length]
        : random.nextInt(256);
    pos++;
    left--;
  }
  return out;
}
