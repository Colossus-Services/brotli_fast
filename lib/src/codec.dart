/// `dart:convert` codec and converters, including chunked (stream) conversion.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'brotli.dart';
import 'common/errors.dart';
import 'decoder/decoder.dart';
import 'dictionary.dart';
import 'encoder/encoder.dart';
import 'options.dart';

/// A [BrotliCodec] with the default settings.
///
/// ```dart
/// final packed = brotli.encode(bytes);
/// final bytes = brotli.decode(packed);
/// await file.openRead().transform(brotli.decoder).pipe(sink);
/// ```
const BrotliCodec brotli = BrotliCodec();

/// Brotli as a [Codec] between raw and compressed bytes.
///
/// Its [encoder] and [decoder] also work as stream transformers, emitting
/// output while input arrives. Fuse it with `utf8` to compress strings:
/// `utf8.fuse(brotli)`.
final class BrotliCodec extends Codec<List<int>, List<int>> {
  /// Creates a codec; see [brotliEncode] and [brotliDecode] for the meaning of
  /// the arguments. A [windowBits] above 24 also lets the [decoder] accept the
  /// large-window format.
  const BrotliCodec({
    this.quality = brotliDefaultQuality,
    this.windowBits = brotliDefaultWindowBits,
    this.dictionary,
    this.maxOutputSize = brotliDefaultMaxOutputSize,
  });

  /// Compression quality, `0..11`.
  final int quality;

  /// Window size in bits, `10..30`.
  final int windowBits;

  /// Dictionary used by both directions, if any.
  final BrotliDictionary? dictionary;

  /// Decoded-size limit, or `null` for none.
  final int? maxOutputSize;

  @override
  BrotliEncoder get encoder => BrotliEncoder(
    quality: quality,
    windowBits: windowBits,
    dictionary: dictionary,
  );

  @override
  BrotliDecoder get decoder => BrotliDecoder(
    maxOutputSize: maxOutputSize,
    dictionary: dictionary,
    allowLargeWindow: windowBits > 24,
  );
}

/// Converts raw bytes to a Brotli stream.
///
/// [convert] compresses one buffer (the fastest path). As a stream
/// transformer it emits a compressed block for every 128 KiB of input (64 KiB
/// at quality 0), so output starts flowing before the input ends.
final class BrotliEncoder extends Converter<List<int>, List<int>> {
  /// Creates an encoder; see [brotliEncode] for the arguments.
  const BrotliEncoder({
    this.quality = brotliDefaultQuality,
    this.windowBits = brotliDefaultWindowBits,
    this.dictionary,
  });

  /// Compression quality, `0..11`.
  final int quality;

  /// Window size in bits, `10..30`.
  final int windowBits;

  /// Dictionary the stream may copy from, if any.
  final BrotliDictionary? dictionary;

  @override
  Uint8List convert(List<int> input) => brotliEncode(
    input,
    quality: quality,
    windowBits: windowBits,
    dictionary: dictionary,
  );

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      _EncoderSink(
        StreamingEncoder(
          encodeOptions(
            quality: quality,
            windowBits: windowBits,
            dictionary: dictionary,
          ),
        ),
        sink,
      );
}

/// Converts a Brotli stream back to raw bytes.
///
/// As a stream transformer it emits decompressed output as soon as it is
/// available, without buffering the compressed stream.
final class BrotliDecoder extends Converter<List<int>, List<int>> {
  /// Creates a decoder; see [brotliDecode] for the arguments.
  const BrotliDecoder({
    this.maxOutputSize = brotliDefaultMaxOutputSize,
    this.dictionary,
    this.sharedDictionary,
    this.allowLargeWindow = false,
  });

  /// Decoded-size limit, or `null` for none.
  final int? maxOutputSize;

  /// Dictionary the stream was encoded with, if any.
  final BrotliDictionary? dictionary;

  /// Serialized shared dictionary, if any.
  final Uint8List? sharedDictionary;

  /// Whether the non-standard large-window format is accepted.
  final bool allowLargeWindow;

  @override
  Uint8List convert(List<int> input) => brotliDecode(
    input,
    maxOutputSize: maxOutputSize,
    dictionary: dictionary,
    sharedDictionary: sharedDictionary,
    allowLargeWindow: allowLargeWindow,
  );

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      _DecoderSink(
        StreamingDecoder(
          maxOutputSize: maxOutputSize,
          allowLargeWindow: allowLargeWindow,
          compoundDictionary: dictionary?.bytes,
          sharedDictionary: sharedDictionary,
        ),
        sink,
      );
}

final class _EncoderSink extends ByteConversionSink {
  _EncoderSink(this._encoder, this._sink);

  final StreamingEncoder _encoder;
  final Sink<List<int>> _sink;

  @override
  void add(List<int> chunk) {
    _encoder.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    _emit();
  }

  @override
  void close() {
    if (_encoder.isFinished) return;
    _encoder.finish();
    _emit();
    _sink.close();
  }

  void _emit() {
    final output = _encoder.takeOutput();
    if (output.isNotEmpty) _sink.add(output);
  }
}

final class _DecoderSink extends ByteConversionSink {
  _DecoderSink(this._decoder, this._sink);

  static const int _chunkSize = 64 * 1024;

  final StreamingDecoder _decoder;
  final Sink<List<int>> _sink;
  final Uint8List _buffer = Uint8List(_chunkSize);
  bool _done = false;
  bool _closed = false;

  @override
  void add(List<int> chunk) {
    if (_closed) throw StateError('add after close');
    if (chunk.isEmpty) return;
    // Same rule as one-shot decoding, whatever the chunking: no trailing data.
    if (_done) {
      throw BrotliException(
        BrotliErrorCode.unusedBytesAfterEnd,
        'stream ended with ${chunk.length} unused bytes',
        inputOffset: _decoder.consumedInput,
      );
    }
    _decoder.addInput(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    _pump();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _decoder.closeInput();
    if (!_done) _pump();
    if (!_done) {
      throw BrotliException(
        BrotliErrorCode.truncatedInput,
        'stream ended before the last meta-block',
        inputOffset: _decoder.consumedInput,
      );
    }
    _sink.close();
  }

  /// Decodes until the decoder needs more input or the stream ends.
  void _pump() {
    while (true) {
      final status = _decoder.decode(_buffer);
      final written = _decoder.bytesWritten;
      if (written > 0) _sink.add(_buffer.sublist(0, written));
      switch (status) {
        case BrotliStatus.done:
          _done = true;
          return;
        case BrotliStatus.needMoreInput:
          return;
        case BrotliStatus.needMoreOutput:
          // A full buffer always means progress; anything else is a bug.
          if (written == 0) throw StateError('decoder made no progress');
      }
    }
  }
}
