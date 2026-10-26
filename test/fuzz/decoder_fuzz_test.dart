/// Deterministic hardening tests for the decoder plus encoder/decoder
/// round-trip properties.
///
/// The fuzz cases are fully seeded and bounded: malformed input may either be
/// rejected with [BrotliException] or (very rarely) decode to a different valid
/// buffer, but it must never surface any other exception type and must respect
/// `maxOutputSize`.
@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:brotli_fast/src/encoder/encoder.dart' show maxCompressedSize;
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

import '../decoder/decoder_helpers.dart';
import '../support/corpus.dart';
import '../support/high_ratio.dart';

/// Output bound for every fuzz input (decompression-bomb guard).
const int _maxFuzzOutput = 1 << 20;

/// Qualities covered by the round-trip properties.
const List<int> _qualities = <int>[0, 1, 4, 5];

Uint8List _pattern(int size, {int seed = 3}) {
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = (i * 31 + seed + (i >> 6)) & 0xFF;
  }
  return bytes;
}

/// Both encoder tiers at [quality]: the public one-shot encoder and the
/// high-ratio / greedy path.
Map<String, Uint8List> _encodings(Uint8List input, int quality, int lgwin) =>
    <String, Uint8List>{
      'brotliEncode': brotliEncode(input, quality: quality, windowBits: lgwin),
      'highRatio': highRatioEncode(
        input,
        BrotliEncodeOptions(quality: quality, lgwin: lgwin),
      ),
    };

/// Runs [input] through the one-shot decoder and asserts that the only possible
/// failure is [BrotliException].
void _expectOnlyBrotliException(Uint8List input, String reason) {
  try {
    final output = brotliDecode(input, maxOutputSize: _maxFuzzOutput);
    expect(
      output.length,
      lessThanOrEqualTo(_maxFuzzOutput),
      reason: '$reason: output bound',
    );
  } on BrotliException {
    // The expected outcome for malformed streams.
  }
}

/// Deterministic mutations of one compressed corpus stream.
Iterable<Uint8List> _mutations(Uint8List original, Random random) sync* {
  if (original.isEmpty) {
    return;
  }
  // Random bit flips.
  for (var i = 0; i < 2; i++) {
    final mutated = Uint8List.fromList(original);
    final index = random.nextInt(mutated.length);
    mutated[index] ^= 1 << random.nextInt(8);
    yield mutated;
  }
  // Byte replacement.
  final replaced = Uint8List.fromList(original);
  replaced[random.nextInt(replaced.length)] = random.nextInt(256);
  yield replaced;
  // Single byte deletion.
  if (original.length > 1) {
    final index = random.nextInt(original.length);
    yield Uint8List.fromList(<int>[
      ...original.sublist(0, index),
      ...original.sublist(index + 1),
    ]);
  }
  // Single byte insertion.
  final insertAt = random.nextInt(original.length + 1);
  yield Uint8List.fromList(<int>[
    ...original.sublist(0, insertAt),
    random.nextInt(256),
    ...original.sublist(insertAt),
  ]);
  // Truncation at a few deterministic fractions.
  for (final divisor in <int>[2, 3, 5]) {
    final cut = original.length ~/ divisor;
    if (cut > 0 && cut < original.length) {
      yield Uint8List.sublistView(original, 0, cut);
    }
  }
  // Trailing garbage (strict one-shot must reject it as unused input).
  yield Uint8List.fromList(<int>[...original, 0xDE, 0xAD, 0xBE, 0xEF]);
}

