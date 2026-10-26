/// Meta-block writer for the fast tier (qualities 0..5).
///
/// A deliberately minimal serializer: one literal tree, one command tree and
/// one distance tree per meta-block, with no context modeling, block splitting
/// or dictionary references (the high-ratio path in `encoder.dart` owns those).
/// Common short commands and runs of equal-length literals are packed into
/// single writes.
library;

import 'dart:typed_data';

import 'bit_writer.dart';
import 'command.dart';
import 'huffman_encoder.dart';
import 'metablock_writer.dart' show mnibblesForLength;

/// Number of command symbols in the length-code alphabet.
const int _numCommandSymbols = 704;

/// Number of distance symbols for NPOSTFIX = NDIRECT = 0.
const int _numDistanceSymbols = 64;

/// Writes single-tree Brotli meta-blocks.
final class FastMetaBlockWriter {
  final HuffmanEncoder _huffman = HuffmanEncoder();

  final Uint32List _literalHistogram = Uint32List(256);
  final Uint32List _commandHistogram = Uint32List(_numCommandSymbols);
  final Uint32List _distanceHistogram = Uint32List(_numDistanceSymbols);

  final Uint8List _literalDepth = Uint8List(256);
  final Uint8List _commandDepth = Uint8List(_numCommandSymbols);
  final Uint8List _distanceDepth = Uint8List(_numDistanceSymbols);

  final Uint16List _literalBits = Uint16List(256);
  final Uint16List _commandBits = Uint16List(_numCommandSymbols);
  final Uint16List _distanceBits = Uint16List(_numDistanceSymbols);

  /// Writes one compressed meta-block without the ISLAST flag.
  void store(
    BitWriter writer,
    Uint8List input,
    int start,
    int length,
    CommandBuffer commands,
  ) {
    final literalHistogram = _literalHistogram;
    final commandHistogram = _commandHistogram;
    final distanceHistogram = _distanceHistogram;
    literalHistogram.fillRange(0, 256, 0);
    commandHistogram.fillRange(0, _numCommandSymbols, 0);
    distanceHistogram.fillRange(0, _numDistanceSymbols, 0);

    var pos = start;
    for (var i = 0; i < commands.count; i++) {
      final insertLen = commands.insertLen[i];
      for (var j = 0; j < insertLen; j++) {
        literalHistogram[input[pos + j]]++;
      }
      pos += insertLen;
      final cmdPrefix = commands.cmdPrefix[i];
      commandHistogram[cmdPrefix]++;
      final copyLen = commands.copyLen[i];
      if (copyLen != 0 && cmdPrefix >= 128) {
        distanceHistogram[commands.distPrefix[i] & 0x3FF]++;
      }
      pos += copyLen;
    }

    // Header first: not last, compressed, one block type each, NPOSTFIX =
    // NDIRECT = 0, context mode = LSB6, trivial literal/distance context maps.
    final mnibbles = mnibblesForLength(length);
    writer.writeBits(1, 0); // ISLAST
    writer.writeBits(2, mnibbles - 4);
    writer.writeBits(mnibbles * 4, length - 1);
    writer.writeBits(1, 0); // ISUNCOMPRESSED
    writer.writeBits(1, 0); // NBLTYPESL = 1
    writer.writeBits(1, 0); // NBLTYPESI = 1
    writer.writeBits(1, 0); // NBLTYPESD = 1
    writer.writeBits(2, 0); // NPOSTFIX
    writer.writeBits(4, 0); // NDIRECT
    writer.writeBits(2, 0); // context mode: LSB6
    writer.writeBits(1, 0); // literal context map (trivial)
    writer.writeBits(1, 0); // distance context map (trivial)

    _huffman.buildAndStore(
      literalHistogram,
      256,
      256,
      writer,
      _literalDepth,
      _literalBits,
    );
    _huffman.buildAndStore(
      commandHistogram,
      _numCommandSymbols,
      _numCommandSymbols,
      writer,
      _commandDepth,
      _commandBits,
    );
    _huffman.buildAndStore(
      distanceHistogram,
      _numDistanceSymbols,
      _numDistanceSymbols,
      writer,
      _distanceDepth,
      _distanceBits,
    );

    // Command stream.
    final literalDepth = _literalDepth;
    final literalBits = _literalBits;
    final commandDepth = _commandDepth;
    final commandBits = _commandBits;
    final distanceDepth = _distanceDepth;
    final distanceBits = _distanceBits;
    pos = start;
    for (var i = 0; i < commands.count; i++) {
      final insertLen = commands.insertLen[i];
      final copyLen = commands.copyLen[i];
      final command = commands.cmdPrefix[i];
      // The command symbol and its insert/copy extra bits are usually short
      // enough to emit as one write; the bits are identical either way.
      final commandDepthBits = commandDepth[command];
      final insCode = getInsertLengthCode(insertLen);
      final insExtraBits = kInsExtra[insCode];
      final insExtraValue = commandInsertExtraValue(insertLen, insCode);
      var copyExtraBits = 0;
      var copyExtraValue = 0;
      if (copyLen != 0) {
        final copyCode = getCopyLengthCode(copyLen);
        copyExtraBits = kCopyExtra[copyCode];
        copyExtraValue = commandCopyExtraValue(copyLen, copyCode);
      }
      final totalBits = commandDepthBits + insExtraBits + copyExtraBits;
      if (totalBits <= 32) {
        writer.writeBits(
          totalBits,
          commandBits[command] |
              (insExtraValue << commandDepthBits) |
              (copyExtraValue << (commandDepthBits + insExtraBits)),
        );
      } else {
        writer.writeBits(commandDepthBits, commandBits[command]);
        writer.writeBits(insExtraBits, insExtraValue);
        writer.writeBits(copyExtraBits, copyExtraValue);
      }
      // Literals dominate binary meta-blocks. Four consecutive literals that
      // share a code length are packed into a single write (up to 32 bits),
      // cutting the per-literal call overhead without changing the bit stream.
      var j = 0;
      while (j < insertLen) {
        if (insertLen - j >= 4) {
          final a = input[pos + j];
          final b = input[pos + j + 1];
          final c = input[pos + j + 2];
          final d = input[pos + j + 3];
          final depth = literalDepth[a];
          if (depth == literalDepth[b] &&
              depth == literalDepth[c] &&
              depth == literalDepth[d] &&
              depth <= 8) {
            final packed =
                literalBits[a] |
                (literalBits[b] << depth) |
                (literalBits[c] << (depth * 2)) |
                (literalBits[d] << (depth * 3));
            writer.writeBits(depth * 4, packed);
            j += 4;
            continue;
          }
        }
        final literal = input[pos + j];
        writer.writeBits(literalDepth[literal], literalBits[literal]);
        j++;
      }
      pos += insertLen;
      if (copyLen != 0) {
        pos += copyLen;
        if (command >= 128) {
          final distancePrefix = commands.distPrefix[i];
          final symbol = distancePrefix & 0x3FF;
          final symbolDepth = distanceDepth[symbol];
          final extraBits = distancePrefix >> 10;
          if (symbolDepth + extraBits <= 32) {
            writer.writeBits(
              symbolDepth + extraBits,
              distanceBits[symbol] | (commands.distExtra[i] << symbolDepth),
            );
          } else {
            writer.writeBits(symbolDepth, distanceBits[symbol]);
            if (extraBits != 0) {
              writer.writeBits(extraBits, commands.distExtra[i]);
            }
          }
        }
      }
    }
  }
}
