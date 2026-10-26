/// Caller-provided raw (LZ77) dictionary.
library;

import 'dart:typed_data';

import 'encoder/compound_dictionary.dart';

/// Largest accepted dictionary (distances must stay inside the decoder's
/// `maxAllowedDistance` range).
const int maxDictionarySize = 1 << 30;

/// A raw dictionary shared by the encoder and the decoder.
///
/// This is the "compound dictionary" extension implemented by
/// `brotli --dictionary` and the Rust `brotli` crates: the dictionary bytes act
/// as history immediately preceding the stream, so the encoder can copy spans
/// of the input that also occur in the dictionary. It pays off for many small
/// payloads that share boilerplate (JSON with a common schema, HTML templates).
///
/// The decoder must be given a dictionary with exactly the same bytes. Brotli
/// streams carry no dictionary checksum: a different dictionary of the same
/// length decodes to different bytes, a different length normally fails.
///
/// The match index is built on the first encode and reused afterwards, so keep
/// one instance for repeated encodes. Instances are immutable and can be shared.
final class BrotliDictionary {
  /// Creates a dictionary from [bytes].
  ///
  /// A [Uint8List] is used by reference (do not modify it afterwards); any
  /// other list is copied. Throws [ArgumentError] if it is larger than
  /// [maxDictionarySize].
  factory BrotliDictionary(List<int> bytes) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (data.length > maxDictionarySize) {
      throw ArgumentError.value(
        data.length,
        'bytes',
        'dictionary exceeds $maxDictionarySize bytes',
      );
    }
    return BrotliDictionary._(data);
  }

  BrotliDictionary._(this.bytes);

  /// The dictionary bytes.
  final Uint8List bytes;

  /// Number of dictionary bytes.
  int get length => bytes.length;

  late final Map<int, List<int>> _index = CompoundDictionaryMatcher.buildIndex(
    bytes,
  );
}

/// A matcher over [dictionary] that reuses its cached index.
CompoundDictionaryMatcher dictionaryMatcher(BrotliDictionary dictionary) =>
    CompoundDictionaryMatcher(dictionary.bytes, index: dictionary._index);
