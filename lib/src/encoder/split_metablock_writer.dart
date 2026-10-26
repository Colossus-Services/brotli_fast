/// Meta-block serialisation for the block-splitting encoder path.
///
/// This is the `BrotliStoreMetaBlock` layout with per-category block types:
///
/// ```text
/// ISLAST (1) [ISEMPTY (1) when ISLAST] MNIBBLES-4 (2) MLEN-1 (mnibbles*4)
/// [ISUNCOMPRESSED (1) when !ISLAST]
/// literal block split:  NBLTYPESL-1 (varint)
///                       [type-code tree, length-code tree, first switch]
/// command block split:  NBLTYPESI-1 (varint) [...]
/// distance block split: NBLTYPESD-1 (varint) [...]
/// NPOSTFIX (2) = 0, NDIRECT (4) = 0
/// literal context mode (2) x NBLTYPESL
/// literal context map:  NTREESL-1 (varint) [+ map when NTREESL > 1]
/// distance context map: NTREESD-1 (varint) [+ implicit map]
/// <NTREESL literal trees> <NBLTYPESI command trees> <NTREESD distance trees>
/// command stream with inline block switches
/// byte padding when ISLAST
/// ```
///
/// Block switches appear inline in the symbol stream: before a symbol whose
/// block is exhausted the encoder writes the block-type code (relative to the
/// previous two types) and the block-length code plus extra bits. The first
/// switch of each category is written as part of its split header.
library;

import 'dart:typed_data';

import 'bit_writer.dart';
import 'block_split.dart';
import 'command.dart';
import 'context_map_encoder.dart';
import 'context_modeling.dart';
import 'distance_params.dart';
import 'histogram_optimizer.dart';
import 'huffman_encoder.dart';
import 'metablock_writer.dart' show mnibblesForLength;

/// Largest meta-block length allowed by RFC 7932.
const int kMaxSplitMetaBlockLength = 1 << 24;

/// Runtime state for emitting one category's block switches.
final class _BlockSplitCode {
  _BlockSplitCode(this.split)
    : typeDepth = Uint8List(split.numTypes + 2),
      typeBits = Uint16List(split.numTypes + 2),
      lengthDepth = Uint8List(kNumBlockLengthCodes),
      lengthBits = Uint16List(kNumBlockLengthCodes);

  final BlockSplit split;
  final Uint8List typeDepth;
  final Uint16List typeBits;
  final Uint8List lengthDepth;
  final Uint16List lengthBits;
  final BlockTypeCodeCalculator calculator = BlockTypeCodeCalculator();

  int blockIndex = 0;
  int blockLength = 0;
  int blockType = 0;

  /// Starts emitting symbols of the first block (its switch is in the header).
  void beginEmission() {
    blockIndex = 0;
    blockLength = split.numBlocks == 0 ? 0 : split.lengths[0];
    blockType = split.numBlocks == 0 ? 0 : split.types[0];
  }
}

/// Writes one compressed meta-block that may use block types.
final class SplitMetaBlockWriter {
  SplitMetaBlockWriter() : _huffman = HuffmanEncoder() {
    _contextMaps = ContextMapEncoder(_huffman);
  }

  final HuffmanEncoder _huffman;
  late final ContextMapEncoder _contextMaps;

  Uint32List _literalHistogram = Uint32List(0);
  Uint32List _commandHistogram = Uint32List(0);
  Uint32List _distanceHistogram = Uint32List(0);
  Uint8List _literalDepth = Uint8List(0);
  Uint16List _literalBits = Uint16List(0);
  Uint8List _commandDepth = Uint8List(0);
  Uint16List _commandBits = Uint16List(0);
  Uint8List _distanceDepth = Uint8List(0);
  Uint16List _distanceBits = Uint16List(0);
  Uint8List _goodForRle = Uint8List(0);
  final Int32List _distBitsScratch = Int32List(1);
  final Int32List _distExtraScratch = Int32List(1);

