/// Brotli decoder state machine: stream header, metablock headers, metadata
/// skipping, uncompressed blocks, ring-buffer wrap/flush, and the compressed
/// metablock phases (delegated to `decoder_metablock.dart`).
///
/// This is the state machine of `Decode.decompress` from
/// `java/org/brotli/dec/Decode.java`. It keeps the reference's
/// `while + switch (runningState)` shape; the compressed-metablock phases
/// (`compressedBlockStart`, `mainLoop`, `insertLoop`, `readDistance`,
/// `copyLoop`) call into `decoder_metablock.dart` and hand control back here
/// for every output flush.
///
/// Implemented by this file:
///
/// * stream header: window bits `10..24`, reserved-value rejection, and the
///   non-RFC large-window extension (`25..30`) gated by
///   [DecoderState.allowLargeWindow];
/// * metablock headers: ISLAST, ISLASTEMPTY, MNIBBLES, MLEN, ISUNCOMPRESSED,
///   metadata, including the exuberant-nibble checks;
/// * metadata payloads are skipped (never copied), also when they span many
///   input-window refills;
/// * uncompressed metablocks are copied into the ring buffer, flushed when the
///   window is full, and wrapped;
/// * ring-buffer growth (`maybeReallocateRingBuffer`), eager flushing,
///   wrapping and the `maxOutputSize` guard;
/// * compressed metablocks: Huffman block trees, context maps, distance LUT,
///   command/literal/copy loops and block switching. Distances past
///   `maxDistance` resolve to the RFC static dictionary or, when a compound
///   dictionary is attached, to the caller's dictionary (the non-RFC
///   `brotli --dictionary` extension);
/// * truncated / trailing / padding / header errors surface as
///   [BrotliException], never as `RangeError`/`StateError`.
///
/// The class is single-stream and synchronous. Input suspension is possible
/// through [BitReader]; the compressed-header step machine and the hot loops
/// are resumable, so chunked input works.
library;

import 'dart:typed_data';

import '../common/errors.dart';
import '../common/format_tables.dart';
import '../options.dart';
import 'bit_reader.dart';
import 'decoder_metablock.dart';
import 'decoder_state.dart';
import 'fast_metablock_supported.dart';
import 'shared_dictionary.dart';

/// Brotli decoder core: owns the [BitReader], the [DecoderState] and the state
/// machine.
///
/// Callers invoke [decode] repeatedly with (possibly small) output buffers and
/// react to the returned [BrotliStatus]:
///
/// * [BrotliStatus.needMoreOutput]: the output slice is full; call again.
/// * [BrotliStatus.needMoreInput]: the [BitReader] is still open and wants more
///   bytes. (With a closed reader this never happens.)
/// * [BrotliStatus.done]: the stream ended; further calls return `done`.
final class BrotliDecoderCore {
  /// Creates a decoder, parsing [sharedDictionary] eagerly.
  ///
  /// Malformed serialized shared dictionaries throw [BrotliException] here,
  /// before any stream data is consumed. An embedded LZ77 prefix is merged
  /// into the compound dictionary address space after [compoundDictionary].
  factory BrotliDecoderCore(
    BitReader reader, {
    bool allowLargeWindow = false,
    int? maxOutputSize,
    Uint8List? compoundDictionary,
    Uint8List? sharedDictionary,
  }) {
    final shared = sharedDictionary == null
        ? null
        : SharedDictionary.parse(sharedDictionary);
    return BrotliDecoderCore._(
      reader,
      DecoderState(
        allowLargeWindow: allowLargeWindow,
        maxOutputSize: maxOutputSize,
        compoundDictionary: combineCompoundDictionary(
          compoundDictionary,
          shared,
        ),
        sharedDictionary: shared,
      ),
    );
  }

  BrotliDecoderCore._(this.reader, this.state) {
    state.phase = DecodePhase.initialized;
  }

  /// Bit-level input for this stream.
  final BitReader reader;

  /// Mutable state shared with the compressed-block layer.
  final DecoderState state;

