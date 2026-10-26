/// Context-map serialisation helpers shared by the meta-block writers.
///
/// These are the bit-level primitives of `c/enc/brotli_bit_stream.c`:
///
/// * [storeVarLenUint8] - `StoreVarLenUint8`;
/// * [ContextMapEncoder] - `EncodeContextMap`: the number of trees as a varint,
///   then (for more than one tree) a move-to-front transformed map whose zero
///   runs are RLE-coded (`RunLengthCodeZeros`), described by its own Huffman
///   code, followed by the inverse-MTF flag;
/// * [storeTrivialContextMap] - `StoreTrivialContextMap`: the implicit map used
///   for distance contexts, where block type `i` maps to histogram `i`.
///
/// The encoder writes the *number of Huffman trees* as part of the context map
/// (there is no separate `NTREESL` field), which is easy to get wrong.
library;

import 'dart:typed_data';

import '../common/bit_utils.dart';
import 'bit_writer.dart';
import 'context_modeling.dart';
import 'huffman_encoder.dart';

/// Number of literal contexts per block type (`1 << kLiteralContextBits`).
const int kContextMapSize = kNumLiteralContexts;

/// `SYMBOL_BITS` of the packed context-map RLE symbols.
const int _kContextMapSymbolBits = 9;

/// Initial size of the context-map Huffman alphabet buffers.
///
/// The buffers grow on demand: with block splitting the literal context map can
/// reference many more than three trees.
const int kContextMapMaxAlphabet = 3 + 6;

/// `StoreVarLenUint8`: `0` as a single zero bit, else `1`, three bits of
/// `log2(value)` and the remaining mantissa bits.
void storeVarLenUint8(BitWriter writer, int value) {
  if (value == 0) {
    writer.writeBits(1, 0);
    return;
  }
  final nbits = log2Floor(value);
  writer.writeBits(1, 1);
  writer.writeBits(3, nbits);
  writer.writeBits(nbits, value - (1 << nbits));
}

/// Encodes 64-entry context maps (`EncodeContextMap`).
final class ContextMapEncoder {
  /// Creates an encoder that borrows [huffman] for tree serialisation.
  ContextMapEncoder(this._huffman)
    : _histogram = Uint32List(kContextMapMaxAlphabet),
      _depth = Uint8List(kContextMapMaxAlphabet),
      _bits = Uint16List(kContextMapMaxAlphabet),
      _mtf = Uint8List(256),
      _maxRunLengthPrefix = Int32List(1);

  final HuffmanEncoder _huffman;
  Uint32List _histogram;
  Uint8List _depth;
  Uint16List _bits;
  Uint32List _rleSymbols = Uint32List(kContextMapSize);
  final Uint8List _mtf;
  final Int32List _maxRunLengthPrefix;

  /// Writes the context map [contextMap] (`contextMap.length` entries) that
  /// selects one of [numClusters] Huffman trees.
  void store(BitWriter writer, Uint8List contextMap, int numClusters) {
    final required = numClusters + 6;
    if (_histogram.length < required) {
      _histogram = Uint32List(required);
      _depth = Uint8List(required);
      _bits = Uint16List(required);
    }
    storeVarLenUint8(writer, numClusters - 1);
    if (numClusters == 1) return;
    final size = contextMap.length;
    if (_rleSymbols.length < size) {
      _rleSymbols = Uint32List(size);
    }

    // Move-to-front transform (MoveToFrontTransform).
    var maxValue = 0;
    for (var i = 0; i < size; i++) {
      final value = contextMap[i];
      _rleSymbols[i] = value;
      if (value > maxValue) maxValue = value;
    }
    final mtfSize = maxValue + 1;
    for (var i = 0; i < mtfSize; i++) {
      _mtf[i] = i;
    }
    for (var i = 0; i < size; i++) {
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
    final numRleSymbols = _runLengthCodeZeros(_rleSymbols, size);
    final maxPrefix = _maxRunLengthPrefix[0];
    final alphabetSize = numClusters + maxPrefix;

    _histogram.fillRange(0, _histogram.length, 0);
    const symbolMask = (1 << _kContextMapSymbolBits) - 1;
    for (var i = 0; i < numRleSymbols; i++) {
      _histogram[_rleSymbols[i] & symbolMask]++;
    }
    final useRle = maxPrefix > 0;
    writer.writeBits(1, useRle ? 1 : 0);
    if (useRle) writer.writeBits(4, maxPrefix - 1);
    _huffman.buildAndStore(
      _histogram,
      alphabetSize,
      alphabetSize,
      writer,
      _depth,
      _bits,
    );
    for (var i = 0; i < numRleSymbols; i++) {
      final packed = _rleSymbols[i];
      final symbol = packed & symbolMask;
      final extraBitsValue = packed >> _kContextMapSymbolBits;
      writer.writeBits(_depth[symbol], _bits[symbol]);
      if (symbol > 0 && symbol <= maxPrefix) {
        writer.writeBits(symbol, extraBitsValue);
      }
    }
    writer.writeBits(1, 1); // use move-to-front
  }

  /// `RunLengthCodeZeros`: replaces zero runs of the MTF stream in place.
  int _runLengthCodeZeros(Uint32List values, int inSize) {
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
}

/// `StoreTrivialContextMap`: block type `i` maps to histogram `i`.
///
/// The map covers `numTypes << contextBits` entries. The intermediate values
/// are written MTF-transformed (that is what the final inverse-MTF flag says).
void storeTrivialContextMap(
  BitWriter writer,
  HuffmanEncoder huffman,
  int numTypes,
  int contextBits,
) {
  storeVarLenUint8(writer, numTypes - 1);
  if (numTypes <= 1) return;
  final repeatCode = contextBits - 1;
  final repeatBits = (1 << repeatCode) - 1;
  final alphabetSize = numTypes + repeatCode;
  final histogram = Uint32List(alphabetSize);
  final depth = Uint8List(alphabetSize);
  final bits = Uint16List(alphabetSize);
  // Write RLEMAX.
  writer.writeBits(1, 1);
  writer.writeBits(4, repeatCode - 1);
  histogram[repeatCode] = numTypes;
  histogram[0] = 1;
  for (var i = contextBits; i < alphabetSize; i++) {
    histogram[i] = 1;
  }
  huffman.buildAndStore(
    histogram,
    alphabetSize,
    alphabetSize,
    writer,
    depth,
    bits,
  );
  for (var i = 0; i < numTypes; i++) {
    final code = i == 0 ? 0 : i + contextBits - 1;
    writer.writeBits(depth[code], bits[code]);
    writer.writeBits(depth[repeatCode], bits[repeatCode]);
    writer.writeBits(repeatCode, repeatBits);
  }
  writer.writeBits(1, 1); // inverse move-to-front
}
