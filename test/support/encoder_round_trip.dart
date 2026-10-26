/// Round-trip checks for encoder tests: every stream is decoded by our own
/// decoder and by the reference `brotli` CLI (see `brotli_cli.dart`).
///
/// Tests using these helpers need the CLI, so give their group
/// `skip: brotliCliSkipReason()`.
library;

import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:brotli_fast/src/encoder/encoder.dart' show maxCompressedSize;
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

import 'brotli_cli.dart';
import 'expect_bytes.dart';
import 'high_ratio.dart';

export 'expect_bytes.dart';

/// Decodes [compressed] with our decoder and the reference CLI and expects
/// [input] back from both. [largeWindow] accepts large-window streams.
Future<void> expectDecodes(
  Uint8List compressed,
  Uint8List input, {
  required String reason,
  bool largeWindow = false,
}) async {
  expectSameBytes(
    brotliDecode(
      compressed,
      allowLargeWindow: largeWindow,
      maxOutputSize: null,
    ),
    input,
    reason: '$reason (brotli_fast decoder)',
  );
  expectSameBytes(
    await cliDecompress(compressed, largeWindow: largeWindow),
    input,
    reason: '$reason (reference CLI)',
  );
}

/// [expectDecodes] plus the `maxCompressedSize` output bound.
Future<void> expectRoundTrip(
  Uint8List input,
  Uint8List compressed, {
  required String reason,
}) async {
  expect(
    compressed.length,
    lessThanOrEqualTo(maxCompressedSize(input.length)),
    reason: '$reason: output exceeds maxCompressedSize',
  );
  await expectDecodes(compressed, input, reason: reason);
}

/// The distinct encoder paths that serve [quality] / [lgwin]: the routed
/// one-shot `brotliEncode` and, when it can differ (qualities 0..5 take the
/// fast tier at the default window), the high-ratio path.
Map<String, Uint8List> encodePaths(
  Uint8List input, {
  required int quality,
  int lgwin = brotliDefaultWindowBits,
}) {
  final oneShot = brotliEncode(input, quality: quality, windowBits: lgwin);
  if (quality > 5 || lgwin != brotliDefaultWindowBits) {
    return <String, Uint8List>{'one-shot': oneShot};
  }
  return <String, Uint8List>{
    'one-shot': oneShot,
    'high-ratio': highRatioEncode(
      input,
      BrotliEncodeOptions(quality: quality, lgwin: lgwin),
    ),
  };
}

/// Encodes [input] through every path of [encodePaths] and round-trips each
/// stream.
Future<void> expectEncodeRoundTrip(
  Uint8List input, {
  required int quality,
  int lgwin = brotliDefaultWindowBits,
  required String reason,
}) async {
  final paths = encodePaths(input, quality: quality, lgwin: lgwin);
  for (final entry in paths.entries) {
    await expectRoundTrip(input, entry.value, reason: '$reason ${entry.key}');
  }
}
