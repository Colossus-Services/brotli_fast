/// Brotli error codes and exception type.
library;

/// Stable, format-oriented error codes.
///
/// The names describe the RFC 7932 condition, not an internal decoder state.
enum BrotliErrorCode {
  invalidWindowBits,
  invalidMetaBlockLength,
  invalidHuffmanCode,
  invalidContextMap,
  invalidBlockType,
  invalidBlockLength,
  invalidContextMode,
  reservedBit,
  invalidDistance,
  invalidDictionaryWord,
  invalidTransform,
  truncatedInput,
  corruptPadding,
  readAfterEnd,
  unusedBytesAfterEnd,
  unsupportedFeature,
  outputLimitExceeded,
  internalError,
}

/// Exception thrown for malformed streams, unsupported features and limits.
final class BrotliException implements FormatException {
  BrotliException(this.code, this.message, {this.inputOffset});

  final BrotliErrorCode code;
  @override
  final String message;

  /// Absolute input offset when the condition was detected, if known.
  final int? inputOffset;

  @override
  String get source => 'Brotli';

  @override
  int? get offset => inputOffset;

  @override
  String toString() {
    final at = inputOffset == null ? '' : ' at byte $inputOffset';
    return 'BrotliException(${code.name})$at: $message';
  }
}
