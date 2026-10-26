/// Encodes through the high-ratio / greedy paths at any quality.
///
/// One-shot `brotliEncode` routes qualities 0..5 to the fast tier; tests of the
/// other paths encode through [StreamingEncoder] instead, whose single
/// `add` + `finish` is byte-identical to a one-shot encode on those paths
/// (except for empty input, which streams as a 2-byte stream instead of the
/// canonical `0x06`).
library;

import 'dart:typed_data';

import 'package:brotli_fast/src/encoder/encoder.dart';
import 'package:brotli_fast/src/options.dart';

Uint8List highRatioEncode(Uint8List input, BrotliEncodeOptions options) {
  final encoder = StreamingEncoder(options)
    ..add(input)
    ..finish();
  return encoder.takeOutput();
}
