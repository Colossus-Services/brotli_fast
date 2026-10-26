/// RFC 7932 meta-block serialisation.
///
/// Two header flavours are supported, both from `c/enc/brotli_bit_stream.c`:
///
/// * **one literal tree** (`BrotliStoreMetaBlockTrivial`): the 13 zero bits
///   `NBLTYPESL/NBLTYPESI/NBLTYPESD = 0`, `NPOSTFIX = 0`, `NDIRECT = 0`,
///   literal context mode `LSB6`, `NTREESL-1 = 0`, `NTREESD-1 = 0`;
/// * **literal context modeling** (`BrotliStoreMetaBlock` with one block type):
///   context mode UTF-8, `NTREESL = 2 or 3`, an explicit 64-entry context map
///   (`EncodeContextMap`: varint, MTF, zero-run RLE, Huffman) and one literal
///   Huffman tree per context.
///
/// ```text
/// ISLAST (1) [ISEMPTY (1) when ISLAST] MNIBBLES-4 (2) MLEN-1 (mnibbles*4)
/// [ISUNCOMPRESSED (1) when !ISLAST]
/// NBLTYPESL (1) = 0, NBLTYPESI (1) = 0, NBLTYPESD (1) = 0   // varint(0)
/// NPOSTFIX (2) = 0, NDIRECT (4) = 0
/// literal context mode (2) = 0 (LSB6) or 2 (UTF-8)
/// NTREESL-1 (varint) = 0..2
/// [literal context map, when NTREESL > 1]
/// NTREESD-1 (varint) = 0
/// <NTREESL literal trees> <1 command tree> <1 distance tree>
/// command stream (see [storeCommands])
/// byte padding when ISLAST
/// ```
///
/// The 13 zero bits of the trivial header are exactly the fields above; that is
/// why the reference encoder can write them with a single `BrotliWriteBits(13,
/// 0)`.
library;

import 'dart:typed_data';

import '../common/bit_utils.dart';
import 'bit_writer.dart';
import 'command.dart';
import 'context_modeling.dart';
import 'distance_params.dart';
import 'huffman_encoder.dart';

/// Largest meta-block length allowed by RFC 7932.
const int kMaxMetaBlockLength = 1 << 24;

/// Maximum number of literal trees this writer can emit per meta-block.
const int kMaxLiteralTrees = 3;

/// Size of the context-map Huffman alphabet (`num_clusters + 6`).
const int _kContextMapAlphabetSize = kMaxLiteralTrees + 6;

/// `SYMBOL_BITS` of the packed context-map RLE symbols.
const int _kContextMapSymbolBits = 9;

/// Writes one *uncompressed* meta-block (`BrotliStoreUncompressedMetaBlock`).
///
/// An uncompressed block can never be the last block, so `ISLAST` is 0 and the
/// caller must finish the stream with an empty last block.
void writeUncompressedMetaBlock(
  BitWriter writer,
  Uint8List input,
  int start,
  int length,
) {
  assert(length > 0 && length <= kMaxMetaBlockLength);
  final mnibbles = mnibblesForLength(length);
  writer.writeBits(1, 0); // ISLAST = 0
  writer.writeBits(2, mnibbles - 4);
  writer.writeBits(mnibbles * 4, length - 1);
  writer.writeBits(1, 1); // ISUNCOMPRESSED = 1
  writer.alignToByte();
  writer.writeBytes(input, start, start + length);
}

/// Number of bits an uncompressed meta-block of [length] bytes occupies when
/// started at bit position [startBitPosition].
///
/// Used to decide whether a compressed block is actually smaller: the encoder
/// rewinds and stores the block uncompressed when it is not, which guarantees
/// that output never exceeds uncompressed framing.
int uncompressedMetaBlockBits(int length, [int startBitPosition = 0]) {
  final mnibbles = mnibblesForLength(length);
  final headerBits = 1 + 2 + mnibbles * 4 + 1;
  return alignToByte(startBitPosition + headerBits) -
      startBitPosition +
      length * 8;
}

/// Number of MLEN nibbles (4, 5 or 6) for a meta-block of [length] bytes.
int mnibblesForLength(int length) {
  assert(length > 0 && length <= kMaxMetaBlockLength);
  // BrotliEncodeMlen: lg = bit length of (length - 1), at least 1.
  final lg = length == 1 ? 1 : log2Floor(length - 1) + 1;
  return lg < 16 ? 4 : (lg + 3) ~/ 4;
}

/// Writes one compressed meta-block: header, Huffman trees and the command
/// stream.
///
/// All scratch buffers are owned by the instance, so encoding allocates
/// nothing per meta-block (the histograms are cleared in place).
final class MetaBlockWriter {
  MetaBlockWriter()
    : _huffman = HuffmanEncoder(),
      _commandHistogram = Uint32List(numCommandSymbols),
      _commandDepth = Uint8List(numCommandSymbols),
      _commandBits = Uint16List(numCommandSymbols),
      _rleSymbols = Uint32List(kNumLiteralContexts),
      _mtf = Uint8List(256),
      _maxRunLengthPrefix = Int32List(1);