  /// Bytes produced by the most recent [decode] call.
  int get bytesWritten => state.bytesWritten;

  /// Decodes into `output[start..end)` and returns the next status.
  ///
  /// `end` defaults to `output.length`. On return, [bytesWritten] tells how many
  /// bytes were appended to the slice.
  BrotliStatus decode(Uint8List output, [int start = 0, int? end]) {
    final limit = end ?? output.length;
    RangeError.checkValidRange(start, limit, output.length);
    state.output = output;
    state.outputOffset = start;
    state.outputLength = limit;
    state.outputUsed = start;

    if (state.phase == DecodePhase.uninitialized) {
      state.phase = DecodePhase.initialized;
    }
    if (state.phase == DecodePhase.closed) {
      throw BrotliException(BrotliErrorCode.internalError, 'decoder is closed');
    }
    if (state.phase == DecodePhase.finished) {
      _finishStream();
      return BrotliStatus.done;
    }

    while (state.phase != DecodePhase.finished) {
      switch (state.phase) {
        case DecodePhase.initialized:
          final status = _startStream();
          if (status != null) {
            return status;
          }
          continue;

        case DecodePhase.blockStart:
          if (state.metaBlockLength < 0) {
            throw BrotliException(
              BrotliErrorCode.invalidMetaBlockLength,
              'negative metablock length',
              inputOffset: reader.bytesConsumed,
            );
          }
          final status = _readNextMetablockHeader();
          if (status != null) {
            return status;
          }
          continue;

        case DecodePhase.readMetadata:
          final status = _readMetadata();
          if (status != null) {
            return status;
          }
          continue;

        case DecodePhase.copyUncompressed:
          final status = _copyUncompressedData();
          if (status != null) {
            return status;
          }
          continue;

        case DecodePhase.initWrite:
          state.ringBufferBytesReady = state.pos < state.ringBufferSize
              ? state.pos
              : state.ringBufferSize;
          state.phase = DecodePhase.write;
          continue;

        case DecodePhase.write:
          final status = _writeRingBuffer();
          if (status != null) {
            return status;
          }
          continue;

        case DecodePhase.compressedBlockStart:
          final status = decodeCompressedMetablockHeader(reader, state);
          if (status != null) {
            return status;
          }
          if (state.phase == DecodePhase.mainLoop && _canUseFastMetablock()) {
            if (!decodeCompressedMetablockFast(reader, state)) {
              continue;
            }
          }
          continue;

        case DecodePhase.mainLoop:
          final status = decodeMainLoop(reader, state);
          if (status != null) {
            return status;
          }
          continue;

        case DecodePhase.insertLoop:
          final status = decodeInsertLoop(reader, state);
          if (status != null) {
            return status;
          }
          continue;

        case DecodePhase.readDistance:
          final status = decodeDistance(reader, state);
          if (status != null) {
            return status;
          }
          continue;

        case DecodePhase.copyLoop:
          final status = decodeCopyLoop(reader, state);
          if (status != null) {
            return status;
          }
          continue;

        case DecodePhase.copyFromCompoundDictionary:
          final status = decodeCompoundDictionaryCopy(state);
          if (status != null) {
            return status;
          }
          continue;

        case DecodePhase.useDictionary:
          // The distance resolver switches straight to
          // [DecodePhase.copyFromCompoundDictionary] or back to the main loop;
          // reaching this state means the state machine is inconsistent.
          throw BrotliException(
            BrotliErrorCode.internalError,
            'unexpected useDictionary phase',
            inputOffset: reader.bytesConsumed,
          );

        case DecodePhase.finished:
        case DecodePhase.uninitialized:
        case DecodePhase.closed:
          throw BrotliException(
            BrotliErrorCode.internalError,
            'unexpected decoder phase ${state.phase.name}',
          );
      }
    }

    _finishStream();
    return BrotliStatus.done;
  }

  // ---------------------------------------------------------------------------
  // Stream / metablock headers.
  // ---------------------------------------------------------------------------

