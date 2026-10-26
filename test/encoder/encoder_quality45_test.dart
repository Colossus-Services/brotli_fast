@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_fast/src/common/bit_utils.dart' show mul32;
import 'package:brotli_fast/src/encoder/backward_references.dart';
import 'package:brotli_fast/src/encoder/command.dart';
import 'package:brotli_fast/src/encoder/encoder.dart';
import 'package:brotli_fast/src/encoder/match_finder.dart';
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

import '../support/brotli_cli.dart';
import '../support/encoder_round_trip.dart';
import '../support/high_ratio.dart';

const int _kKiB = 1024;
const int _kMiB = 1 << 20;

void main() {
  group('backward reference scoring', () {
    test('score is 135 per literal byte minus 30 per distance bit', () {
      expect(kLiteralByteScore, 135);
      expect(kDistanceBitPenalty, 30);
      expect(kScoreBase, 30 * 8 * 8);
      expect(kMinScore, kScoreBase + 100);
      // Distance 1 has log2 == 0, so no penalty at all.
      expect(backwardReferenceScore(4, 1), kScoreBase + 540);
      expect(backwardReferenceScore(4, 4), kScoreBase + 540 - 60);
      expect(backwardReferenceScore(4, 1 << 20), kScoreBase + 540 - 600);
      expect(backwardReferenceScore(8, 1 << 24), kScoreBase + 1080 - 720);
    });

    test('longer copies always score higher at the same distance', () {
      for (final distance in <int>[1, 2, 3, 4, 17, 1000, 1 << 20, 1 << 23]) {
        var previous = backwardReferenceScore(2, distance);
        for (var len = 3; len <= 300; len += 7) {
          final score = backwardReferenceScore(len, distance);
          expect(score, greaterThan(previous));
          previous = score;
        }
      }
    });

    test('closer copies score higher at the same length', () {
      var previous = backwardReferenceScore(8, 1);
      // Distances chosen so that log2Floor(distance) strictly increases.
      for (final distance in <int>[3, 5, 9, 17, 33, 1000, 65536, 1 << 24]) {
        final score = backwardReferenceScore(8, distance);
        expect(score, lessThan(previous));
        previous = score;
      }
      // Distances in the same power-of-two bucket score identically.
      expect(backwardReferenceScore(8, 2), backwardReferenceScore(8, 3));
    });

    test('short far copies fall below the acceptance threshold', () {
      // "Don't accept a short copy from far away": a copy must earn back the
      // bits its distance costs.
      expect(backwardReferenceScore(4, 1 << 24), lessThan(kMinScore));
      expect(backwardReferenceScore(6, 1 << 24), lessThan(kMinScore));
      expect(backwardReferenceScore(7, 1 << 24), greaterThan(kMinScore));
      expect(backwardReferenceScore(4, 1), greaterThan(kMinScore));
    });

    test('last-distance scores and penalties follow the reference tables', () {
      expect(backwardReferenceScoreUsingLastDistance(4), kScoreBase + 540 + 15);
      // The C constant is `39 + ((0x1CA10 >> (code & 0xE)) & 0xE)`, so odd
      // codes reuse the penalty of the even code below them.
      const expected = <int>[39, 39, 43, 43, 39, 39, 47, 47];
      for (var i = 0; i < expected.length; i++) {
        expect(
          backwardReferencePenaltyUsingLastDistance(i),
          expected[i],
          reason: 'short code $i',
        );
      }
      for (var i = 0; i < 16; i++) {
        expect(
          backwardReferencePenaltyUsingLastDistance(i),
          inInclusiveRange(39, 53),
          reason: 'short code $i',
        );
      }
      // Reusing the most recent distance is never more expensive than a
      // derived short code.
      for (var i = 1; i < 16; i++) {
        expect(
          backwardReferencePenaltyUsingLastDistance(i),
          greaterThanOrEqualTo(backwardReferencePenaltyUsingLastDistance(0)),
        );
      }
    });

    test('prepareDistanceCache derives the +-1..3 search entries', () {
      final cache = createSearchDistanceCache();
      expect(cache, hasLength(16));
      expect(cache.sublist(0, 4), orderedEquals(<int>[4, 11, 15, 16]));
      cache[0] = 100;
      cache[1] = 200;
      prepareDistanceCache(cache, 10);
      expect(
        cache.sublist(0, 10),
        orderedEquals(<int>[100, 200, 15, 16, 99, 101, 98, 102, 97, 103]),
      );
      prepareDistanceCache(cache, 16);
      expect(
        cache.sublist(4, 16),
        orderedEquals(<int>[
          99, 101, 98, 102, 97, 103, 199, 201, 198, 202, 197, 203, //
        ]),
      );
      // With only four entries checked, the derived slots stay untouched.
      cache[0] = 5;
      prepareDistanceCache(cache, 4);
      expect(cache[4], 99);
    });
  });

  group('HashChainMatcher', () {
    test('quality 4/5 parameters match the reference hasher table', () {
      final q4 = chainParamsForQuality(4);
      expect(q4.bucketBits, 14);
      expect(q4.blockBits, 3);
      expect(q4.numLastDistances, 4);
      final q5 = chainParamsForQuality(5);
      expect(q5.bucketBits, 14);
      expect(q5.blockBits, 4);
      expect(q5.numLastDistances, 4);
      // The ladder is documented in `chainParamsForQuality`: qualities 2..4
      // share the 8-candidate tier, 5/6 widen the chain, and 7/8/9 are the
      // block-splitting tiers.
      expect(chainParamsForQuality(2).blockBits, 3);
      expect(chainParamsForQuality(3).blockBits, 3);
      expect(chainParamsForQuality(6).blockBits, 5);
      expect(chainParamsForQuality(7).numLastDistances, 10);
      expect(chainParamsForQuality(8).blockBits, 7);
      expect(chainParamsForQuality(9).numLastDistances, 16);
      expect(chainParamsForQuality(11).blockBits, 8);
      expect(kChainBlockSize, 1 << 17);
    });

    test('hashAt stays inside the bucket range', () {
      final input = _data(_DataKind.text, 4096);
      for (final bits in <int>[8, 10, 14, 15]) {
        final matcher = HashChainMatcher(
          bucketBits: bits,
          blockBits: 3,
          numLastDistances: 4,
        );
        for (var pos = 0; pos + 4 <= input.length; pos++) {
          expect(
            matcher.hashAt(input, pos),
            inInclusiveRange(0, (1 << bits) - 1),
          );
        }
      }
    });

    test('the candidate ring keeps the newest blockSize positions', () {
      final data = Uint8List(256);
      // Six positions whose first four bytes are identical => same bucket.
      final positions = <int>[8, 24, 40, 56, 72, 88];
      for (final pos in positions) {
        data[pos] = 0x41; // 'A'
        data[pos + 1] = 0x42; // 'B'
        data[pos + 2] = 0x43; // 'C'
        data[pos + 3] = 0x44; // 'D'
      }
      final matcher = HashChainMatcher(
        bucketBits: 10,
        blockBits: 2, // 4 candidates per bucket
        numLastDistances: 4,
      );
      final key = matcher.hashAt(data, positions.first);
      for (final pos in positions) {
        expect(matcher.hashAt(data, pos), key);
        matcher.store(data, pos);
      }
      expect(matcher.counts[key], 6);
      final base = key << matcher.blockBits;
      // Insertions 0..3 fill the four slots; 4 and 5 wrap around and replace
      // the two oldest entries.
      expect(
        <int>[
          matcher.buckets[base],
          matcher.buckets[base + 1],
          matcher.buckets[base + 2],
          matcher.buckets[base + 3],
        ],
        orderedEquals(<int>[
          positions[4],
          positions[5],
          positions[2],
          positions[3],
        ]),
      );
    });

    test(
      'a scored search prefers a close copy over a slightly longer far one',
      () {
        // Both candidates share the 4-byte prefix "QWER":
        //   * position 0     - a 6-byte match, 2^20 + 64 bytes away
        //   * position t - 4 - a 4-byte match, 4 bytes away
        // The close match scores 2400, the far one 1920 + 810 - 600 = 2130.
        final fixture = _MatcherFixture(farLength: 6);
        final result = fixture.search(numDistances: 4);
        expect(result.len, 4);
        expect(result.distance, 4);
        expect(result.score, 2400);
      },
    );

    test('a clearly longer copy still wins from far away', () {
      // The far candidate matches 9 bytes: 1920 + 1215 - 600 = 2535 > 2400.
      final fixture = _MatcherFixture(farLength: 9);
      final result = fixture.search(numDistances: 4);
      expect(result.len, 9);
      expect(result.distance, fixture.target);
      expect(result.score, 2535);
    });

    test('maxLength caps the copy', () {
      final fixture = _MatcherFixture(farLength: 9, storeClose: false);
      final result = fixture.search(numDistances: 4, maxLength: 7);
      expect(result.len, 7);
      expect(result.distance, fixture.target);
    });

    test('candidates beyond maxBackward are ignored', () {
      final fixture = _MatcherFixture(farLength: 9, storeClose: false);
      final rejected = fixture.search(
        numDistances: 4,
        maxBackward: fixture.target - 1,
      );
      expect(rejected.len, 0);
      expect(rejected.score, kMinScore);
      // One byte more of window and the same candidate is accepted.
      final accepted = fixture.search(numDistances: 4);
      expect(accepted.len, 9);
    });

    test('the last-distance cache is tried before the chain', () {
      // A 6-byte match at distance 775, which only exists because entry 6 of
      // the cache (`cache[0] - 2`) is derived by prepareDistanceCache.
      final data = Uint8List((1 << 12) + 64);
      _fillPseudoRandom(data, 7);
      const target = 1 << 12;
      const distance = 775;
      data[target - distance + 0] = 0x10;
      data[target - distance + 1] = 0x20;
      data[target - distance + 2] = 0x30;
      data[target - distance + 3] = 0x40;
      data[target - distance + 4] = 0x50;
      data[target - distance + 5] = 0x60;
      for (var i = 0; i < 6; i++) {
        data[target + i] = data[target - distance + i];
      }
      data[target - distance + 6] = 0x01;
      data[target + 6] = 0x02;

      final matcher = HashChainMatcher(
        bucketBits: 14,
        blockBits: 3,
        numLastDistances: 10,
      );
      final cache = createSearchDistanceCache();
      cache[0] = 777; // no actual match at 777
      cache[1] = 778;
      prepareDistanceCache(cache, 10);
      expect(cache[4], 776);
      expect(cache[6], 775);
      final result = HasherSearchResult()..reset(kMinScore);
      matcher.findLongestMatch(
        data,
        cache,
        10,
        target,
        data.length - target,
        target,
        result,
      );
      expect(result.distance, 775);
      expect(result.len, 6);
      expect(
        result.score,
        kScoreBase + 810 + 15 - backwardReferencePenaltyUsingLastDistance(6),
      );
    });
  });

  group('lazy matching', () {
    test('a match starting one byte later is taken when it is much better', () {
      // A greedy parse would take the 4-byte "Xbcd" match at `_lazyTarget`;
      // the 9-byte "bcdefghij" match at `_lazyTarget + 1` scores ~585 more, so
      // one literal must be emitted first and the copy must start at +1.
      final data = _lazyFixture();
      final commands = CommandBuffer(64);
      final matcher = HashChainMatcher(
        bucketBits: 14,
        blockBits: 3,
        numLastDistances: 4,
      );
      final cache = createSearchDistanceCache();
      createBackwardReferences(
        data,
        0,
        data.length,
        matcher,
        commands,
        cache,
        1 << 22,
        extensiveSearch: true,
      );
      var position = 0;
      var found = false;
      for (var i = 0; i < commands.count; i++) {
        final insert = commands.insertLen[i];
        final copy = commands.copyLen[i];
        position += insert;
        if (position == _lazyTarget + 1) {
          found = true;
          expect(copy, 9, reason: 'the long match must start at target + 1');
        }
        expect(
          position,
          isNot(_lazyTarget),
          reason: 'a greedy parse would copy at target',
        );
        position += copy;
      }
      expect(found, isTrue);
      expect(position, data.length);
    });

    test('degenerate blocks become a single insert-only command', () {
      final data = Uint8List(8);
      final commands = CommandBuffer(4);
      final matcher = HashChainMatcher(
        bucketBits: 10,
        blockBits: 2,
        numLastDistances: 4,
      );
      final cache = createSearchDistanceCache();
      createBackwardReferences(
        data,
        0,
        data.length,
        matcher,
        commands,
        cache,
        1 << 22,
        extensiveSearch: true,
      );
      expect(commands.count, 1);
      expect(commands.insertLen[0], 8);
      expect(commands.copyLen[0], 0);
    });
  });

  group('quality 4/5 reference round-trip', () {
    for (final quality in <int>[4, 5]) {
      test('quality $quality: boundary sizes up to 128 KiB', () async {
        const sizes = <int>[
          0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, //
          65, 255, 256, 257, 1023, 1024, 1025, 4095, 4096, 65535, 65536,
          65537, 131071, 131072, 131073,
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
          for (final size in <int>[
            _kMiB - 1,
            _kMiB,
            _kMiB + 1,
            2 * _kMiB,
            2 * _kMiB + 3,
          ]) {
            await expectEncodeRoundTrip(
              _data(kind, size),
              quality: quality,
              reason: 'q$quality ${kind.name} $size',
            );
          }
        }
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('quality $quality: every window size round-trips', () async {
        // Long-range repeats: distances beyond the window must never be used,
        // otherwise the reference decoder rejects the stream.
        final input = _copyFromHistory(70000, quality);
        for (var lgwin = 10; lgwin <= 24; lgwin++) {
          await expectEncodeRoundTrip(
            input,
            quality: quality,
            lgwin: lgwin,
            reason: 'q$quality lgwin $lgwin',
          );
        }
      });

      test(
        'quality $quality: mixed compressible/incompressible blocks',
        () async {
          // The random middle block is stored uncompressed; the distance cache
          // must be rolled back so the following block still decodes.
          final mixed = Uint8List.fromList(<int>[
            ..._data(_DataKind.text, 128 * _kKiB),
            ..._data(_DataKind.random, 128 * _kKiB),
            ..._data(_DataKind.text, 128 * _kKiB),
            ..._data(_DataKind.zeros, 96 * _kKiB),
          ]);
          await expectEncodeRoundTrip(
            mixed,
            quality: quality,
            reason: 'mixed blocks',
          );
        },
      );

      test('quality $quality: adversarial payloads round-trip', () async {
        final cases = <String, Uint8List>{
          'small alphabet': _smallAlphabet(50000, 4, 1),
          'small alphabet 16': _smallAlphabet(200000, 16, 2),
          'word soup': _wordSoup(120000, 3),
          'long literal run': _longLiteralRun(),
          'copy-from-history': _copyFromHistory(200000, 1),
          'copy-from-history wide': _copyFromHistory(
            180000,
            2,
            maxDistance: 120000,
          ),
          'rle runs': _rleRuns(150000, 4),
          'block boundary text': _data(_DataKind.text, 2 * 65536 + 333),
          'cjk runs': _data(_DataKind.cjk, 200000),
        };
        for (final entry in cases.entries) {
          await expectEncodeRoundTrip(
            entry.value,
            quality: quality,
            reason: 'q$quality ${entry.key}',
          );
        }
      });

      test('quality $quality: deterministic output', () {
        final input = _data(_DataKind.text, 100000);
        final first = encodePaths(input, quality: quality);
        final second = encodePaths(input, quality: quality);
        for (final key in first.keys) {
          expect(second[key], orderedEquals(first[key]!), reason: key);
        }
        final other = encodePaths(input, quality: quality, lgwin: 20);
        for (final stream in first.values) {
          expect(other['one-shot'], isNot(orderedEquals(stream)));
        }
        expect(
          encodePaths(input, quality: quality, lgwin: 20)['one-shot'],
          orderedEquals(other['one-shot']!),
        );
        if (quality == 5) {
          // Quality 5 must not fall back to quality 4's parameters.
          expect(
            first['high-ratio'],
            isNot(orderedEquals(_highRatio(input, 4))),
          );
        }
      });
    }
  }, skip: brotliCliSkipReason());

  group('quality 4/5 framing', () {
    test('the window header records lgwin', () {
      final input = _data(_DataKind.text, 4096);
      for (var lgwin = 10; lgwin <= 24; lgwin++) {
        for (final quality in <int>[4, 5]) {
          final paths = encodePaths(input, quality: quality, lgwin: lgwin);
          for (final entry in paths.entries) {
            final header = _StreamHeader.parse(entry.value);
            expect(
              header.lgwin,
              lgwin,
              reason: 'q$quality lgwin $lgwin ${entry.key}',
            );
          }
        }
      }
    });

    test(
      'compressible blocks are compressed, random blocks are stored raw',
      () {
        final textPaths = encodePaths(_data(_DataKind.text, 4096), quality: 5);
        for (final entry in textPaths.entries) {
          final text = _StreamHeader.parse(entry.value);
          expect(text.isLast, isFalse, reason: entry.key);
          expect(
            text.isUncompressed,
            isFalse,
            reason: '${entry.key}: text must be compressed',
          );
        }

        final randomPaths = encodePaths(
          _data(_DataKind.random, 4096),
          quality: 5,
        );
        for (final entry in randomPaths.entries) {
          final random = _StreamHeader.parse(entry.value);
          expect(random.isLast, isFalse, reason: entry.key);
          expect(
            random.isUncompressed,
            isTrue,
            reason:
                '${entry.key}: incompressible data must fall back to an '
                'uncompressed block',
          );
        }
      },
    );
  });

  group('quality 4/5 size behaviour', () {
    test('output never exceeds maxCompressedSize', () {
      for (final quality in <int>[4, 5]) {
        for (final kind in _DataKind.values) {
          for (final size in <int>[1, 2, 17, 1000, 65536, _kMiB]) {
            final input = _data(kind, size);
            for (final entry in encodePaths(input, quality: quality).entries) {
              expect(
                entry.value.length,
                lessThanOrEqualTo(maxCompressedSize(input.length)),
                reason: 'q$quality ${kind.name} $size ${entry.key}',
              );
            }
          }
        }
      }
    });

    test('incompressible input stays within a few bytes of the input', () {
      for (final quality in <int>[4, 5]) {
        for (final size in <int>[1, 1000, 65536, 262144]) {
          final input = _data(_DataKind.random, size);
          for (final entry in encodePaths(input, quality: quality).entries) {
            expect(
              entry.value.length,
              lessThanOrEqualTo(size + 4 * (size ~/ 16384) + 8),
              reason: 'q$quality $size ${entry.key}',
            );
          }
        }
      }
    });

    test('compressible input gets much smaller', () {
      for (final quality in <int>[4, 5]) {
        final cases = <String, (Uint8List, int)>{
          'zeros': (_data(_DataKind.zeros, _kMiB), 1000),
          'repetitive': (_data(_DataKind.repetitive, 256 * _kKiB), 4096),
          'text': (_data(_DataKind.text, 256 * _kKiB), 256 * _kKiB ~/ 2),
        };
        for (final entry in cases.entries) {
          final (input, bound) = entry.value;
          for (final path in encodePaths(input, quality: quality).entries) {
            expect(
              path.value.length,
              lessThan(bound),
              reason: 'q$quality ${entry.key} ${path.key}',
            );
          }
        }
      }
    });

    test(
      'quality 4/5 beat quality 1 on text and quality 5 beats quality 4',
      () {
        final sources = <String, Uint8List>{
          'alice29.txt': _textAlice,
          'asyoulik.txt': _textAsyoulik,
          'lcet10.txt': _textLcet10,
          'plrabn12.txt': _textPlrabn12,
          'text-256k': _data(_DataKind.text, 256 * _kKiB),
          'text-1m': _data(_DataKind.text, _kMiB),
        };
        for (final entry in sources.entries) {
          final q1 = _highRatio(entry.value, 1).length;
          final q4 = _highRatio(entry.value, 4).length;
          final q5 = _highRatio(entry.value, 5).length;
          // Hash chains + lazy matching must recover the greedy parser's loss
          // with real margin, not just by a byte or two.
          expect(q4, lessThanOrEqualTo((q1 * 99) ~/ 100), reason: entry.key);
          expect(q5, lessThanOrEqualTo((q1 * 99) ~/ 100), reason: entry.key);
          expect(q5, lessThan(q4), reason: entry.key);
          expect(q5, lessThan(entry.value.length));
        }
      },
    );
  });

  group('ratio versus the reference encoder', () {
    test('report size ratios at quality 4 and 5', () async {
      final cases = <String, Uint8List>{
        'alice-152k': _textAlice,
        'plrabn12-482k': _textPlrabn12,
        'text-256k': _data(_DataKind.text, 256 * _kKiB),
        'text-1m': _data(_DataKind.text, _kMiB),
        'text-2m': _data(_DataKind.text, 2 * _kMiB),
        'repetitive-256k': _data(_DataKind.repetitive, 256 * _kKiB),
        'zeros-1m': _data(_DataKind.zeros, _kMiB),
        'random-256k': _data(_DataKind.random, 256 * _kKiB),
        'utf8-cjk-256k': _data(_DataKind.cjk, 256 * _kKiB),
      };
      final report = StringBuffer(
        'ratio report (ours / brotli CLI, quality 4/5):\n',
      );
      for (final quality in <int>[4, 5]) {
        for (final entry in cases.entries) {
          final input = entry.value;
          final reference = await cliCompress(input, quality: quality);
          for (final path in encodePaths(input, quality: quality).entries) {
            final ours = path.value;
            final ratio = ours.length / reference.length;
            final label = 'q$quality ${entry.key} ${path.key}';
            report.writeln(
              '  ${label.padRight(30)} '
              'in=${input.length.toString().padLeft(8)} '
              'ours=${ours.length.toString().padLeft(8)} '
              'ref=${reference.length.toString().padLeft(8)} '
              'ratio=${ratio.toStringAsFixed(4)}',
            );
            if (entry.key == 'random-256k') {
              // Incompressible data: both fall back to ~uncompressed framing.
              expect(ours.length, lessThanOrEqualTo(input.length + 64));
              expect(ratio, lessThan(1.001), reason: label);
            } else if (entry.key.startsWith('zeros') ||
                entry.key.startsWith('repetitive') ||
                entry.key.startsWith('utf8')) {
              // Highly repetitive input: a handful of very long copies. Our
              // per-128-KiB tree sets cost a few bytes more than the
              // reference's block merging, but the absolute size stays tiny.
              expect(ours.length, lessThan(input.length ~/ 100), reason: label);
            } else if (path.key == 'high-ratio') {
              // Chains + lazy matching, no context modeling, no block
              // splitting: within a few percent of the reference. (The
              // one-shot fast tier trades a little ratio for speed; its
              // numbers are reported only.)
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

Uint8List _highRatio(Uint8List input, int quality) =>
    highRatioEncode(input, BrotliEncodeOptions(quality: quality));

// ---------------------------------------------------------------------------
// Matcher / lazy fixtures
// ---------------------------------------------------------------------------

/// Two candidates with the same 4-byte prefix "QWER":
///
/// * position `0` - a [farLength]-byte copy of the target,
/// * position `target - 4` - a 4-byte copy (unless [storeClose] is false).
final class _MatcherFixture {
  _MatcherFixture({required this.farLength, this.storeClose = true}) {
    _fillPseudoRandom(data, 11);
    const prefix = 'QWERTYUIOP';
    // The far candidate.
    for (var i = 0; i < farLength; i++) {
      data[i] = prefix.codeUnitAt(i);
    }
    // The target, and the close candidate whose 4 bytes are the prefix.
    for (var i = 0; i < farLength; i++) {
      data[target + i] = prefix.codeUnitAt(i);
    }
    for (var i = 0; i < 4; i++) {
      data[target - 4 + i] = prefix.codeUnitAt(i);
    }
    // Cut the far match after `farLength` bytes.
    data[farLength] = 0xAA;
    data[target + farLength] = 0xBB;
    // The close match is cut after 4 bytes because data[target] ('Q') differs
    // from data[target + 4] (the 5th prefix byte, 'T').
  }

  final int farLength;
  final bool storeClose;
  final int target = (1 << 20) + 64;
  final Uint8List data = Uint8List((1 << 20) + 128);

  HasherSearchResult search({
    required int numDistances,
    int maxLength = 12,
    int? maxBackward,
  }) {
    final matcher = HashChainMatcher(
      bucketBits: 14,
      blockBits: 3,
      numLastDistances: numDistances,
    );
    // Insertion order matches the input order: the far position is older and
    // is therefore overwritten first by the ring buffer.
    matcher.store(data, 0);
    if (storeClose) matcher.store(data, target - 4);
    // The distance cache must not rescue either candidate.
    final cache = createSearchDistanceCache();
    cache[0] = 777;
    cache[1] = 778;
    cache[2] = 779;
    cache[3] = 780;
    prepareDistanceCache(cache, numDistances);
    final result = HasherSearchResult()..reset(kMinScore);
    matcher.findLongestMatch(
      data,
      cache,
      numDistances,
      target,
      maxLength,
      maxBackward ?? target,
      result,
    );
    return result;
  }
}

/// Lazy-matching fixture: a 4-byte copy at [_lazyTarget] versus a 9-byte copy
/// at [_lazyTarget] + 1.
///
/// Everything sits inside the first [`kLiteralSpreeLength`] bytes so the
/// incompressible-data skip heuristic cannot hide the relevant positions from
/// the hasher.
const int _lazyTarget = 40;

Uint8List _lazyFixture() {
  final data = Uint8List(80);
  _fillPseudoRandom(data, 13);
  // "bcdefghij" at 10 (9 bytes); data[19] cuts it.
  const long = 'bcdefghij';
  for (var i = 0; i < long.length; i++) {
    data[10 + i] = long.codeUnitAt(i);
  }
  data[19] = 0x01;
  // "Xbcd" at 20: a 4-byte match that a greedy parser would take; data[24]
  // cuts it.
  data[20] = 0x58; // 'X'
  data[21] = 0x62; // 'b'
  data[22] = 0x63; // 'c'
  data[23] = 0x64; // 'd'
  data[24] = 0x00;
  // "Xbcdefghij" at the target: the copy at target + 1 matches "bcdefghij"
  // at 10 for 9 bytes, while the copy at target matches "Xbcd" at 20 for 4.
  data[_lazyTarget] = 0x58;
  for (var i = 0; i < 9; i++) {
    data[_lazyTarget + 1 + i] = long.codeUnitAt(i);
  }
  data[_lazyTarget + 10] = 0x02; // cuts the 9-byte match
  return data;
}

/// Minimal LSB-first reader for the *first* meta-block header.
final class _StreamHeader {
  _StreamHeader._({
    required this.lgwin,
    required this.isLast,
    required this.isUncompressed,
  });

  final int lgwin;
  final bool isLast;
  final bool isUncompressed;

  /// Parses window bits plus the first meta-block header.
  static _StreamHeader parse(Uint8List stream) {
    var bitPosition = 0;
    int readBits(int count) {
      var value = 0;
      for (var i = 0; i < count; i++) {
        final byte = bitPosition >> 3;
        final bit = (stream[byte] >> (bitPosition & 7)) & 1;
        value |= bit << i;
        bitPosition++;
      }
      return value;
    }

    // Mirrors `DecodeWindowBits` from the RFC 7932 decoder.
    final int lgwin;
    if (readBits(1) == 0) {
      lgwin = 16;
    } else {
      final n1 = readBits(3);
      if (n1 != 0) {
        lgwin = 17 + n1;
      } else {
        final n2 = readBits(3);
        if (n2 != 0) {
          lgwin = 8 + n2;
        } else {
          lgwin = 17;
        }
      }
    }
    final isLast = readBits(1) == 1;
    if (isLast) {
      return _StreamHeader._(lgwin: lgwin, isLast: true, isUncompressed: false);
    }
    final nibbles = readBits(2) + 4;
    for (var i = 0; i < nibbles * 4; i++) {
      readBits(1);
    }
    return _StreamHeader._(
      lgwin: lgwin,
      isLast: false,
      isUncompressed: readBits(1) == 1,
    );
  }
}

/// Deterministic LCG so fixtures never depend on `dart:math` internals.
void _fillPseudoRandom(Uint8List data, int seed) {
  var state = seed & 0xFFFFFFFF;
  for (var i = 0; i < data.length; i++) {
    state = (mul32(state, 1664525) + 1013904223) & 0xFFFFFFFF;
    data[i] = (state >> 16) & 0xFF;
  }
}

// ---------------------------------------------------------------------------
// Data fixtures
// ---------------------------------------------------------------------------

enum _DataKind { text, repetitive, random, zeros, cjk, all256 }

final Uint8List _textAlice = _readTestData('alice29.txt');
final Uint8List _textAsyoulik = _readTestData('asyoulik.txt');
final Uint8List _textLcet10 = _readTestData('lcet10.txt');
final Uint8List _textPlrabn12 = _readTestData('plrabn12.txt');

Uint8List _readTestData(String name) =>
    File('test/testdata/$name').readAsBytesSync();

Uint8List _data(_DataKind kind, int size, {int seed = 0}) {
  switch (kind) {
    case _DataKind.zeros:
      return Uint8List(size);
    case _DataKind.all256:
      final pattern = Uint8List.fromList(List<int>.generate(256, (i) => i));
      return _repeatToSize(pattern, size);
    case _DataKind.cjk:
      final pattern = utf8.encode('纯 Dart 实现的 Brotli 编码器，体积与速度的平衡 0123456789 ');
      return _repeatToSize(pattern, size);
    case _DataKind.repetitive:
      final pattern = utf8.encode(
        'brotli_fast stage-2a hash chains + lazy matching 0123456789 abcdefghij ',
      );
      return _repeatToSize(pattern, size);
    case _DataKind.text:
      return _repeatToSize(_textAlice, size);
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

Uint8List _smallAlphabet(int size, int alphabetSize, int seed) {
  final random = Random(seed);
  const source =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = source.codeUnitAt(random.nextInt(alphabetSize));
  }
  return out;
}

Uint8List _wordSoup(int size, int seed) {
  final random = Random(seed);
  const words = <String>[
    'brotli', 'dart', 'encoder', 'huffman', 'window', 'lazy', 'match', //
    'dictionary', 'compression', 'stream', 'meta', 'block', 'literal',
  ];
  final builder = BytesBuilder();
  while (builder.length < size) {
    builder.add(utf8.encode(words[random.nextInt(words.length)]));
    builder.addByte(0x20);
  }
  return Uint8List.sublistView(builder.takeBytes(), 0, size);
}

Uint8List _longLiteralRun() {
  final random = Random(99);
  final out = Uint8List(70000);
  for (var i = 0; i < 38000; i++) {
    out[i] = random.nextInt(200) + 40;
  }
  return out;
}

Uint8List _copyFromHistory(int size, int seed, {int maxDistance = 1 << 18}) {
  final random = Random(seed);
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    if (i > 16 && random.nextInt(10) != 0) {
      final limit = i < maxDistance ? i : maxDistance;
      final distance = 1 + random.nextInt(limit);
      out[i] = out[i - distance];
    } else {
      out[i] = random.nextInt(256);
    }
  }
  return out;
}

Uint8List _rleRuns(int size, int seed) {
  final random = Random(seed);
  final out = Uint8List(size);
  var pos = 0;
  while (pos < size) {
    final value = random.nextInt(256);
    final length = 1 + random.nextInt(300);
    final end = pos + length < size ? pos + length : size;
    out.fillRange(pos, end, value);
    pos = end;
  }
  return out;
}