  void _ensureCapacity(MetaBlockSplit split, int distanceAlphabet) {
    final literalSize = split.numLiteralTrees * numLiteralSymbols;
    final commandSize = split.commandSplit.numTypes * numCommandSymbols;
    final distanceSize = split.distanceSplit.numTypes * distanceAlphabet;
    if (_literalHistogram.length < literalSize) {
      _literalHistogram = Uint32List(literalSize);
      _literalDepth = Uint8List(literalSize);
      _literalBits = Uint16List(literalSize);
    }
    if (_commandHistogram.length < commandSize) {
      _commandHistogram = Uint32List(commandSize);
      _commandDepth = Uint8List(commandSize);
      _commandBits = Uint16List(commandSize);
    }
    if (_distanceHistogram.length < distanceSize) {
      _distanceHistogram = Uint32List(distanceSize);
      _distanceDepth = Uint8List(distanceSize);
      _distanceBits = Uint16List(distanceSize);
    }
    final maxAlphabet = numCommandSymbols;
    if (_goodForRle.length < maxAlphabet) {
      _goodForRle = Uint8List(maxAlphabet);
    }
  }

  /// Writes the meta-block for `input[start .. start + length)`.
  void store(
    BitWriter writer,
    Uint8List input,
    int start,
    int length,
    CommandBuffer commands,
    MetaBlockSplit split, {
    required bool isLast,
    DistanceParams? distanceParams,
    bool optimizeHistograms = false,
  }) {
    assert(length > 0 && length <= kMaxSplitMetaBlockLength);
    final distParams = distanceParams ?? kDefaultDistanceParams;
    final distanceAlphabet = distParams.alphabetSize;
    _ensureCapacity(split, distanceAlphabet);
    _literalHistogram.setRange(
      0,
      split.numLiteralTrees * numLiteralSymbols,
      split.literalHistograms,
    );
    _commandHistogram.setRange(
      0,
      split.commandSplit.numTypes * numCommandSymbols,
      split.commandHistograms,
    );
    _distanceHistogram.setRange(
      0,
      split.distanceSplit.numTypes * distanceAlphabet,
      split.distanceHistograms,
    );
    if (optimizeHistograms) {
      _optimizeHistogram(
        _literalHistogram,
        split.literalHistograms,
        split.numLiteralTrees,
        numLiteralSymbols,
      );
      _optimizeHistogram(
        _commandHistogram,
        split.commandHistograms,
        split.commandSplit.numTypes,
        numCommandSymbols,
      );
      _optimizeHistogram(
        _distanceHistogram,
        split.distanceHistograms,
        split.distanceSplit.numTypes,
        distanceAlphabet,
      );
    }

    final mnibbles = mnibblesForLength(length);
    writer.writeBits(1, isLast ? 1 : 0); // ISLAST
    if (isLast) writer.writeBits(1, 0); // ISEMPTY = 0
    writer.writeBits(2, mnibbles - 4);
    writer.writeBits(mnibbles * 4, length - 1);
    if (!isLast) writer.writeBits(1, 0); // ISUNCOMPRESSED = 0

    // Block split codes (with the first switch of each category).
    final literalCode = _BlockSplitCode(split.literalSplit);
    final commandCode = _BlockSplitCode(split.commandSplit);
    final distanceCode = _BlockSplitCode(split.distanceSplit);
    _storeBlockSplitCode(writer, literalCode);
    _storeBlockSplitCode(writer, commandCode);
    _storeBlockSplitCode(writer, distanceCode);

    writer.writeBits(2, distParams.npostfix); // NPOSTFIX
    writer.writeBits(4, distParams.ndirect >> distParams.npostfix); // NDIRECT
    final useContexts = split.numLiteralContexts > 1;
    final contextMode = useContexts ? kLiteralContextModeUtf8 : 0;
    for (var i = 0; i < split.literalSplit.numTypes; i++) {
      writer.writeBits(2, contextMode);
    }

    // Literal context map (also carries the literal tree count).
    _contextMaps.store(writer, split.literalContextMap, split.numLiteralTrees);
    // Distance context map: block type i uses distance tree i.
    storeTrivialContextMap(writer, _huffman, split.distanceSplit.numTypes, 2);

    for (var tree = 0; tree < split.numLiteralTrees; tree++) {
      final base = tree * numLiteralSymbols;
      _huffman.buildAndStore(
        Uint32List.sublistView(
          _literalHistogram,
          base,
          base + numLiteralSymbols,
        ),
        numLiteralSymbols,
        numLiteralSymbols,
        writer,
        Uint8List.sublistView(_literalDepth, base, base + numLiteralSymbols),
        Uint16List.sublistView(_literalBits, base, base + numLiteralSymbols),
      );
    }
    for (var tree = 0; tree < split.commandSplit.numTypes; tree++) {
      final base = tree * numCommandSymbols;
      _huffman.buildAndStore(
        Uint32List.sublistView(
          _commandHistogram,
          base,
          base + numCommandSymbols,
        ),
        numCommandSymbols,
        numCommandSymbols,
        writer,
        Uint8List.sublistView(_commandDepth, base, base + numCommandSymbols),
        Uint16List.sublistView(_commandBits, base, base + numCommandSymbols),
      );
    }
    for (var tree = 0; tree < split.distanceSplit.numTypes; tree++) {
      final base = tree * distanceAlphabet;
      _huffman.buildAndStore(
        Uint32List.sublistView(
          _distanceHistogram,
          base,
          base + distanceAlphabet,
        ),
        distanceAlphabet,
        distanceAlphabet,
        writer,
        Uint8List.sublistView(_distanceDepth, base, base + distanceAlphabet),
        Uint16List.sublistView(_distanceBits, base, base + distanceAlphabet),
      );
    }

    literalCode.beginEmission();
    commandCode.beginEmission();
    distanceCode.beginEmission();
    _storeCommands(
      writer,
      input,
      start,
      length,
      commands,
      split,
      literalCode,
      commandCode,
      distanceCode,
      distParams,
    );

    if (isLast) writer.alignToByte();
  }

