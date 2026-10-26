/// One-shot encode/decode functions.
library;

import 'dart:typed_data';

import 'common/errors.dart';
import 'decoder/decoder.dart' as decoder;
import 'dictionary.dart';
import 'encoder/encoder.dart' as encoder;
import 'options.dart';

/// Default compression quality: a good speed/ratio balance.
const int brotliDefaultQuality = 5;

/// Default window size in bits (a 4 MiB window).
const int brotliDefaultWindowBits = 22;

/// Default limit on the decoded size of [brotliDecode] (1 GiB).
const int brotliDefaultMaxOutputSize = 1 << 30;

/// Compresses [data] into a Brotli stream.
///
/// * [quality] is `0..11`: 0..5 favor speed (5 is a good default), 6..11
///   favor ratio and are progressively slower.
/// * [windowBits] is `10..24` (the sliding window is `2^windowBits - 16`
///   bytes). `25..30` produce the non-standard large-window format, which
///   decoders only accept when they opt in (see [brotliDecode]).
/// * [dictionary] lets the stream copy from bytes the decoder also has; the
///   decoder must be given the same dictionary.
///
/// Throws [ArgumentError] for out-of-range arguments.
Uint8List brotliEncode(
  List<int> data, {
  int quality = brotliDefaultQuality,
  int windowBits = brotliDefaultWindowBits,
  BrotliDictionary? dictionary,
}) => encoder.encode(
  _bytes(data),
  encodeOptions(
    quality: quality,
    windowBits: windowBits,
    dictionary: dictionary,
  ),
);

/// Decompresses the complete Brotli stream [data].
///
/// * [maxOutputSize] guards against decompression bombs: a stream that
///   decodes to more bytes throws a [BrotliException] with
///   [BrotliErrorCode.outputLimitExceeded].
/// * [dictionary] must be the dictionary the stream was encoded with, if any.
/// * [sharedDictionary] is a serialized shared dictionary
///   (`draft-vandevenne-shared-brotli-format`, as produced for
///   `brotli --dictionary`), which may replace the built-in static dictionary.
/// * [allowLargeWindow] accepts the non-standard large-window format
///   (`windowBits` 25..30); it is rejected by default.
///
/// Throws [BrotliException] for malformed, truncated or oversized streams.
Uint8List brotliDecode(
  List<int> data, {
  int? maxOutputSize = brotliDefaultMaxOutputSize,
  BrotliDictionary? dictionary,
  Uint8List? sharedDictionary,
  bool allowLargeWindow = false,
}) => decoder.decode(
  _bytes(data),
  maxOutputSize: maxOutputSize,
  allowLargeWindow: allowLargeWindow,
  compoundDictionary: dictionary?.bytes,
  sharedDictionary: sharedDictionary,
);

/// Validated encoder options for the public arguments.
BrotliEncodeOptions encodeOptions({
  required int quality,
  required int windowBits,
  required BrotliDictionary? dictionary,
  int? sizeHint,
}) {
  RangeError.checkValueInInterval(quality, 0, 11, 'quality');
  RangeError.checkValueInInterval(windowBits, 10, 30, 'windowBits');
  return BrotliEncodeOptions(
    quality: quality,
    lgwin: windowBits,
    largeWindow: windowBits > 24,
    dictionary: dictionary,
    sizeHint: sizeHint,
  );
}

Uint8List _bytes(List<int> data) =>
    data is Uint8List ? data : Uint8List.fromList(data);
