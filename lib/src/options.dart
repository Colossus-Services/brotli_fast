/// Internal option and status types shared by the encoder and decoder.
library;

import 'dictionary.dart';

/// Progress reported by the resumable decoder core.
enum BrotliStatus {
  /// The decoder needs more input; all provided input has been consumed.
  needMoreInput,

  /// The output buffer is full; call again with more space.
  needMoreOutput,

  /// The stream ended cleanly.
  done,
}

/// Validated encoder parameters.
///
/// [quality] is `0..11`; [lgwin] is `10..24` for RFC 7932 streams and `25..30`
/// when [largeWindow] is set (non-RFC large-window extension).
final class BrotliEncodeOptions {
  const BrotliEncodeOptions({
    this.quality = 5,
    this.lgwin = 22,
    this.sizeHint,
    this.largeWindow = false,
    this.dictionary,
  });

  final int quality;
  final int lgwin;

  /// Expected total input size; enables the large-input context heuristics
  /// before the whole input has been seen (streaming).
  final int? sizeHint;

  /// Non-RFC large-window streams (lgwin 25..30).
  final bool largeWindow;

  /// Raw LZ77 dictionary the stream may copy from.
  final BrotliDictionary? dictionary;
}