  // -- header helpers ------------------------------------------------------

  void _storeBlockSplitCode(BitWriter writer, _BlockSplitCode code) {
    final split = code.split;
    storeVarLenUint8(writer, split.numTypes - 1);
    if (split.numTypes <= 1) return;

    final typeHistogram = Uint32List(split.numTypes + 2);
    final lengthHistogram = Uint32List(kNumBlockLengthCodes);
    final calculator = BlockTypeCodeCalculator();
    for (var i = 0; i < split.numBlocks; i++) {
      final typeCode = calculator.next(split.types[i]);
      if (i != 0) typeHistogram[typeCode]++;
      lengthHistogram[blockLengthPrefixCode(split.lengths[i])]++;
    }
    _huffman.buildAndStore(
      typeHistogram,
      split.numTypes + 2,
      split.numTypes + 2,
      writer,
      code.typeDepth,
      code.typeBits,
    );
    _huffman.buildAndStore(
      lengthHistogram,
      kNumBlockLengthCodes,
      kNumBlockLengthCodes,
      writer,
      code.lengthDepth,
      code.lengthBits,
    );
    // First block switch: length only (the type is implicitly 0). The type
    // code is not written, but the calculator must still advance through it so
    // that the inline switches agree with the histogram built above.
    code.calculator.next(split.types[0]);
    _storeBlockLength(writer, code, split.lengths[0]);
  }

  void _storeBlockLength(BitWriter writer, _BlockSplitCode code, int length) {
    final lengthCode = blockLengthPrefixCode(length);
    writer.writeBits(code.lengthDepth[lengthCode], code.lengthBits[lengthCode]);
    final extraBits = kBlockLengthCodeExtraBits[lengthCode];
    writer.writeBits(extraBits, length - kBlockLengthCodeOffset[lengthCode]);
  }

  void _beginNextBlock(BitWriter writer, _BlockSplitCode code) {
    final split = code.split;
    code.blockIndex++;
    assert(code.blockIndex < split.numBlocks);
    final type = split.types[code.blockIndex];
    final typeCode = code.calculator.next(type);
    writer.writeBits(code.typeDepth[typeCode], code.typeBits[typeCode]);
    _storeBlockLength(writer, code, split.lengths[code.blockIndex]);
    code.blockLength = split.lengths[code.blockIndex];
    code.blockType = type;
  }

