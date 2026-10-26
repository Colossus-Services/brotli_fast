@TestOn('vm')
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:brotli_fast/src/encoder/encoder.dart';
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

import '../support/brotli_cli.dart';
import '../support/encoder_fixtures.dart';

const int _kKiB = 1024;
const int _kMiB = 1 << 20;

void main() {
  final cliSkip = brotliCliSkipReason();

  group('large-window streams', () {
    test('header is the 14-bit large-window extension', () {
      final input = aliceText(1000);
      for (final windowBits in <int>[25, 26, 30]) {
        final stream = brotliEncode(input, windowBits: windowBits);
        expect(_readLargeWindowHeader(stream), windowBits);
        // Same through the internal options.
        final internal = encode(
          input,
          BrotliEncodeOptions(lgwin: windowBits, largeWindow: true),
        );
        expect(internal, orderedEquals(stream));
      }
      // The same data with a regular window is a regular stream.
      final regular = brotliEncode(input, windowBits: 24);
      expect(_readLargeWindowHeader(regular), isNull);
    });

    test('our decoder decodes them only with allowLargeWindow', () {
      final input = aliceText(200000);
      for (final windowBits in <int>[25, 30]) {
        final stream = brotliEncode(input, windowBits: windowBits);
        expectSameBytes(
          brotliDecode(stream, allowLargeWindow: true),
          input,
          reason: 'windowBits $windowBits',
        );
        expect(
          () => brotliDecode(stream),
          throwsA(isA<BrotliException>()),
          reason: 'windowBits $windowBits must be rejected without the opt-in',
        );
      }
    });

    test(
      'reference CLI decodes q0/q1/q4/q5/q8/q11 at windowBits 25/26/30',
      () async {
        final cases = <String, Uint8List>{
          'text-2m': aliceText(2 * _kMiB),
          'cjk-300k': variedCjk(300 * _kKiB, 3),
          'binary-300k': randomBytes(300 * _kKiB, 5),
        };
        for (final entry in cases.entries) {
          for (final quality in <int>[0, 1, 4, 5, 8, 11]) {
            for (final windowBits in <int>[25, 26, 30]) {
              final stream = brotliEncode(
                entry.value,
                quality: quality,
                windowBits: windowBits,
              );
              expectSameBytes(
                await cliDecompress(stream, largeWindow: true),
                entry.value,
                reason: '${entry.key} q$quality windowBits $windowBits',
              );
            }
          }
        }
      },
      skip: cliSkip,
      timeout: const Timeout(Duration(minutes: 12)),
    );

    test(
      'streaming encoder supports large windows with flushes',
      () async {
        final input = aliceText(500000);
        final encoder = StreamingEncoder(
          const BrotliEncodeOptions(quality: 5, lgwin: 30, largeWindow: true),
        );
        final output = BytesBuilder(copy: false);
        for (var offset = 0; offset < input.length; offset += 7000) {
          final end = min(offset + 7000, input.length);
          encoder.add(Uint8List.sublistView(input, offset, end));
          encoder.flush();
          output.add(encoder.takeOutput());
        }
        encoder.finish();
        output.add(encoder.takeOutput());
        final stream = output.takeBytes();
        expect(encoder.isFinished, isTrue);
        expect(_readLargeWindowHeader(stream), 30);
        expectSameBytes(await cliDecompress(stream, largeWindow: true), input);
        expectSameBytes(brotliDecode(stream, allowLargeWindow: true), input);
      },
      skip: cliSkip,
      timeout: const Timeout(Duration(minutes: 6)),
    );

    test('chunked conversion with windowBits 30 is a large-window stream', () {
      final input = aliceText(300000);
      final chunks = <List<int>>[];
      final sink = const BrotliEncoder(windowBits: 30).startChunkedConversion(
        ChunkedConversionSink.withCallback(chunks.addAll),
      );
      for (var offset = 0; offset < input.length; offset += 50000) {
        sink.add(
          Uint8List.sublistView(
            input,
            offset,
            min(offset + 50000, input.length),
          ),
        );
      }
      sink.close();
      final stream = Uint8List.fromList([for (final c in chunks) ...c]);
      expect(_readLargeWindowHeader(stream), 30);
      expectSameBytes(brotliDecode(stream, allowLargeWindow: true), input);
    });

    test('returns the same bytes as a one-shot encode', () {
      final input = aliceText(150000);
      const options = BrotliEncodeOptions(
        quality: 5,
        lgwin: 26,
        largeWindow: true,
      );
      final encoder = StreamingEncoder(options)
        ..add(input)
        ..finish();
      expect(
        encoder.takeOutput(),
        orderedEquals(brotliEncode(input, quality: 5, windowBits: 26)),
      );
    });

    test('invalid combinations throw', () {
      final input = aliceText(1000);
      expect(
        () => encode(input, const BrotliEncodeOptions(lgwin: 25)),
        throwsA(isA<BrotliException>()),
      );
      expect(
        () => StreamingEncoder(const BrotliEncodeOptions(lgwin: 30)),
        throwsA(isA<BrotliException>()),
      );
      expect(() => brotliEncode(input, windowBits: 31), throwsRangeError);
      // lgwin 22 with the flag still produces a regular (non-large) stream.
      final regular = encode(
        input,
        const BrotliEncodeOptions(lgwin: 22, largeWindow: true),
      );
      expect(_readLargeWindowHeader(regular), isNull);
      expectSameBytes(brotliDecode(regular), input);
    });

    test('deterministic and bounded', () {
      final input = aliceText(120000);
      final first = brotliEncode(input, quality: 8, windowBits: 30);
      expect(
        brotliEncode(input, quality: 8, windowBits: 30),
        orderedEquals(first),
      );
      expect(first.length, lessThanOrEqualTo(maxCompressedSize(input.length)));
    });
  });

  group('ratio versus the reference CLI', () {
    test('report large-window sizes against the reference', () async {
      final input = aliceText(2 * _kMiB);
      final report = StringBuffer('large-window report (ours / reference):\n');
      for (final quality in <int>[5, 11]) {
        final ours = brotliEncode(input, quality: quality, windowBits: 30);
        final reference = await cliCompress(
          input,
          quality: quality,
          windowBits: 30,
        );
        report.writeln(
          '  q$quality windowBits 30 in=${input.length} ours=${ours.length} '
          'ref=${reference.length} '
          'ratio=${(ours.length / reference.length).toStringAsFixed(4)}',
        );
        expect(ours.length / reference.length, lessThan(1.3));
        // The reference large-window stream decodes with our decoder.
        expectSameBytes(
          brotliDecode(reference, allowLargeWindow: true),
          input,
          reason: 'reference q$quality',
        );
      }
      print(report.toString().trimRight());
    }, timeout: const Timeout(Duration(minutes: 10)));
  }, skip: cliSkip);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns the lgwin of a large-window header, or null for a regular stream.
int? _readLargeWindowHeader(Uint8List stream) {
  var bit = 0;
  int readBits(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      value |= ((stream[bit >> 3] >> (bit & 7)) & 1) << i;
      bit++;
    }
    return value;
  }

  if (readBits(1) == 0) return null; // lgwin 16
  final n1 = readBits(3);
  if (n1 != 0) return null; // regular 17..24
  final n2 = readBits(3);
  if (n2 != 1) return null; // reserved / regular 8+n2
  expect(readBits(1), 0, reason: 'reserved bit after the large-window marker');
  return readBits(6);
}