void main() {
  final corpus = Corpus.load();

  group('fuzz: malformed streams', () {
    test('mutated corpus streams only raise BrotliException', () {
      final random = Random(0xB70B11);
      for (final entry in corpus.entries) {
        final compressed = corpus.compressedBytes(entry);
        for (final mutated in _mutations(compressed, random)) {
          _expectOnlyBrotliException(mutated, 'mutation of ${entry.name}');
        }
      }
    });

    test('mutated streams also fail cleanly when streamed', () {
      final random = Random(0x57EA);
      for (final name in <String>['monkey', 'mapsdatazrh', 'quickfox']) {
        final entry = corpus.entries.firstWhere((e) => e.name == name);
        final compressed = corpus.compressedBytes(entry);
        for (final mutated in _mutations(compressed, random)) {
          try {
            streamDecode(
              mutated,
              inputChunk: 7,
              outputChunk: 64,
              maxOutputSize: _maxFuzzOutput,
            );
          } on BrotliException {
            // Expected.
          }
        }
      }
    });

    test('truncated corpus streams raise BrotliException', () {
      for (final entry in corpus.entries) {
        final compressed = corpus.compressedBytes(entry);
        final cuts = <int>{0, 1, compressed.length ~/ 2, compressed.length - 1};
        for (final cut in cuts) {
          if (cut < 0 || cut >= compressed.length) {
            continue;
          }
          expect(
            () => brotliDecode(Uint8List.sublistView(compressed, 0, cut)),
            throwsBrotli(),
            reason: 'truncation of ${entry.name} at $cut',
          );
        }
      }
    });

    test('random byte streams only raise BrotliException', () {
      final random = Random(0xDEC0DE);
      for (var i = 0; i < 250; i++) {
        final length = 1 + random.nextInt(96);
        final bytes = Uint8List.fromList(
          List<int>.generate(length, (_) => random.nextInt(256)),
        );
        _expectOnlyBrotliException(bytes, 'random stream $i');
      }
    });

    test('empty input is reported as truncated', () {
      expect(
        () => brotliDecode(Uint8List(0)),
        throwsBrotli(BrotliErrorCode.truncatedInput),
      );
    });

    test('strict one-shot rejects trailing bytes', () {
      final compressed = brotliEncode(_pattern(64));
      expect(
        () => brotliDecode(Uint8List.fromList(<int>[...compressed, 0x00])),
        throwsBrotli(BrotliErrorCode.unusedBytesAfterEnd),
      );
    });

    test('maxOutputSize is enforced', () {
      final compressed = brotliEncode(_pattern(2048));
      expect(
        () => brotliDecode(compressed, maxOutputSize: 1024),
        throwsBrotli(BrotliErrorCode.outputLimitExceeded),
      );
    });
  });

  group('property: encoder/decoder round-trip', () {
    test('all sizes x qualities x lgwin values', () {
      const sizes = <int>[0, 1, 2, 3, 7, 64, 1023, 4096, 65537];
      const lgwins = <int>[10, 16, 22, 24];
      for (final size in sizes) {
        final input = _pattern(size, seed: size + 11);
        for (final quality in _qualities) {
          for (final lgwin in lgwins) {
            final encodings = _encodings(input, quality, lgwin);
            for (final MapEntry(key: tier, value: compressed)
                in encodings.entries) {
              final label = '$tier size=$size q=$quality lgwin=$lgwin';
              expect(
                compressed.length,
                lessThanOrEqualTo(maxCompressedSize(input.length)),
                reason: '$label bound',
              );
              expectBytes(
                brotliDecode(compressed, maxOutputSize: size + 64),
                input,
                label,
              );
            }
          }
        }
      }
    });

    test('incompressible random data round-trips', () {
      final random = Random(0x51EED);
      for (final size in <int>[0, 1, 31, 1024, 4096]) {
        final input = Uint8List.fromList(
          List<int>.generate(size, (_) => random.nextInt(256)),
        );
        for (final quality in _qualities) {
          for (final MapEntry(key: tier, value: compressed) in _encodings(
            input,
            quality,
            22,
          ).entries) {
            expectBytes(
              brotliDecode(compressed),
              input,
              '$tier random size=$size q=$quality',
            );
          }
        }
      }
    });

    test('repetitive data round-trips', () {
      final input = Uint8List(1 << 15);
      for (var i = 0; i < input.length; i++) {
        input[i] = (i >> 7) & 0x07;
      }
      for (final quality in _qualities) {
        for (final MapEntry(key: tier, value: compressed) in _encodings(
          input,
          quality,
          22,
        ).entries) {
          expect(compressed.length, lessThan(input.length));
          expectBytes(
            brotliDecode(compressed),
            input,
            '$tier repetitive q=$quality',
          );
        }
      }
    });

    test('encoder output is deterministic', () {
      final input = _pattern(4096);
      for (final quality in _qualities) {
        final first = _encodings(input, quality, 22);
        final second = _encodings(input, quality, 22);
        for (final tier in first.keys) {
          expectBytes(
            second[tier]!,
            first[tier]!,
            '$tier determinism q=$quality',
          );
        }
      }
    });

    test('streaming decode matches one-shot for several input chunks', () {
      final input = _pattern(8192);
      for (final MapEntry(key: tier, value: compressed) in _encodings(
        input,
        5,
        22,
      ).entries) {
        for (final chunk in <int>[1, 2, 3, 7, 4096]) {
          expectBytes(
            streamDecode(compressed, inputChunk: chunk, outputChunk: 13),
            input,
            '$tier streaming chunk=$chunk',
          );
        }
      }
    });
  });
}
