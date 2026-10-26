/// Fast tier of the encoder: qualities 0..5 without dictionaries, at the
/// default 22-bit window.
///
/// One lazy (or, for binary input, greedy) parse per 128 KiB meta-block and a
/// single-tree serialization; see `fast_parse.dart` and
/// `fast_metablock_writer.dart`.
library;

import 'dart:typed_data';

import '../options.dart';
import 'bit_writer.dart';
import 'command.dart';
import 'fast_metablock_writer.dart';
import 'fast_parse.dart';
import 'metablock_writer.dart'
    show uncompressedMetaBlockBits, writeUncompressedMetaBlock;

/// Window bits used by the fast tier.
const int fastLgwin = 22;

/// The fast-tier parameters for encoding [input] with [options], or `null`
/// when the high-ratio path must handle it.
///
/// * qualities 2..5 use the lazy tier (binary input at quality 5 uses a
///   greedier, hash-light variant);
/// * qualities 0/1 use the fast tier only for binary input, whose shared
///   greedy tier beats the text-oriented greedy path on binary data.
FastParseParams? fastParamsFor(Uint8List input, BrotliEncodeOptions options) {
  if (options.dictionary != null ||
      options.largeWindow ||
      options.lgwin != fastLgwin) {
    return null;
  }
  final quality = options.quality;
  if (quality >= 2 && quality <= 5) {
    return quality == 5 && _looksBinary(input)
        ? FastParseParams.q5Binary
        : FastParseParams.q5;
  }
  if (quality <= 1 && _looksBinary(input)) return FastParseParams.greedyBinary;
  return null;
}

/// Writes the meta-blocks for non-empty [input] (no stream header, no final
/// block).
void writeFastMetaBlocks(
  BitWriter writer,
  Uint8List input,
  FastParseParams params,
) {
  // The chain is only walked by multi-candidate and lazy searches; the
  // single-slot greedy tier never reads it.
  final hasher = FastHasher(
    input,
    params.bucketBits,
    trackChain: params.maxCandidates > 1 || params.lazySteps > 0,
  );
  // Copies are at least minMatch == 4 bytes, so a block needs at most
  // blockSize / 4 commands; sizing the buffer that way (instead of the
  // worst-case 2 bytes per command) avoids a multi-megabyte zeroed allocation
  // on every encode.
  final commands = CommandBuffer(params.blockSize ~/ 4 + 16);
  final distanceCache = createInitialDistanceCache();
  final metaBlockWriter = FastMetaBlockWriter();
  const maxBackwardLimit = (1 << fastLgwin) - 16;
  final blockSize = params.blockSize;
  for (var offset = 0; offset < input.length; offset += blockSize) {
    final length = offset + blockSize <= input.length
        ? blockSize
        : input.length - offset;
    final startBits = writer.bitPosition;
    // The distance cache is decoder state: if this block ends up stored
    // uncompressed its copies never reach the decoder, so roll it back.
    final saved0 = distanceCache[0];
    final saved1 = distanceCache[1];
    final saved2 = distanceCache[2];
    final saved3 = distanceCache[3];
    fastParse(
      input,
      offset,
      length,
      hasher,
      commands,
      distanceCache,
      maxBackwardLimit,
      params,
    );
    final mark = writer.mark();
    metaBlockWriter.store(writer, input, offset, length, commands);
    if (writer.bitPosition - startBits >
        uncompressedMetaBlockBits(length, startBits)) {
      writer.rewind(mark);
      distanceCache[0] = saved0;
      distanceCache[1] = saved1;
      distanceCache[2] = saved2;
      distanceCache[3] = saved3;
      writeUncompressedMetaBlock(writer, input, offset, length);
    }
  }
}

/// Conservative content probe: a small sample is classified as binary when
/// under 90% of its bytes are printable ASCII (plus tab/CR/LF). UTF-8 text is
/// 100% printable, the binary benchmark corpus ~68%.
bool _looksBinary(Uint8List input) {
  if (input.isEmpty) return false;
  final sample = input.length < 4096 ? input.length : 4096;
  var printable = 0;
  for (var i = 0; i < sample; i++) {
    final byte = input[i];
    if ((byte >= 0x20 && byte <= 0x7E) ||
        byte == 9 ||
        byte == 10 ||
        byte == 13) {
      printable++;
    }
  }
  return printable * 10 < sample * 9;
}