  final HuffmanEncoder _huffman;
  // One histogram/tree per literal context; the complex 13-context model needs
  // more than kMaxLiteralTrees, so these grow on demand.
  Uint32List _literalHistogram = Uint32List(
    kMaxLiteralTrees * numLiteralSymbols,
  );
  final Uint32List _commandHistogram;
  // Distance histograms/trees can be wider than 64 symbols for large-window
  // streams, so they grow on demand (DistanceParams.alphabetSize).
  Uint32List _distanceHistogram = Uint32List(numDistanceSymbols);
  Uint8List _literalDepth = Uint8List(kMaxLiteralTrees * numLiteralSymbols);
  Uint16List _literalBits = Uint16List(kMaxLiteralTrees * numLiteralSymbols);
  final Uint8List _commandDepth;
  final Uint16List _commandBits;
  Uint8List _distanceDepth = Uint8List(numDistanceSymbols);
  Uint16List _distanceBits = Uint16List(numDistanceSymbols);

  // Context-map encoding scratch.
  // The context map alphabet is numClusters + RLE prefixes; the complex 13
  // context model exceeds _kContextMapAlphabetSize, so these grow on demand.
  Uint32List _contextMapHistogram = Uint32List(_kContextMapAlphabetSize);
  Uint8List _contextMapDepth = Uint8List(_kContextMapAlphabetSize);
  Uint16List _contextMapBits = Uint16List(_kContextMapAlphabetSize);
  final Uint32List _rleSymbols;
  final Uint8List _mtf;
  final Int32List _maxRunLengthPrefix;