  /// Applies [optimizeHuffmanCountsForRle] to every tree histogram in
  /// `dst`/`src` (which share their layout).
  ///
  /// The RLE optimiser only adjusts counts; if it ever zeroed a symbol that was
  /// present before, that tree is left unoptimised (the symbol must keep a
  /// non-zero code length or the stream would corrupt).
  void _optimizeHistogram(
    Uint32List dst,
    Uint32List src,
    int numTrees,
    int alphabetSize,
  ) {
    for (var tree = 0; tree < numTrees; tree++) {
      final base = tree * alphabetSize;
      optimizeHuffmanCountsForRle(
        Uint32List.sublistView(dst, base, base + alphabetSize),
        alphabetSize,
        _goodForRle,
      );
      var safe = true;
      for (var s = 0; s < alphabetSize; s++) {
        if (src[base + s] != 0 && dst[base + s] == 0) {
          safe = false;
          break;
        }
      }
      if (!safe) {
        dst.setRange(base, base + alphabetSize, src, base);
      }
    }
  }

  // -- symbol stream -------------------------------------------------------

  void _storeCommands(
    BitWriter writer,
    Uint8List input,
    int start,
    int length,
    CommandBuffer commands,
    MetaBlockSplit split,
    _BlockSplitCode literalCode,
    _BlockSplitCode commandCode,
    _BlockSplitCode distanceCode,
    DistanceParams distanceParams,
  ) {
    final contextMap = split.literalContextMap;
    var pos = start;
    for (var i = 0; i < commands.count; i++) {
      final cmdPrefix = commands.cmdPrefix[i];
      final insertLen = commands.insertLen[i];
      final copyLen = commands.copyLen[i];

      if (commandCode.blockLength == 0) {
        _beginNextBlock(writer, commandCode);
      }
      commandCode.blockLength--;
      writer.writeBits(
        _commandDepth[commandCode.blockType * numCommandSymbols + cmdPrefix],
        _commandBits[commandCode.blockType * numCommandSymbols + cmdPrefix],
      );

      // Insert extra bits, then copy extra bits (StoreCommandExtra).
      final insCode = getInsertLengthCode(insertLen);
      writer.writeBits(
        kInsExtra[insCode],
        commandInsertExtraValue(insertLen, insCode),
      );
      if (copyLen != 0) {
        final copyCode = getCopyLengthCode(copyLen);
        writer.writeBits(
          kCopyExtra[copyCode],
          commandCopyExtraValue(copyLen, copyCode),
        );
      }

      for (var j = 0; j < insertLen; j++) {
        if (literalCode.blockLength == 0) {
          _beginNextBlock(writer, literalCode);
        }
        literalCode.blockLength--;
        final literal = input[pos];
        final context = split.numLiteralContexts > 1
            ? literalContextId(input, pos)
            : 0;
        final tree =
            contextMap[literalCode.blockType * kNumLiteralContexts + context];
        final index = tree * numLiteralSymbols + literal;
        writer.writeBits(_literalDepth[index], _literalBits[index]);
        pos++;
      }

      if (copyLen != 0) {
        pos += copyLen;
        if (cmdPrefix >= 128) {
          if (distanceCode.blockLength == 0) {
            _beginNextBlock(writer, distanceCode);
          }
          distanceCode.blockLength--;
          // Re-encode the parameter-independent distance code with the
          // meta-block's chosen NPOSTFIX / NDIRECT.
          final packed = encodeDistanceCode(
            commands.distCode[i],
            distanceParams,
            _distBitsScratch,
            _distExtraScratch,
          );
          final distanceSymbol = packed & 0x3FF;
          final extraBits = packed >> 10;
          final index =
              distanceCode.blockType * distanceParams.alphabetSize +
              distanceSymbol;
          writer.writeBits(_distanceDepth[index], _distanceBits[index]);
          if (extraBits != 0) {
            writer.writeBits(extraBits, _distExtraScratch[0]);
          }
        }
      }
    }
    assert(pos == start + length, 'command stream covers the whole block');
  }
}