  /// Parses the stream header. Returns a suspension status or `null` on
  /// success.
  BrotliStatus? _startStream() {
    if (!reader.refill()) {
      return BrotliStatus.needMoreInput;
    }
    _requireHeaderBits();
    reader.fillBitWindow();
    final windowBits = _decodeWindowBits();
    state.windowBits = windowBits;
    state.maxRingBufferSize = 1 << windowBits;
    state.maxBackwardDistance = state.maxRingBufferSize - 16;
    state.phase = DecodePhase.blockStart;
    return null;
  }

  /// Port of `Decode.decodeWindowBits`.
  ///
  /// Returns the effective window bits or throws
  /// [BrotliErrorCode.invalidWindowBits] for reserved / disallowed values.
  int _decodeWindowBits() {
    final allowLargeWindow = state.allowLargeWindow;
    state.largeWindow = false;
    reader.fillBitWindow();
    if (reader.readFewBits(1) == 0) {
      return 16;
    }
    var n = reader.readFewBits(3);
    if (n != 0) {
      return 17 + n;
    }
    n = reader.readFewBits(3);
    if (n != 0) {
      if (n == 1) {
        if (!allowLargeWindow) {
          // Reserved value in a standard RFC 7932 stream.
          throw BrotliException(
            BrotliErrorCode.invalidWindowBits,
            'reserved window-bits value (large window is disabled)',
            inputOffset: reader.bytesConsumed,
          );
        }
        state.largeWindow = true;
        // Reserved bit for post-large-window extensions.
        if (reader.readFewBits(1) != 0) {
          throw BrotliException(
            BrotliErrorCode.invalidWindowBits,
            'reserved bit set in the large-window header',
            inputOffset: reader.bytesConsumed,
          );
        }
        n = reader.readFewBits(6);
        if (n < minLargeWindowBits || n > maxLargeWindowBits) {
          throw BrotliException(
            BrotliErrorCode.invalidWindowBits,
            'large-window bits $n out of range '
            '[$minLargeWindowBits, $maxLargeWindowBits]',
            inputOffset: reader.bytesConsumed,
          );
        }
        return n;
      }
      return 8 + n;
    }
    return 17;
  }

  /// Reads the next metablock header and advances [DecoderState.phase].
  BrotliStatus? _readNextMetablockHeader() {
    if (state.inputEnd != 0) {
      state.nextPhase = DecodePhase.finished;
      state.phase = DecodePhase.initWrite;
      return null;
    }
    if (!reader.refill()) {
      return BrotliStatus.needMoreInput;
    }
    _requireHeaderBits();
    _decodeMetaBlockLength();

    if (state.metaBlockLength == 0 && !state.isMetadata) {
      // ISLASTEMPTY: the next blockStart iteration sees inputEnd != 0.
      return null;
    }
    if (state.isUncompressed || state.isMetadata) {
      reader.jumpToByteBoundary();
      state.phase = state.isMetadata
          ? DecodePhase.readMetadata
          : DecodePhase.copyUncompressed;
    } else {
      state.phase = DecodePhase.compressedBlockStart;
      state.headerStep = 0;
    }
    if (state.isMetadata) {
      assert(state.metaBlockLength >= 0);
      return null;
    }

    assert(
      state.metaBlockLength <= maxMetaBlockLength,
      'metablock length ${state.metaBlockLength} exceeds 1 << 24',
    );
    state.expectedTotalSize += state.metaBlockLength;
    if (state.expectedTotalSize > maxExpectedTotalSize) {
      state.expectedTotalSize = maxExpectedTotalSize;
    }
    if (state.ringBufferSize < state.maxRingBufferSize) {
      state.maybeReallocateRingBuffer();
    }
    return null;
  }

