@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:brotli_fast/src/encoder/encoder.dart';
import 'package:brotli_fast/src/encoder/fast_encoder.dart' show fastParamsFor;
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

import '../support/brotli_cli.dart';
import '../support/encoder_fixtures.dart';

const int _kKiB = 1024;
const int _kMiB = 1 << 20;

void main() {
  final cliSkip = brotliCliSkipReason();

  group('one-shot parity', () {
    test('a single add + finish equals the one-shot encode', () {
      final input = aliceText(70 * _kKiB);
      var compared = 0;
      for (final quality in <int>[0, 1, 2, 5, 8, 11]) {
        for (final lgwin in <int>[10, 16, 22]) {
          final options = BrotliEncodeOptions(quality: quality, lgwin: lgwin);
          final encoder = StreamingEncoder(options)
            ..add(input)
            ..finish();
          final output = encoder.takeOutput();
          expect(encoder.isFinished, isTrue);
          final reason = 'q$quality lgwin $lgwin';
          if (fastParamsFor(input, options) == null) {
            // Same path as the one-shot encoder: byte-identical.
            expect(
              output,
              orderedEquals(encode(input, options)),
              reason: reason,
            );
            compared++;
          } else {
            // One-shot uses the fast tier here; streaming never does.
            expectSameBytes(brotliDecode(output), input, reason: reason);
          }
          expect(
            output.length,
            lessThanOrEqualTo(maxCompressedSize(input.length)),
            reason: reason,
          );
        }
      }
      expect(compared, greaterThanOrEqualTo(14));
    });

    test('empty input + finish is a valid empty stream', () {
      final encoder = StreamingEncoder(const BrotliEncodeOptions())..finish();
      final output = encoder.takeOutput();
      expect(output, isNotEmpty);
      expect(output.length, lessThanOrEqualTo(maxCompressedSize(0)));
      expect(brotliDecode(output), isEmpty);
    });

    test('single byte input', () {
      final input = Uint8List.fromList(<int>[0x41]);
      const options = BrotliEncodeOptions(quality: 6);
      final encoder = StreamingEncoder(options)
        ..add(input)
        ..finish();
      final output = encoder.takeOutput();
      expect(output, orderedEquals(brotliEncode(input, quality: 6)));
      expect(brotliDecode(output), orderedEquals(input));
      // Default options (fast tier one-shot): still a valid stream.
      final fast = StreamingEncoder(const BrotliEncodeOptions())
        ..add(input)
        ..finish();
      expect(brotliDecode(fast.takeOutput()), orderedEquals(input));
    });
  });

  group('flush boundaries', () {
    test('flush makes output available without ending the stream', () {
      final input = aliceText(30000);
      final encoder = StreamingEncoder(const BrotliEncodeOptions(quality: 5));
      encoder.add(Uint8List.sublistView(input, 0, 10000));
      expect(encoder.takeOutput(), isEmpty);
      encoder.flush();
      final firstPart = encoder.takeOutput();
      expect(firstPart, isNotEmpty);
      expect(encoder.isFinished, isFalse);
      // A second flush with no pending data produces nothing.
      encoder.flush();
      expect(encoder.takeOutput(), isEmpty);
      encoder.add(Uint8List.sublistView(input, 10000));
      encoder.finish();
      final rest = encoder.takeOutput();
      expect(rest, isNotEmpty);
      expect(encoder.isFinished, isTrue);
      final whole = <int>[...firstPart, ...rest];
      expectSameBytes(brotliDecode(whole), input);
    });

    test('flush with pending data then continuing keeps one valid stream', () {
      final input = aliceText(200000);
      final encoder = StreamingEncoder(const BrotliEncodeOptions(quality: 5));
      final output = BytesBuilder(copy: false);
      var flushes = 0;
      for (var offset = 0; offset < input.length; offset += 17000) {
        final end = min(offset + 17000, input.length);
        encoder.add(Uint8List.sublistView(input, offset, end));
        if (offset % 34000 == 0) {
          encoder.flush();
          flushes++;
        }
        output.add(encoder.takeOutput());
      }
      encoder.finish();
      output.add(encoder.takeOutput());
      expect(flushes, greaterThan(1));
      expectSameBytes(brotliDecode(output.takeBytes()), input);
    });
  });

  group('numeric round-trip', () {
    test(
      'chunk sizes 1/2/3/7/4096 round-trip through the reference CLI',
      () async {
        final input = aliceText(60000);
        for (final chunkSize in <int>[1, 2, 3, 7, 4096]) {
          for (final quality in <int>[0, 1, 4, 5, 8, 11]) {
            for (final lgwin in <int>[10, 16, 22, 24]) {
              final options = BrotliEncodeOptions(
                quality: quality,
                lgwin: lgwin,
              );
              final output = _buildChunked(input, options, chunkSize);
              expect(
                output.length,
                lessThanOrEqualTo(maxCompressedSize(input.length)),
                reason: 'bound q$quality lgwin $lgwin chunk $chunkSize',
              );
              expectSameBytes(
                await cliDecompress(output),
                input,
                reason: 'q$quality lgwin $lgwin chunk $chunkSize',
              );
            }
          }
        }
      },
      skip: cliSkip,
      timeout: const Timeout(Duration(minutes: 10)),
    );

    test(
      'flushed chunks round-trip (quality 0/1/5/11)',
      () async {
        final input = aliceText(120000);
        for (final quality in <int>[0, 1, 5, 11]) {
          final encoder = StreamingEncoder(
            BrotliEncodeOptions(quality: quality),
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
          expectSameBytes(
            await cliDecompress(stream),
            input,
            reason: 'q$quality flush per chunk',
          );
          expectSameBytes(
            brotliDecode(stream),
            input,
            reason: 'ours q$quality flush per chunk',
          );
        }
      },
      skip: cliSkip,
      timeout: const Timeout(Duration(minutes: 8)),
    );

    test(
      '1 MiB, repetitive and random inputs round-trip',
      () async {
        final cases = <String, Uint8List>{
          'text-1m': aliceText(_kMiB),
          'zeros-1m': Uint8List(_kMiB),
          'random-256k': randomBytes(256 * _kKiB, 7),
        };
        for (final entry in cases.entries) {
          for (final quality in <int>[0, 5, 11]) {
            final output = BytesBuilder(copy: false);
            final encoder = StreamingEncoder(
              BrotliEncodeOptions(quality: quality),
            );
            for (
              var offset = 0;
              offset < entry.value.length;
              offset += 100000
            ) {
              final end = min(offset + 100000, entry.value.length);
              encoder.add(Uint8List.sublistView(entry.value, offset, end));
              if (offset % 200000 == 0) encoder.flush();
              output.add(encoder.takeOutput());
            }
            encoder.finish();
            output.add(encoder.takeOutput());
            final bytes = output.takeBytes();
            expect(
              bytes.length,
              lessThanOrEqualTo(maxCompressedSize(entry.value.length)),
              reason: '${entry.key} q$quality bound',
            );
            expectSameBytes(
              await cliDecompress(bytes),
              entry.value,
              reason: '${entry.key} q$quality',
            );
          }
        }
      },
      skip: cliSkip,
      timeout: const Timeout(Duration(minutes: 12)),
    );
  });

  group('API behaviour', () {
    test('deterministic across encoder instances', () {
      final input = aliceText(80000);
      List<int> run() {
        final encoder = StreamingEncoder(const BrotliEncodeOptions(quality: 8));
        final output = BytesBuilder(copy: false);
        for (var offset = 0; offset < input.length; offset += 4096) {
          final end = min(offset + 4096, input.length);
          encoder.add(Uint8List.sublistView(input, offset, end));
          encoder.flush();
          output.add(encoder.takeOutput());
        }
        encoder.finish();
        output.add(encoder.takeOutput());
        return output.takeBytes();
      }

      expect(run(), orderedEquals(run()));
    });

    test('invalid states throw StateError', () {
      final encoder = StreamingEncoder(const BrotliEncodeOptions())..finish();
      expect(() => encoder.add(Uint8List(4)), throwsStateError);
      expect(encoder.flush, throwsStateError);
      expect(encoder.finish, throwsStateError);
      // The empty stream produced by finish() is still available, once.
      expect(encoder.takeOutput(), isNotEmpty);
      expect(encoder.takeOutput(), isEmpty);
    });

    test('takeOutput drains', () {
      final encoder = StreamingEncoder(const BrotliEncodeOptions())
        ..add(Uint8List.fromList(List<int>.generate(50000, (i) => i & 0xFF)))
        ..flush()
        ..finish();
      final output = encoder.takeOutput();
      expect(output, isNotEmpty);
      expect(encoder.takeOutput(), isEmpty);
      expect(brotliDecode(output).length, 50000);
    });

    test('chunked conversion matches the streaming encoder', () async {
      final input = aliceText(300000);
      final chunks = <List<int>>[
        for (var offset = 0; offset < input.length; offset += 30000)
          Uint8List.sublistView(
            input,
            offset,
            min(offset + 30000, input.length),
          ),
      ];
      final viaStream = await Stream<List<int>>.fromIterable(chunks)
          .transform(const BrotliEncoder(quality: 8))
          .fold<BytesBuilder>(BytesBuilder(), (b, chunk) => b..add(chunk));
      final encoder = StreamingEncoder(const BrotliEncodeOptions(quality: 8));
      final direct = BytesBuilder(copy: false);
      for (final chunk in chunks) {
        encoder.add(chunk as Uint8List);
        direct.add(encoder.takeOutput());
      }
      encoder.finish();
      direct.add(encoder.takeOutput());
      final bytes = viaStream.takeBytes();
      expect(bytes, orderedEquals(direct.takeBytes()));
      expectSameBytes(brotliDecode(bytes), input);
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Uint8List _buildChunked(
  Uint8List input,
  BrotliEncodeOptions options,
  int chunkSize,
) {
  final encoder = StreamingEncoder(options);
  final output = BytesBuilder(copy: false);
  for (var offset = 0; offset < input.length; offset += chunkSize) {
    final end = min(offset + chunkSize, input.length);
    encoder.add(Uint8List.sublistView(input, offset, end));
    output.add(encoder.takeOutput());
  }
  encoder.finish();
  output.add(encoder.takeOutput());
  return output.takeBytes();
}
