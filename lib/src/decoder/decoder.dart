/// Decoder entry points: one-shot and streaming.
///
/// The hot path lives in [BrotliDecoderCore] and `decoder_metablock.dart`;
/// this file adapts it to whole buffers and to chunked input.
library;

import 'dart:typed_data';

import '../common/errors.dart';
import '../options.dart';
import 'bit_reader.dart';
import 'decoder_core.dart';
import 'decoder_state.dart' show maxTransformedWordLength;

/// Largest output a one-shot decode allocates for (1 GiB).
const int maxOneShotOutput = 1 << 30;

/// Decodes the complete stream [input].
///
/// Uses a single large output allocation so the whole-metablock fast path can
/// run without a mid-metablock ring flush. If the stream is larger than the
/// initial guess, the allocation doubles and decoding restarts.
///
/// [maxOutputSize] (`null` for no limit beyond [maxOneShotOutput]) guards
/// against decompression bombs.
Uint8List decode(
  Uint8List input, {
  int? maxOutputSize,
  bool allowLargeWindow = false,
  Uint8List? compoundDictionary,
  Uint8List? sharedDictionary,
}) {
  final limit = maxOutputSize == null || maxOutputSize > maxOneShotOutput
      ? maxOneShotOutput
      : maxOutputSize;
  var capacity = (1 << 20) + maxTransformedWordLength;
  if (capacity > limit) capacity = limit;
  while (true) {
    final buffer = Uint8List(capacity);
    try {
      final used = _decodeInto(
        buffer,
        input,
        maxOutputSize: maxOutputSize,
        allowLargeWindow: allowLargeWindow,
        compoundDictionary: compoundDictionary,
        sharedDictionary: sharedDictionary,
      );
      return Uint8List.sublistView(buffer, 0, used);
    } on BrotliException catch (error) {
      if (error.code != BrotliErrorCode.outputLimitExceeded ||
          capacity >= limit) {
        rethrow;
      }
      capacity = capacity * 2 > limit ? limit : capacity * 2;
    }
  }
}

/// Decodes [input] into [dst] and returns the number of bytes written; throws
/// [BrotliErrorCode.outputLimitExceeded] when [dst] is too small.
int _decodeInto(
  Uint8List dst,
  Uint8List input, {
  required int? maxOutputSize,
  required bool allowLargeWindow,
  required Uint8List? compoundDictionary,
  required Uint8List? sharedDictionary,
}) {
  final core = BrotliDecoderCore(
    BitReader.fromBytes(input),
    allowLargeWindow: allowLargeWindow,
    maxOutputSize: maxOutputSize,
    compoundDictionary: compoundDictionary,
    sharedDictionary: sharedDictionary,
  );
  var used = 0;
  try {
    while (true) {
      final status = core.decode(dst, used, dst.length);
      used += core.bytesWritten;
      switch (status) {
        case BrotliStatus.done:
          return used;
        case BrotliStatus.needMoreOutput:
          throw BrotliException(
            BrotliErrorCode.outputLimitExceeded,
            'output buffer of ${dst.length} bytes is too small',
            inputOffset: core.reader.bytesConsumed,
          );
        case BrotliStatus.needMoreInput:
          throw BrotliException(
            BrotliErrorCode.truncatedInput,
            'decoder requested more input from a closed stream',
            inputOffset: core.reader.bytesConsumed,
          );
      }
    }
  } finally {
    // The decoder is finished either way; its window can serve the next one.
    core.state.releaseRingBuffer();
  }
}

/// Streaming decoder over chunked input.
///
/// The hot loop is the same as [decode]'s; streaming only changes how input
/// arrives and when output is flushed.
final class StreamingDecoder {
  StreamingDecoder({
    int? maxOutputSize,
    bool allowLargeWindow = false,
    Uint8List? compoundDictionary,
    Uint8List? sharedDictionary,
  }) {
    _core = BrotliDecoderCore(
      BitReader(_queue),
      allowLargeWindow: allowLargeWindow,
      maxOutputSize: maxOutputSize,
      compoundDictionary: compoundDictionary,
      sharedDictionary: sharedDictionary,
    );
  }

  final _InputQueue _queue = _InputQueue();
  late final BrotliDecoderCore _core;

  /// Queues [bytes] (copied; callers may reuse the buffer afterwards).
  void addInput(Uint8List bytes) {
    if (_queue.isClosed) throw StateError('input is already closed');
    _queue.add(bytes);
  }

  /// Declares that no further input will be added.
  void closeInput() => _queue.close();

  /// Bytes produced by the most recent [decode] call.
  int get bytesWritten => _core.bytesWritten;

  /// Input bytes consumed so far.
  int get consumedInput => _core.reader.bytesConsumed;

  /// Decodes into `output[start..end)` and returns the next status.
  BrotliStatus decode(Uint8List output, [int start = 0, int? end]) =>
      _core.decode(output, start, end);
}

final class _InputQueue implements BitReaderInput {
  final List<Uint8List> _chunks = <Uint8List>[];
  int _index = 0;
  int _offset = 0;
  bool _closed = false;

  void add(Uint8List bytes) {
    if (bytes.isNotEmpty) _chunks.add(Uint8List.fromList(bytes));
  }

  void close() {
    _closed = true;
  }

  @override
  int readInto(Uint8List destination, int offset, int length) {
    var written = 0;
    while (written < length && _index < _chunks.length) {
      final chunk = _chunks[_index];
      final available = chunk.length - _offset;
      if (available == 0) {
        // Drop consumed chunks so a long stream does not retain its input.
        _chunks[_index] = _empty;
        _index++;
        _offset = 0;
        continue;
      }
      final count = available < length - written ? available : length - written;
      destination.setRange(
        offset + written,
        offset + written + count,
        chunk,
        _offset,
      );
      _offset += count;
      written += count;
    }
    return written;
  }

  @override
  bool get isClosed => _closed;

  static final Uint8List _empty = Uint8List(0);
}