  /// Whether the fused whole-metablock loop can run without a flush,
  /// suspension or dictionary-chunk copy in the middle.
  bool _canUseFastMetablock() {
    if (!fastMetablockSupported) {
      return false;
    }
    if (!reader.sourceClosed) {
      return false;
    }
    if (state.compoundDictionarySize != 0 || state.sharedDictionary != null) {
      return false;
    }
    final pos = state.pos;
    final meta = state.metaBlockLength;
    if (meta <= 0) {
      return false;
    }
    if (pos + meta + maxTransformedWordLength > state.ringBuffer.length) {
      return false;
    }
    return state.outputUsed + pos + meta <= state.outputLength;
  }

  /// Port of `Decode.decodeMetaBlockLength`.
  void _decodeMetaBlockLength() {
    reader.fillBitWindow();
    state.inputEnd = reader.readFewBits(1);
    state.metaBlockLength = 0;
    state.isUncompressed = false;
    state.isMetadata = false;
    if (state.inputEnd != 0 && reader.readFewBits(1) != 0) {
      // ISLASTEMPTY: an empty final metablock.
      return;
    }
    final sizeNibbles = reader.readFewBits(2) + 4;
    if (sizeNibbles == 7) {
      state.isMetadata = true;
      if (reader.readFewBits(1) != 0) {
        throw BrotliException(
          BrotliErrorCode.invalidMetaBlockLength,
          'metadata reserved bit is set',
          inputOffset: reader.bytesConsumed,
        );
      }
      final sizeBytes = reader.readFewBits(2);
      if (sizeBytes == 0) {
        // Empty metadata block.
        return;
      }
      for (var i = 0; i < sizeBytes; i++) {
        reader.fillBitWindow();
        final bits = reader.readFewBits(8);
        if (bits == 0 && i + 1 == sizeBytes && sizeBytes > 1) {
          throw BrotliException(
            BrotliErrorCode.invalidMetaBlockLength,
            'metadata length has an exuberant last byte',
            inputOffset: reader.bytesConsumed,
          );
        }
        state.metaBlockLength += bits << (i * 8);
      }
    } else {
      for (var i = 0; i < sizeNibbles; i++) {
        reader.fillBitWindow();
        final bits = reader.readFewBits(4);
        if (bits == 0 && i + 1 == sizeNibbles && sizeNibbles > 4) {
          throw BrotliException(
            BrotliErrorCode.invalidMetaBlockLength,
            'metablock length has an exuberant last nibble',
            inputOffset: reader.bytesConsumed,
          );
        }
        state.metaBlockLength += bits << (i * 4);
      }
    }
    state.metaBlockLength++;
    if (state.inputEnd == 0) {
      state.isUncompressed = reader.readFewBits(1) != 0;
    }
  }

  // ---------------------------------------------------------------------------
  // Metadata / uncompressed payloads.
  // ---------------------------------------------------------------------------

  /// Skips the current metadata payload (port of the READ_METADATA loop).
  BrotliStatus? _readMetadata() {
    while (state.metaBlockLength > 0) {
      final skipped = reader.skipRawBytes(state.metaBlockLength);
      state.metaBlockLength -= skipped;
      if (state.metaBlockLength == 0) {
        break;
      }
      if (!reader.refill()) {
        return BrotliStatus.needMoreInput;
      }
      if (reader.endOfStreamReached && reader.filled == 0) {
        throw BrotliException(
          BrotliErrorCode.truncatedInput,
          'metadata payload is shorter than its declared length '
          '(${state.metaBlockLength} bytes missing)',
          inputOffset: reader.tailBytes,
        );
      }
    }
    state.phase = DecodePhase.blockStart;
    return null;
  }