  /// Writes the compressed meta-block for `input[start .. start + length)`.
  ///
  /// [commands] must describe exactly [length] bytes of input. When [isLast]
  /// the final `ISEMPTY` bit and byte padding are handled here.
  ///
  /// When [contexts] is non-null (and has more than one cluster) literals are
  /// coded with one tree per context selected by `contexts.contextMap`; the
  /// literal context mode written to the stream is UTF-8.
  void store(
    BitWriter writer,
    Uint8List input,
    int start,
    int length,
    CommandBuffer commands, {
    required bool isLast,
    LiteralContextModel? contexts,
    DistanceParams? distanceParams,
  }) {
    assert(length > 0 && length <= kMaxMetaBlockLength);
    final distanceAlphabet =
        (distanceParams ?? kDefaultDistanceParams).alphabetSize;
    if (_distanceHistogram.length < distanceAlphabet) {
      _distanceHistogram = Uint32List(distanceAlphabet);
      _distanceDepth = Uint8List(distanceAlphabet);
      _distanceBits = Uint16List(distanceAlphabet);
    }
    final model = (contexts != null && contexts.numClusters > 1)
        ? contexts
        : null;
    final literalTrees = model == null ? 1 : model.numClusters;
    if (_literalHistogram.length < literalTrees * numLiteralSymbols) {
      final size = literalTrees * numLiteralSymbols;
      _literalHistogram = Uint32List(size);
      _literalDepth = Uint8List(size);
      _literalBits = Uint16List(size);
    }

    final mnibbles = mnibblesForLength(length);
    writer.writeBits(1, isLast ? 1 : 0); // ISLAST
    if (isLast) writer.writeBits(1, 0); // ISEMPTY = 0
    writer.writeBits(2, mnibbles - 4);
    writer.writeBits(mnibbles * 4, length - 1);
    if (!isLast) writer.writeBits(1, 0); // ISUNCOMPRESSED = 0

    final numLiteralTrees = model == null ? 1 : model.numClusters;
    if (model == null) {
      // NBLTYPESL=0, NBLTYPESI=0, NBLTYPESD=0, NPOSTFIX=0, NDIRECT=0,
      // literal context mode=0 (LSB6), NTREESL-1=0, NTREESD-1=0.
      writer.writeBits(13, 0);
    } else {
      writer.writeBits(1, 0); // NBLTYPESL - 1
      writer.writeBits(1, 0); // NBLTYPESI - 1
      writer.writeBits(1, 0); // NBLTYPESD - 1
      writer.writeBits(2, 0); // NPOSTFIX
      writer.writeBits(4, 0); // NDIRECT
      writer.writeBits(2, kLiteralContextModeUtf8); // literal context mode
      // `EncodeContextMap` starts with the `NTREESL - 1` varint itself.
      _storeContextMap(writer, model.contextMap, numLiteralTrees);
      writer.writeBits(1, 0); // NTREESD - 1
    }

    _buildHistograms(input, start, length, commands, model);
    for (var tree = 0; tree < numLiteralTrees; tree++) {
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
    _huffman.buildAndStore(
      _commandHistogram,
      numCommandSymbols,
      numCommandSymbols,
      writer,
      _commandDepth,
      _commandBits,
    );
    _huffman.buildAndStore(
      _distanceHistogram,
      distanceAlphabet,
      distanceAlphabet,
      writer,
      _distanceDepth,
      _distanceBits,
    );

    _storeCommands(writer, input, start, length, commands, model);

    if (isLast) writer.alignToByte();
  }

  // -- header helpers ------------------------------------------------------

  /// `StoreVarLenUint8`: `0` as a single zero bit, else `1`, three bits of
  /// `log2(value)` and the remaining mantissa bits.
  void _storeVarLenUint8(BitWriter writer, int value) {
    if (value == 0) {
      writer.writeBits(1, 0);
      return;
    }
    final nbits = log2Floor(value);
    writer.writeBits(1, 1);
    writer.writeBits(3, nbits);
    writer.writeBits(nbits, value - (1 << nbits));
  }

  /// `EncodeContextMap`: MTF transform, zero-run RLE and the Huffman code that
  /// describes the resulting symbol stream.
  void _storeContextMap(
    BitWriter writer,
    Uint8List contextMap,
    int numClusters,
  ) {
    _storeVarLenUint8(writer, numClusters - 1);
    if (numClusters == 1) return;

    // Move-to-front transform (`MoveToFrontTransform`). The context map is
    // copied into the RLE scratch buffer first.
    var maxValue = 0;
    for (var i = 0; i < kNumLiteralContexts; i++) {
      final value = contextMap[i];
      _rleSymbols[i] = value;
      if (value > maxValue) maxValue = value;
    }
    final mtfSize = maxValue + 1;
    for (var i = 0; i < mtfSize; i++) {
      _mtf[i] = i;
    }
    for (var i = 0; i < kNumLiteralContexts; i++) {
      final value = _rleSymbols[i];
      var index = 0;
      while (_mtf[index] != value) {
        index++;
      }
      _rleSymbols[i] = index;
      final moved = _mtf[index];
      for (var k = index; k > 0; k--) {
        _mtf[k] = _mtf[k - 1];
      }
      _mtf[0] = moved;
    }

    _maxRunLengthPrefix[0] = 6;
    final numRleSymbols = _runLengthCodeZeros(_rleSymbols);
    final maxPrefix = _maxRunLengthPrefix[0];
    final alphabetSize = numClusters + maxPrefix;

    if (_contextMapHistogram.length < alphabetSize) {
      _contextMapHistogram = Uint32List(alphabetSize);
      _contextMapDepth = Uint8List(alphabetSize);
      _contextMapBits = Uint16List(alphabetSize);
    }
    final histogram = _contextMapHistogram;
    histogram.fillRange(0, histogram.length, 0);
    const symbolMask = (1 << _kContextMapSymbolBits) - 1;
    for (var i = 0; i < numRleSymbols; i++) {
      histogram[_rleSymbols[i] & symbolMask]++;
    }
    final useRle = maxPrefix > 0;
    writer.writeBits(1, useRle ? 1 : 0);
    if (useRle) writer.writeBits(4, maxPrefix - 1);
    _huffman.buildAndStore(
      histogram,
      alphabetSize,
      alphabetSize,
      writer,
      _contextMapDepth,
      _contextMapBits,
    );
    for (var i = 0; i < numRleSymbols; i++) {
      final packed = _rleSymbols[i];
      final symbol = packed & symbolMask;
      final extraBitsValue = packed >> _kContextMapSymbolBits;
      writer.writeBits(_contextMapDepth[symbol], _contextMapBits[symbol]);
      if (symbol > 0 && symbol <= maxPrefix) {
        writer.writeBits(symbol, extraBitsValue);
      }
    }
    writer.writeBits(1, 1); // use move-to-front
  }

  /// `RunLengthCodeZeros`: replaces zero runs of the MTF stream with prefix
  /// codes in place and returns the new length.
  ///
  /// A packed symbol is `prefix | (extra_bits << 9)`; non-zero MTF values are
  /// shifted up by `max_run_length_prefix`.
  int _runLengthCodeZeros(Uint32List values) {
    const inSize = kNumLiteralContexts;
    var maxReps = 0;
    var i = 0;
    while (i < inSize) {
      var reps = 0;
      while (i < inSize && values[i] != 0) {
        i++;
      }
      while (i < inSize && values[i] == 0) {
        i++;
        reps++;
      }
      if (reps > maxReps) maxReps = reps;
    }
    var maxPrefix = maxReps > 0 ? log2Floor(maxReps) : 0;
    if (maxPrefix > _maxRunLengthPrefix[0]) {
      maxPrefix = _maxRunLengthPrefix[0];
    }
    _maxRunLengthPrefix[0] = maxPrefix;

    var outSize = 0;
    i = 0;
    while (i < inSize) {
      if (values[i] != 0) {
        values[outSize] = values[i] + maxPrefix;
        i++;
        outSize++;
        continue;
      }
      var reps = 1;
      for (var k = i + 1; k < inSize && values[k] == 0; k++) {
        reps++;
      }
      i += reps;
      while (reps != 0) {
        if (reps < (2 << maxPrefix)) {
          final runLengthPrefix = log2Floor(reps);
          final extraBits = reps - (1 << runLengthPrefix);
          values[outSize] = runLengthPrefix + (extraBits << 9);
          outSize++;
          break;
        } else {
          final extraBits = (1 << maxPrefix) - 1;
          values[outSize] = maxPrefix + (extraBits << 9);
          reps -= (2 << maxPrefix) - 1;
          outSize++;
        }
      }
    }
    return outSize;
  }

  // -- histograms and symbol stream ---------------------------------------

  void _buildHistograms(
    Uint8List input,
    int start,
    int length,
    CommandBuffer commands,
    LiteralContextModel? model,
  ) {
    _literalHistogram.fillRange(0, _literalHistogram.length, 0);
    _commandHistogram.fillRange(0, _commandHistogram.length, 0);
    _distanceHistogram.fillRange(0, _distanceHistogram.length, 0);

    var pos = start;
    if (model == null) {
      for (var i = 0; i < commands.count; i++) {
        final insertLen = commands.insertLen[i];
        final copyLen = commands.copyLen[i];
        final cmdPrefix = commands.cmdPrefix[i];
        _commandHistogram[cmdPrefix]++;
        for (var j = 0; j < insertLen; j++) {
          _literalHistogram[input[pos++]]++;
        }
        pos += copyLen;
        if (copyLen != 0 && cmdPrefix >= 128) {
          _distanceHistogram[commands.distPrefix[i] & 0x3FF]++;
        }
      }
    } else {
      final map = model.contextMap;
      for (var i = 0; i < commands.count; i++) {
        final insertLen = commands.insertLen[i];
        final copyLen = commands.copyLen[i];
        final cmdPrefix = commands.cmdPrefix[i];
        _commandHistogram[cmdPrefix]++;
        for (var j = 0; j < insertLen; j++) {
          final tree = map[literalContextId(input, pos)] * numLiteralSymbols;
          _literalHistogram[tree + input[pos]]++;
          pos++;
        }
        pos += copyLen;
        if (copyLen != 0 && cmdPrefix >= 128) {
          _distanceHistogram[commands.distPrefix[i] & 0x3FF]++;
        }
      }
    }
    assert(pos == start + length, 'command stream covers the whole block');
  }

  void _storeCommands(
    BitWriter writer,
    Uint8List input,
    int start,
    int length,
    CommandBuffer commands,
    LiteralContextModel? model,
  ) {
    final map = model?.contextMap;
    var pos = start;
    for (var i = 0; i < commands.count; i++) {
      final cmdPrefix = commands.cmdPrefix[i];
      final insertLen = commands.insertLen[i];
      final copyLen = commands.copyLen[i];

      writer.writeBits(_commandDepth[cmdPrefix], _commandBits[cmdPrefix]);

      // Insert extra bits, then copy extra bits (StoreCommandExtra). The
      // reference writes them as one wide value; splitting keeps every write
      // at most 24 bits and is bit-identical LSB-first.
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

      if (map == null) {
        for (var j = 0; j < insertLen; j++) {
          final literal = input[pos++];
          writer.writeBits(_literalDepth[literal], _literalBits[literal]);
        }
      } else {
        for (var j = 0; j < insertLen; j++) {
          final tree = map[literalContextId(input, pos)] * numLiteralSymbols;
          final literal = input[pos++];
          final index = tree + literal;
          writer.writeBits(_literalDepth[index], _literalBits[index]);
        }
      }

      if (copyLen != 0) {
        pos += copyLen;
        if (cmdPrefix >= 128) {
          // Distance symbol is command-dependent: copy lengths 2..4 encode a
          // distance context but every context maps to the same tree here.
          final distPrefix = commands.distPrefix[i];
          final distanceSymbol = distPrefix & 0x3FF;
          final extraBits = distPrefix >> 10;
          writer.writeBits(
            _distanceDepth[distanceSymbol],
            _distanceBits[distanceSymbol],
          );
          if (extraBits != 0) {
            writer.writeBits(extraBits, commands.distExtra[i]);
          }
        }
      }
    }
    assert(pos == start + length, 'command stream covers the whole block');
  }
}