  /// Copies a raw metablock into the ring buffer (port of
  /// `Decode.copyUncompressedData`).
  BrotliStatus? _copyUncompressedData() {
    if (state.metaBlockLength <= 0) {
      if (!reader.reload()) {
        return BrotliStatus.needMoreInput;
      }
      state.phase = DecodePhase.blockStart;
      return null;
    }

    final remainingInWindow = state.ringBufferSize - state.pos;
    final chunkLength = remainingInWindow < state.metaBlockLength
        ? remainingInWindow
        : state.metaBlockLength;
    final copied = reader.copyRawBytes(
      state.ringBuffer,
      state.pos,
      chunkLength,
    );
    state.metaBlockLength -= copied;
    state.pos += copied;
    if (copied < chunkLength) {
      // The input window ran dry mid-block. Suspending here is safe: only
      // `metaBlockLength` / `pos` advance, and both are resumable.
      if (!reader.refill()) {
        return BrotliStatus.needMoreInput;
      }
      if (reader.endOfStreamReached && reader.filled == 0) {
        throw BrotliException(
          BrotliErrorCode.truncatedInput,
          'uncompressed metablock is shorter than its declared length '
          '(${state.metaBlockLength} bytes missing)',
          inputOffset: reader.tailBytes,
        );
      }
      return null;
    }
    if (state.pos == state.ringBufferSize) {
      state.nextPhase = DecodePhase.copyUncompressed;
      state.phase = DecodePhase.initWrite;
      return null;
    }
    if (!reader.reload()) {
      return BrotliStatus.needMoreInput;
    }
    state.phase = DecodePhase.blockStart;
    return null;
  }

  // ---------------------------------------------------------------------------
  // Ring-buffer flush / wrap.
  // ---------------------------------------------------------------------------

  /// Port of `Decode.writeRingBuffer` plus the WRITE-state wrap logic.
  BrotliStatus? _writeRingBuffer() {
    final toWrite = _min(
      state.outputLength - state.outputUsed,
      state.ringBufferBytesReady - state.ringBufferBytesWritten,
    );
    if (toWrite > 0) {
      final limit = state.maxOutputSize;
      if (limit != null && state.totalOutput + toWrite > limit) {
        throw BrotliException(
          BrotliErrorCode.outputLimitExceeded,
          'output limit of $limit bytes exceeded',
        );
      }
      state.output.setRange(
        state.outputUsed,
        state.outputUsed + toWrite,
        state.ringBuffer,
        state.ringBufferBytesWritten,
      );
      state.outputUsed += toWrite;
      state.ringBufferBytesWritten += toWrite;
      state.totalOutput += toWrite;
    }

    if (state.outputUsed >= state.outputLength &&
        state.ringBufferBytesWritten < state.ringBufferBytesReady) {
      // The caller's slice is full and bytes are still pending; defer the wrap.
      return BrotliStatus.needMoreOutput;
    }

    // WRITE -> nextRunningState, wrapping the ring buffer.
    if (state.pos >= state.maxBackwardDistance) {
      state.maxDistance = state.maxBackwardDistance;
    }
    if (state.pos >= state.ringBufferSize) {
      if (state.pos > state.ringBufferSize) {
        // Only a transformed dictionary word may overflow the window.
        state.ringBuffer.setRange(
          0,
          state.pos - state.ringBufferSize,
          state.ringBuffer,
          state.ringBufferSize,
        );
      }
      state.pos = state.ringBufferSize > 0
          ? state.pos & (state.ringBufferSize - 1)
          : 0;
      state.ringBufferBytesWritten = 0;
    }
    state.phase = state.nextPhase;
    return null;
  }

  /// Validates padding and stream length once FINISHED is reached.
  void _finishStream() {
    reader.jumpToByteBoundary();
    reader.checkHealth(true);
  }

  // ---------------------------------------------------------------------------
  // Helpers.
  // ---------------------------------------------------------------------------

  /// Throws [BrotliErrorCode.truncatedInput] when the stream ended exactly at a
  /// point where more header bits are required.
  ///
  /// Without this check a zero-byte input would be parsed out of the reader's
  /// zero slack and fail as an unrelated format error.
  void _requireHeaderBits() {
    if (!reader.endOfStreamReached) {
      return;
    }
    if (reader.consumedBits >= reader.tailBytes * 8) {
      throw BrotliException(
        BrotliErrorCode.truncatedInput,
        'input ended before the next metablock header',
        inputOffset: reader.tailBytes,
      );
    }
  }

  static int _min(int a, int b) => a < b ? a : b;
}
