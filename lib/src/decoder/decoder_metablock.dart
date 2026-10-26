/// Compressed-metablock decoder.
///
/// Port of the compressed-block parts of `Decode.java`:
/// `readMetablockHuffmanCodesAndContextMaps`, `decodeContextMap`,
/// `decodeBlockTypeAndLength`, the literal/command/distance block switches,
/// `decodeVarLenUnsignedByte`, `calculateDistanceLut`, `doUseDictionary` and the
/// main/insert/copy loops of `decompress`.
///
/// Structure:
///
/// * The header parser is a *resumable step machine* ([DecoderState.headerStep])
///   rather than one big memento. Only a single Huffman code description is
///   ever wrapped in a [BitReaderMemento], because that is the only operation
///   that can consume bits and then fail. Context-map RLE decoding, context
///   modes and the tree-group loops keep their cursors in [DecoderState] and
///   call `refill()` at the top of each loop, so a header of any size can be
///   suspended and restarted.
/// * The hot loops (`mainLoop`, `insertLoop`, `readDistance`, `copyLoop`)
///   follow Java's state machine, but distance resolution lives in its own
///   phase so that suspending there cannot repeat the metablock accounting.
/// * Every loop flushes through [DecodePhase.initWrite] / [DecodePhase.write]
///   when `pos >= fence`, exactly like the reference.
///
/// The static dictionary (RFC 7932 §8) and the optional caller-attached
/// compound ("shared"/prepended) dictionary are resolved in
/// [_applyDictionaryReference]: a distance larger than `maxDistance` is either a
/// compound-dictionary copy (when a dictionary is attached and the distance
/// addresses it) or a static-dictionary word. When a serialized shared
/// dictionary with custom word/transform lists is attached, the word comes from
/// [_applyCustomDictionaryReference] instead of the built-in table.
library;

import 'dart:typed_data';

import '../common/context_lookup.dart';
import '../common/dictionary.dart' as dictionary;
import '../common/dictionary_data.dart'
    show kDictionaryData, kDictionarySizeBitsByLength;
import '../common/errors.dart';
import '../common/format_tables.dart';
import '../common/transforms.dart' as transforms;
import '../options.dart';
import 'bit_reader.dart';
import 'decoder_state.dart';
import 'huffman_decoder.dart';
import 'shared_dictionary.dart';
import 'wide_copy.dart';

// ---------------------------------------------------------------------------
// Entry points used by the state machine in decoder_core.dart.
// ---------------------------------------------------------------------------

/// Shortest static-dictionary word (`sizeBits[4] != 0`).
const int minDictionaryWordLength = 4;

/// Longest static-dictionary word.
const int maxDictionaryWordLength = 24;

/// Number of RFC 7932 word transforms.
const int numRfcTransforms = 121;

/// Parses the compressed-metablock header and sets [DecoderState.phase] to
/// [DecodePhase.mainLoop] on success.
///
/// Returns [BrotliStatus.needMoreInput] when the reader must be refilled; the
/// parser is fully resumable, so the caller can simply call again later.
BrotliStatus? decodeCompressedMetablockHeader(
  BitReader reader,
  DecoderState state,
) {
  for (;;) {
    switch (state.headerStep) {
      // -- NBLTYPES / block type + block length trees (three partitions) -----
      case 0:
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        state.ensureBlockTrees();
        state.blockTrees[0] = 7;
        state.numLiteralBlockTypes = _readVarLenUnsignedByte(reader) + 1;
        state.headerNext = 7;
        state.headerStep = 1;
        break;

      case 1:
        if (state.numLiteralBlockTypes <= 1) {
          state.blockTrees[1] = state.blockTrees[0];
          state.blockTrees[2] = state.blockTrees[0];
          state.literalBlockLength = 1 << 28;
          state.headerStep = 4;
          break;
        }
        final literalAlphabet = state.numLiteralBlockTypes + 2;
        final literalTypeUsed = _tryHuffmanCode(
          reader,
          literalAlphabet,
          literalAlphabet,
          state.blockTrees,
          0,
        );
        if (literalTypeUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext += literalTypeUsed;
        state.blockTrees[1] = state.headerNext;
        state.headerStep = 2;
        break;

      case 2:
        final literalLengthUsed = _tryHuffmanCode(
          reader,
          numBlockLengthCodes,
          numBlockLengthCodes,
          state.blockTrees,
          1,
        );
        if (literalLengthUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext += literalLengthUsed;
        state.blockTrees[2] = state.headerNext;
        state.headerStep = 3;
        break;

      case 3:
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        state.literalBlockLength = readBlockLength(state.blockTrees, 1, reader);
        state.headerStep = 4;
        break;

      case 4:
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        state.numCommandBlockTypes = _readVarLenUnsignedByte(reader) + 1;
        state.headerStep = 5;
        break;

      case 5:
        if (state.numCommandBlockTypes <= 1) {
          state.blockTrees[3] = state.blockTrees[2];
          state.blockTrees[4] = state.blockTrees[2];
          state.commandBlockLength = 1 << 28;
          state.headerStep = 8;
          break;
        }
        final commandAlphabet = state.numCommandBlockTypes + 2;
        final commandTypeUsed = _tryHuffmanCode(
          reader,
          commandAlphabet,
          commandAlphabet,
          state.blockTrees,
          2,
        );
        if (commandTypeUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext = state.blockTrees[2] + commandTypeUsed;
        state.blockTrees[3] = state.headerNext;
        state.headerStep = 6;
        break;

      case 6:
        final commandLengthUsed = _tryHuffmanCode(
          reader,
          numBlockLengthCodes,
          numBlockLengthCodes,
          state.blockTrees,
          3,
        );
        if (commandLengthUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext += commandLengthUsed;
        state.blockTrees[4] = state.headerNext;
        state.headerStep = 7;
        break;

      case 7:
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        state.commandBlockLength = readBlockLength(state.blockTrees, 3, reader);
        state.headerStep = 8;
        break;

      case 8:
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        state.numDistanceBlockTypes = _readVarLenUnsignedByte(reader) + 1;
        state.headerStep = 9;
        break;

      case 9:
        if (state.numDistanceBlockTypes <= 1) {
          state.blockTrees[5] = state.blockTrees[4];
          state.blockTrees[6] = state.blockTrees[4];
          state.distanceBlockLength = 1 << 28;
          state.headerStep = 12;
          break;
        }
        final distanceAlphabet = state.numDistanceBlockTypes + 2;
        final distanceTypeUsed = _tryHuffmanCode(
          reader,
          distanceAlphabet,
          distanceAlphabet,
          state.blockTrees,
          4,
        );
        if (distanceTypeUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext = state.blockTrees[4] + distanceTypeUsed;
        state.blockTrees[5] = state.headerNext;
        state.headerStep = 10;
        break;

      case 10:
        final distanceLengthUsed = _tryHuffmanCode(
          reader,
          numBlockLengthCodes,
          numBlockLengthCodes,
          state.blockTrees,
          5,
        );
        if (distanceLengthUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext += distanceLengthUsed;
        state.blockTrees[6] = state.headerNext;
        state.headerStep = 11;
        break;

      case 11:
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        state.distanceBlockLength = readBlockLength(
          state.blockTrees,
          5,
          reader,
        );
        state.headerStep = 12;
        break;

      // -- distance parameters ----------------------------------------------
      case 12:
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        reader.fillBitWindow();
        state.distancePostfixBits = reader.readFewBits(2);
        state.numDirectDistanceCodes =
            reader.readFewBits(4) << state.distancePostfixBits;
        state.headerStep = 13;
        break;

      // -- literal context modes --------------------------------------------
      case 13:
        final contextModeCount = state.numLiteralBlockTypes;
        if (state.contextModes.length < contextModeCount) {
          state.contextModes = Uint8List(contextModeCount);
        }
        state.headerIndex = 0;
        state.headerStep = 14;
        break;

      case 14:
        if (state.headerIndex >= state.numLiteralBlockTypes) {
          state.headerStep = 15;
          break;
        }
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        final modeLimit = _min(
          state.headerIndex + 96,
          state.numLiteralBlockTypes,
        );
        while (state.headerIndex < modeLimit) {
          reader.fillBitWindow();
          state.contextModes[state.headerIndex] = reader.readFewBits(2);
          state.headerIndex++;
        }
        break;

      // -- literal context map ----------------------------------------------
      case 15:
        final startStatus = _startContextMap(reader, state, false);
        if (startStatus != null) {
          return startStatus;
        }
        if (state.contextMapNumTrees == 1) {
          state.numLiteralTrees = 1;
          state.headerStep = 20;
        } else {
          state.headerStep = 19;
        }
        break;

      case 19:
        // Zero-RLE parameters are read in their own step so a suspension while
        // reading the context-map Huffman code (step 16) can be retried without
        // re-reading these bits.
        final rleStatus = _readContextMapRleParams(reader, state);
        if (rleStatus != null) {
          return rleStatus;
        }
        state.headerStep = 16;
        break;

      case 16:
        final treeStatus = _readContextMapTree(reader, state);
        if (treeStatus != null) {
          return treeStatus;
        }
        state.headerStep = 17;
        break;

      case 17:
        final symbolStatus = _readContextMapSymbols(reader, state, false);
        if (symbolStatus != null) {
          return symbolStatus;
        }
        state.headerStep = 18;
        break;

      case 18:
        final finishStatus = _finishContextMap(reader, state, false);
        if (finishStatus != null) {
          return finishStatus;
        }
        state.numLiteralTrees = state.contextMapNumTrees;
        state.trivialLiteralContext = true;
        final literalMapSize = state.contextMapSize;
        for (var i = 0; i < literalMapSize; i++) {
          if ((state.contextMap[i] & 0xFF) != (i >> numLiteralContextBits)) {
            state.trivialLiteralContext = false;
            break;
          }
        }
        state.headerStep = 20;
        break;

      // -- distance context map ---------------------------------------------
      case 20:
        final startStatus = _startContextMap(reader, state, true);
        if (startStatus != null) {
          return startStatus;
        }
        if (state.contextMapNumTrees == 1) {
          state.numDistTrees = 1;
          state.headerStep = 25;
        } else {
          state.headerStep = 24;
        }
        break;

      case 24:
        final rleStatus = _readContextMapRleParams(reader, state);
        if (rleStatus != null) {
          return rleStatus;
        }
        state.headerStep = 21;
        break;

      case 21:
        final treeStatus = _readContextMapTree(reader, state);
        if (treeStatus != null) {
          return treeStatus;
        }
        state.headerStep = 22;
        break;

      case 22:
        final symbolStatus = _readContextMapSymbols(reader, state, true);
        if (symbolStatus != null) {
          return symbolStatus;
        }
        state.headerStep = 23;
        break;

      case 23:
        final finishStatus = _finishContextMap(reader, state, true);
        if (finishStatus != null) {
          return finishStatus;
        }
        state.numDistTrees = state.contextMapNumTrees;
        state.headerStep = 25;
        break;

      // -- three Huffman tree groups ----------------------------------------
      case 25:
        var distanceAlphabetSizeMax = distanceAlphabetSize(
          state.distancePostfixBits,
          state.numDirectDistanceCodes,
          maxDistanceBits,
        );
        var distanceLimit = distanceAlphabetSizeMax;
        if (state.largeWindow) {
          // Large-window streams may encode up to 62 distance extra bits; only
          // the codes that MAX_ALLOWED_DISTANCE can reach are actually used.
          distanceAlphabetSizeMax = distanceAlphabetSize(
            state.distancePostfixBits,
            state.numDirectDistanceCodes,
            maxLargeWindowDistanceBits,
          );
          final computed = distanceAlphabetLimit(
            maxAllowedDistance,
            state.distancePostfixBits,
            state.numDirectDistanceCodes,
          );
          if (computed < 0) {
            throw BrotliException(
              BrotliErrorCode.internalError,
              'maximum backward distance is too small for the distance alphabet',
            );
          }
          distanceLimit = computed;
        }
        state.distanceAlphabetSizeMax = distanceAlphabetSizeMax;
        state.distanceAlphabetSizeLimit = distanceLimit;
        state.distExtraBits = _ensureBytes(
          state.distExtraBits,
          state.distanceAlphabetSizeLimit,
        );
        state.distOffset = _ensureInt32(
          state.distOffset,
          state.distanceAlphabetSizeLimit,
        );
        state.literalTreeGroup = _ensureUint32(
          state.literalTreeGroup,
          _treeGroupLength(numLiteralCodes, state.numLiteralTrees),
        );
        state.headerIndex = 0;
        state.headerNext = state.numLiteralTrees;
        state.headerStep = 26;
        break;

      case 26:
        if (state.headerIndex >= state.numLiteralTrees) {
          state.commandTreeGroup = _ensureUint32(
            state.commandTreeGroup,
            _treeGroupLength(numCommandCodes, state.numCommandBlockTypes),
          );
          state.headerIndex = 0;
          state.headerNext = state.numCommandBlockTypes;
          state.headerStep = 27;
          break;
        }
        final literalIndex = state.headerIndex;
        state.literalTreeGroup[literalIndex] = state.headerNext;
        final literalUsed = _tryHuffmanCode(
          reader,
          numLiteralCodes,
          numLiteralCodes,
          state.literalTreeGroup,
          literalIndex,
        );
        if (literalUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext += literalUsed;
        state.headerIndex = literalIndex + 1;
        break;

      case 27:
        if (state.headerIndex >= state.numCommandBlockTypes) {
          state.distanceTreeGroup = _ensureUint32(
            state.distanceTreeGroup,
            _treeGroupLength(
              state.distanceAlphabetSizeLimit,
              state.numDistTrees,
            ),
          );
          state.headerIndex = 0;
          state.headerNext = state.numDistTrees;
          state.headerStep = 28;
          break;
        }
        final commandIndex = state.headerIndex;
        state.commandTreeGroup[commandIndex] = state.headerNext;
        final commandUsed = _tryHuffmanCode(
          reader,
          numCommandCodes,
          numCommandCodes,
          state.commandTreeGroup,
          commandIndex,
        );
        if (commandUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext += commandUsed;
        state.headerIndex = commandIndex + 1;
        break;

      case 28:
        if (state.headerIndex >= state.numDistTrees) {
          state.headerStep = 29;
          break;
        }
        final distanceIndex = state.headerIndex;
        state.distanceTreeGroup[distanceIndex] = state.headerNext;
        final distanceUsed = _tryHuffmanCode(
          reader,
          state.distanceAlphabetSizeMax,
          state.distanceAlphabetSizeLimit,
          state.distanceTreeGroup,
          distanceIndex,
        );
        if (distanceUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext += distanceUsed;
        state.headerIndex = distanceIndex + 1;
        break;

      case 29:
        _fillDistanceLut(state);
        state.contextMapSlice = 0;
        state.distContextMapSlice = 0;
        state.contextLookupOffset1 = (state.contextModes[0] & 0xFF) << 9;
        state.contextLookupOffset2 = state.contextLookupOffset1 + 256;
        state.literalTreeIdx = 0;
        _updateLiteralBlockTrivial(state);
        state.commandTreeIdx = 0;
        state.rings[4] = 1;
        state.rings[5] = 0;
        state.rings[6] = 1;
        state.rings[7] = 0;
        state.rings[8] = 1;
        state.rings[9] = 0;
        state.headerStep = 0;
        state.phase = DecodePhase.mainLoop;
        return null;

      default:
        throw BrotliException(
          BrotliErrorCode.internalError,
          'unexpected compressed-header step ${state.headerStep}',
        );
    }
  }
}

/// Decodes one command and switches to the literal insertion phase.
BrotliStatus? decodeMainLoop(BitReader reader, DecoderState state) {
  if (state.metaBlockLength <= 0) {
    state.phase = DecodePhase.blockStart;
    return null;
  }
  if (!reader.refill()) {
    return BrotliStatus.needMoreInput;
  }
  if (state.commandBlockLength == 0) {
    state.commandBlockLength = _decodeBlockTypeAndLength(
      reader,
      state,
      1,
      state.numCommandBlockTypes,
    );
    state.commandTreeIdx = state.rings[7];
  }
  state.commandBlockLength--;

  reader.fillBitWindow();
  final commandCode =
      readSymbol(state.commandTreeGroup, state.commandTreeIdx, reader) << 2;
  final extraBitsPacked = commandLookup[commandCode];
  final insertLengthOffset = commandLookup[commandCode + 1];
  final copyLengthOffset = commandLookup[commandCode + 2];
  final distanceContext = commandLookup[commandCode + 3];

  reader.fillBitWindow();
  state.insertLength =
      insertLengthOffset + reader.readBits(extraBitsPacked & 0xFF);
  reader.fillBitWindow();
  state.copyLength = copyLengthOffset + reader.readBits(extraBitsPacked >> 8);

  state.implicitDistance = distanceContext < 0;
  state.distanceContext = state.implicitDistance ? 0 : distanceContext;
  state.j = 0;
  state.phase = DecodePhase.insertLoop;
  return null;
}

/// Emits the inserted literals of the current command.
BrotliStatus? decodeInsertLoop(BitReader reader, DecoderState state) {
  final fence = state.calculateFence();
  if (state.trivialLiteralContext) {
    while (state.j < state.insertLength) {
      if (!reader.refill()) {
        return BrotliStatus.needMoreInput;
      }
      if (state.literalBlockLength == 0) {
        _literalBlockSwitch(reader, state);
      }
      state.literalBlockLength--;
      reader.fillBitWindow();
      state.ringBuffer[state.pos] = readSymbol(
        state.literalTreeGroup,
        state.literalTreeIdx,
        reader,
      );
      state.pos++;
      state.j++;
      if (state.pos >= fence) {
        state.nextPhase = DecodePhase.insertLoop;
        state.phase = DecodePhase.initWrite;
        return null;
      }
    }
  } else {
    final ring = state.ringBuffer;
    final mask = state.ringBufferMask;
    var prevByte1 = ring[(state.pos - 1) & mask] & 0xFF;
    var prevByte2 = ring[(state.pos - 2) & mask] & 0xFF;
    while (state.j < state.insertLength) {
      if (!reader.refill()) {
        return BrotliStatus.needMoreInput;
      }
      if (state.literalBlockLength == 0) {
        _literalBlockSwitch(reader, state);
      }
      final literalContext =
          kContextLookupTable[state.contextLookupOffset1 + prevByte1] |
          kContextLookupTable[state.contextLookupOffset2 + prevByte2];
      final literalTreeIdx =
          state.contextMap[state.contextMapSlice + literalContext] & 0xFF;
      state.literalBlockLength--;
      prevByte2 = prevByte1;
      reader.fillBitWindow();
      prevByte1 = readSymbol(state.literalTreeGroup, literalTreeIdx, reader);
      ring[state.pos] = prevByte1;
      state.pos++;
      state.j++;
      if (state.pos >= fence) {
        state.nextPhase = DecodePhase.insertLoop;
        state.phase = DecodePhase.initWrite;
        return null;
      }
    }
  }

  state.metaBlockLength -= state.insertLength;
  if (state.metaBlockLength <= 0) {
    state.phase = DecodePhase.mainLoop;
    return null;
  }
  state.phase = DecodePhase.readDistance;
  return null;
}

/// Resolves the distance of the current command (idempotent on suspension).
BrotliStatus? decodeDistance(BitReader reader, DecoderState state) {
  if (!reader.refill()) {
    return BrotliStatus.needMoreInput;
  }
  var distanceSymbol = 0;
  if (state.implicitDistance) {
    state.distance = state.rings[state.distRbIdx];
  } else {
    if (state.distanceBlockLength == 0) {
      state.distanceBlockLength = _decodeBlockTypeAndLength(
        reader,
        state,
        2,
        state.numDistanceBlockTypes,
      );
      state.distContextMapSlice = state.rings[9] << numDistanceContextBits;
    }
    state.distanceBlockLength--;

    final distanceTreeIdx =
        state.distContextMap[state.distContextMapSlice +
            state.distanceContext] &
        0xFF;
    reader.fillBitWindow();
    distanceSymbol = readSymbol(
      state.distanceTreeGroup,
      distanceTreeIdx,
      reader,
    );
    if (distanceSymbol < numDistanceShortCodes) {
      final ringIndex =
          (state.distRbIdx + distanceShortCodeIndexOffset[distanceSymbol]) & 3;
      state.distance =
          state.rings[ringIndex] + distanceShortCodeValueOffset[distanceSymbol];
    } else {
      final extraBits = state.distExtraBits[distanceSymbol];
      reader.fillBitWindow();
      final bits = reader.readBits(extraBits);
      state.distance =
          state.distOffset[distanceSymbol] +
          (bits << state.distancePostfixBits);
    }
  }

  if (state.distance <= 0 || state.distance > maxAllowedDistance) {
    throw BrotliException(
      BrotliErrorCode.invalidDistance,
      'invalid backward reference distance ${state.distance}',
      inputOffset: reader.bytesConsumed,
    );
  }

  if (state.maxDistance != state.maxBackwardDistance &&
      state.pos < state.maxBackwardDistance) {
    state.maxDistance = state.pos;
  } else {
    state.maxDistance = state.maxBackwardDistance;
  }

  if (state.distance > state.maxDistance) {
    // Static- or compound-dictionary reference. The distance ring is rolled
    // only for compound copies (inside the helper), never for static words
    // (Java model; RFC sec. 8).
    _applyDictionaryReference(reader, state);
    return null;
  }

  if (distanceSymbol > 0) {
    state.distRbIdx = (state.distRbIdx + 1) & 3;
    state.rings[state.distRbIdx] = state.distance;
  }
  if (state.copyLength > state.metaBlockLength) {
    throw BrotliException(
      BrotliErrorCode.invalidDistance,
      'copy length ${state.copyLength} overruns the metablock '
      '(${state.metaBlockLength} bytes left)',
      inputOffset: reader.bytesConsumed,
    );
  }
  state.j = 0;
  state.phase = DecodePhase.copyLoop;
  return null;
}

/// Whether [distance] addresses the attached compound dictionary.
///
/// Distances in `(maxDistance, maxDistance + compoundSize]` are compound
/// references; larger distances address the RFC static dictionary.
bool isCompoundDictionaryDistance(
  int distance,
  int maxDistance,
  int compoundSize,
) {
  return distance > maxDistance && distance - maxDistance <= compoundSize;
}

/// Static-dictionary word address for a dictionary-range [distance].
///
/// The compound dictionary occupies the first `compoundSize` addresses, so the
/// RFC 7932 word address is shifted down by that size. The result is
/// non-negative exactly when [isCompoundDictionaryDistance] is `false`.
int staticDictionaryAddress(int distance, int maxDistance, int compoundSize) {
  return distance - maxDistance - 1 - compoundSize;
}

/// Resolves a distance past `maxDistance`: compound dictionary or static word.
///
/// Compound addressing (non-RFC extension, compatible with Rust
/// `brotli-decompressor` and `brotli --dictionary`):
/// * distances in `(maxDistance, maxDistance + dictionary.length]` address the
///   attached dictionary, furthest byte first:
///   `address = dictionary.length - (distance - maxDistance)`;
/// * `copyLength` raw bytes are copied from `address`; the copy may span ring
///   flushes and is resumed in [decodeCompoundDictionaryCopy].
///
/// Static addressing (RFC 7932 §8), for larger distances:
/// * `wordAddress = staticDictionaryAddress(distance, maxDistance, size)`;
/// * the word is selected and transformed by
///   [_applyStaticDictionaryReference].
void _applyDictionaryReference(BitReader reader, DecoderState state) {
  final compoundSize = state.compoundDictionarySize;
  if (isCompoundDictionaryDistance(
    state.distance,
    state.maxDistance,
    compoundSize,
  )) {
    final address = compoundSize - (state.distance - state.maxDistance);
    _applyCompoundDictionaryReference(reader, state, address);
    return;
  }
  final shared = state.sharedDictionary;
  if (shared != null && shared.isCustom) {
    _applyCustomDictionaryReference(reader, state, shared, compoundSize);
    return;
  }
  _applyStaticDictionaryReference(reader, state, compoundSize);
}

/// Literal context (LSB6 mode) used by context-based custom dictionaries.
int _dictionaryContext(DecoderState state) {
  final ring = state.ringBuffer;
  final mask = state.ringBufferMask;
  final p1 = ring[(state.pos - 1) & mask] & 0xFF;
  final p2 = ring[(state.pos - 2) & mask] & 0xFF;
  return (kContextLookupTable[p1] | kContextLookupTable[p2 + 256]) & 0xFF;
}

/// Resolves one static-dictionary reference through a serialized shared
/// dictionary's custom word/transform lists.
///
/// Port of the `s.dictionary.is_custom()` branch of the Rust/C decoder:
/// * the dictionary id is `0` unless the container enables the 64-entry literal
///   context map;
/// * `address = distance - maxDistance - 1 - compoundSize` indexes the flat
///   per-dictionary address space (multi-dictionary rescan included, see
///   [SharedDictionary.lookup]);
/// * the word is copied through the selected transform, which may write up to
///   542 bytes past the ring cursor.
void _applyCustomDictionaryReference(
  BitReader reader,
  DecoderState state,
  SharedDictionary shared,
  int compoundSize,
) {
  final wordLength = state.copyLength;
  if (wordLength < sharedMinDictionaryWordLength ||
      wordLength > sharedMaxDictionaryWordLength) {
    throw BrotliException(
      BrotliErrorCode.invalidDictionaryWord,
      'custom dictionary word length $wordLength is outside '
      '[$sharedMinDictionaryWordLength, $sharedMaxDictionaryWordLength]',
      inputOffset: reader.bytesConsumed,
    );
  }
  final dictId = shared.contextBased
      ? shared.contextMap[_dictionaryContext(state)]
      : 0;
  final address = staticDictionaryAddress(
    state.distance,
    state.maxDistance,
    compoundSize,
  );
  final lookup = shared.lookup(dictId, wordLength, address);
  final fence = state.calculateFence();
  final word = lookup.words.wordBytes(wordLength, lookup.wordIndex);
  final int transformedLength;
  if (lookup.transformIndex == lookup.transforms.cutoffIdentity) {
    // Fast path: ["", IDENTITY, ""] copies the word verbatim.
    state.ringBuffer.setRange(state.pos, state.pos + wordLength, word);
    transformedLength = wordLength;
  } else {
    transformedLength = lookup.transforms.apply(
      state.ringBuffer,
      state.pos,
      word,
      wordLength,
      lookup.transformIndex,
    );
  }
  if (transformedLength == 0 && state.distance <= 120) {
    // Matches the reference: a zero-length transformed word is only tolerated
    // for large distances (where no meaningful LZ77 match was attempted).
    throw BrotliException(
      BrotliErrorCode.invalidTransform,
      'custom dictionary transform ${lookup.transformIndex} produced an '
      'empty word',
      inputOffset: reader.bytesConsumed,
    );
  }
  if (transformedLength > state.metaBlockLength) {
    throw BrotliException(
      BrotliErrorCode.invalidDistance,
      'custom dictionary word of $transformedLength bytes overruns the '
      'metablock (${state.metaBlockLength} bytes left)',
      inputOffset: reader.bytesConsumed,
    );
  }
  assert(
    transformedLength <= maxTransformedWordLength,
    'custom transformed word of $transformedLength bytes exceeds the ring '
    'slack',
  );
  state.pos += transformedLength;
  state.metaBlockLength -= transformedLength;
  state.dictionaryReferenceCount++;
  if (state.pos >= fence) {
    state.nextPhase = DecodePhase.mainLoop;
    state.phase = DecodePhase.initWrite;
  } else {
    state.phase = DecodePhase.mainLoop;
  }
}

/// Starts one compound-dictionary copy (port of Java's
/// `initializeCompoundDictionaryCopy`, single-chunk case).
void _applyCompoundDictionaryReference(
  BitReader reader,
  DecoderState state,
  int address,
) {
  final dictionary = state.compoundDictionary;
  final length = state.copyLength;
  if (length <= 0 || length > dictionary.length - address) {
    throw BrotliException(
      BrotliErrorCode.invalidDistance,
      'compound dictionary reference (address $address, length $length) '
      'overruns the ${dictionary.length}-byte dictionary',
      inputOffset: reader.bytesConsumed,
    );
  }
  if (length > state.metaBlockLength) {
    throw BrotliException(
      BrotliErrorCode.invalidDistance,
      'compound dictionary copy length $length overruns the metablock '
      '(${state.metaBlockLength} bytes left)',
      inputOffset: reader.bytesConsumed,
    );
  }
  // Java/Rust roll the recent-distance cache for compound copies (unlike
  // static-dictionary words).
  state.distRbIdx = (state.distRbIdx + 1) & 3;
  state.rings[state.distRbIdx] = state.distance;
  state.metaBlockLength -= length;
  state.compoundDictionaryOffset = address;
  state.compoundDictionaryRemaining = length;
  state.compoundDictionaryReferenceCount++;
  state.phase = DecodePhase.copyFromCompoundDictionary;
}

/// Copies the remaining bytes of the active compound reference into the ring
/// buffer, stopping at the current fence so the caller can flush.
///
/// Port of Java's `copyFromCompoundDictionary` (single-chunk variant); no
/// input is consumed, so this phase never suspends on the bit reader.
BrotliStatus? decodeCompoundDictionaryCopy(DecoderState state) {
  final fence = state.calculateFence();
  final dictionary = state.compoundDictionary;
  while (state.compoundDictionaryRemaining > 0 && state.pos < fence) {
    final space = fence - state.pos;
    final length = state.compoundDictionaryRemaining < space
        ? state.compoundDictionaryRemaining
        : space;
    state.ringBuffer.setRange(
      state.pos,
      state.pos + length,
      dictionary,
      state.compoundDictionaryOffset,
    );
    state.pos += length;
    state.compoundDictionaryOffset += length;
    state.compoundDictionaryRemaining -= length;
  }
  if (state.pos >= fence) {
    final ready = state.pos < state.ringBufferSize
        ? state.pos
        : state.ringBufferSize;
    if (state.ringBufferBytesWritten >= ready) {
      // Nothing left to flush and the caller's slice is full: no phase can
      // make progress until more output is offered.
      return BrotliStatus.needMoreOutput;
    }
    state.nextPhase = DecodePhase.copyFromCompoundDictionary;
    state.phase = DecodePhase.initWrite;
    return null;
  }
  assert(
    state.compoundDictionaryRemaining == 0,
    'compound copy stopped before the fence',
  );
  state.compoundDictionaryOffset = -1;
  state.phase = DecodePhase.mainLoop;
  return null;
}

/// Resolves and writes one static-dictionary reference (port of
/// `Decode.doUseDictionary` + `Transform.transformDictionaryWord`).
///
/// Encoding (RFC 7932 §8, with an optional compound dictionary attached):
/// * `address = distance - maxDistance - 1 - compoundSize`;
/// * `wordLength = command copy length` must be `4..24`;
/// * `shift = sizeBits[wordLength]`;
/// * `wordIndex = address & ((1 << shift) - 1)`, `transformIndex = address >> shift`;
/// * the word is the transformed dictionary word, written at `pos`.
///
/// The metablock is charged with the **transformed** length, which may differ
/// from the copy length, and the write may extend up to 37 bytes past the ring
/// window into the slack region (the flush path wraps it afterwards).
void _applyStaticDictionaryReference(
  BitReader reader,
  DecoderState state,
  int compoundSize,
) {
  final fence = state.calculateFence();
  final wordLength = state.copyLength;
  if (wordLength < minDictionaryWordLength ||
      wordLength > maxDictionaryWordLength) {
    throw BrotliException(
      BrotliErrorCode.invalidDictionaryWord,
      'dictionary word length $wordLength is outside '
      '[$minDictionaryWordLength, $maxDictionaryWordLength]',
      inputOffset: reader.bytesConsumed,
    );
  }
  final shift = kDictionarySizeBitsByLength[wordLength];
  if (shift == 0) {
    // Unreachable for 4..24; kept as a guard against a table change.
    throw BrotliException(
      BrotliErrorCode.invalidDictionaryWord,
      'dictionary has no words of length $wordLength',
      inputOffset: reader.bytesConsumed,
    );
  }
  final address = staticDictionaryAddress(
    state.distance,
    state.maxDistance,
    compoundSize,
  );
  if (address < 0) {
    // Defensive: the caller only reaches the static path for addresses past
    // the compound dictionary, so a negative value means malformed state.
    throw BrotliException(
      BrotliErrorCode.invalidDistance,
      'static dictionary address $address is negative '
      '(compound size $compoundSize)',
      inputOffset: reader.bytesConsumed,
    );
  }
  final mask = (1 << shift) - 1;
  final wordIndex = address & mask;
  final transformIndex = address >> shift;
  if (transformIndex >= numRfcTransforms) {
    throw BrotliException(
      BrotliErrorCode.invalidTransform,
      'dictionary transform index $transformIndex is out of range '
      '(max ${numRfcTransforms - 1})',
      inputOffset: reader.bytesConsumed,
    );
  }
  final sourceOffset = dictionary.dictionaryWordOffset(wordLength, wordIndex);
  final transformedLength = transforms.transformDictionaryWord(
    state.ringBuffer,
    state.pos,
    kDictionaryData,
    sourceOffset,
    wordLength,
    transformIndex,
  );
  if (transformedLength <= 0) {
    // Java accepts empty results; C rejects them. Match C: an empty dictionary
    // word cannot make progress and is a format error.
    throw BrotliException(
      BrotliErrorCode.invalidDictionaryWord,
      'dictionary transform $transformIndex produced an empty word',
      inputOffset: reader.bytesConsumed,
    );
  }
  assert(
    transformedLength <= maxTransformedWordLength,
    'transformed word of $transformedLength bytes exceeds the ring slack',
  );
  state.pos += transformedLength;
  state.metaBlockLength -= transformedLength;
  state.dictionaryReferenceCount++;
  if (state.pos >= fence) {
    state.nextPhase = DecodePhase.mainLoop;
    state.phase = DecodePhase.initWrite;
  } else {
    state.phase = DecodePhase.mainLoop;
  }
}

/// Executes the backward copy of the current command.
BrotliStatus? decodeCopyLoop(BitReader reader, DecoderState state) {
  final fence = state.calculateFence();
  final ring = state.ringBuffer;
  final mask = state.ringBufferMask;
  final src = (state.pos - state.distance) & mask;
  final dst = state.pos;
  final remaining = state.copyLength - state.j;
  final srcEnd = src + remaining;
  final dstEnd = dst + remaining;

  // Fast path: both ranges stay inside the ring window. Overlapping copies are
  // expanded by doubling `setRange` chunks instead of copying byte by byte;
  // this is the dominant cost for text/RLE payloads (long matches, short
  // distances).
  if (srcEnd <= mask + 1 && dstEnd <= mask + 1) {
    if (state.distance >= remaining) {
      ring.setRange(dst, dst + remaining, ring, src);
    } else {
      final distance = state.distance;
      var copied = distance < remaining ? distance : remaining;
      ring.setRange(dst, dst + copied, ring, src);
      while (copied < remaining) {
        final chunk = copied < remaining - copied ? copied : remaining - copied;
        ring.setRange(dst + copied, dst + copied + chunk, ring, dst);
        copied += chunk;
      }
    }
    state.j += remaining;
    state.metaBlockLength -= remaining;
    state.pos += remaining;
  } else {
    while (state.j < state.copyLength) {
      ring[state.pos] = ring[(state.pos - state.distance) & mask];
      state.metaBlockLength--;
      state.pos++;
      state.j++;
      if (state.pos >= fence) {
        state.nextPhase = DecodePhase.copyLoop;
        state.phase = DecodePhase.initWrite;
        return null;
      }
    }
  }
  state.phase = DecodePhase.mainLoop;
  return null;
}

// ---------------------------------------------------------------------------
// Block switching.
// ---------------------------------------------------------------------------

/// Port of `Decode.decodeBlockTypeAndLength`; caller must have refilled.
int _decodeBlockTypeAndLength(
  BitReader reader,
  DecoderState state,
  int treeType,
  int numBlockTypes,
) {
  final ringOffset = 4 + treeType * 2;
  reader.fillBitWindow();
  var blockType = readSymbol(state.blockTrees, 2 * treeType, reader);
  final blockLength = readBlockLength(
    state.blockTrees,
    2 * treeType + 1,
    reader,
  );
  if (blockType == 1) {
    blockType = state.rings[ringOffset + 1] + 1;
  } else if (blockType == 0) {
    blockType = state.rings[ringOffset];
  } else {
    blockType -= 2;
  }
  if (blockType >= numBlockTypes) {
    blockType -= numBlockTypes;
  }
  if (blockType < 0 || blockType >= numBlockTypes) {
    throw BrotliException(
      BrotliErrorCode.invalidBlockType,
      'block type $blockType is out of range [0, $numBlockTypes)',
      inputOffset: reader.bytesConsumed,
    );
  }
  state.rings[ringOffset] = state.rings[ringOffset + 1];
  state.rings[ringOffset + 1] = blockType;
  return blockLength;
}

/// Detects literal blocks whose 64 contexts all select the same Huffman tree,
/// which lets the hot loop skip the context computation entirely.
void _updateLiteralBlockTrivial(DecoderState state) {
  final slice = state.contextMapSlice;
  final map = state.contextMap;
  final group = state.literalTreeGroup;
  final bases = state.literalBaseByContext;
  final first = map[slice];
  bases[0] = group[first & 0xFF];
  var same = true;
  for (var i = 1; i < 64; i++) {
    final tree = map[slice + i];
    bases[i] = group[tree & 0xFF];
    if (tree != first) {
      same = false;
    }
  }
  state.literalBlockTrivial = same;
}

void _literalBlockSwitch(BitReader reader, DecoderState state) {
  state.literalBlockLength = _decodeBlockTypeAndLength(
    reader,
    state,
    0,
    state.numLiteralBlockTypes,
  );
  final literalBlockType = state.rings[5];
  state.contextMapSlice = literalBlockType << numLiteralContextBits;
  state.literalTreeIdx = state.contextMap[state.contextMapSlice] & 0xFF;
  _updateLiteralBlockTrivial(state);
  final contextMode = state.contextModes[literalBlockType] & 0xFF;
  state.contextLookupOffset1 = contextMode << 9;
  state.contextLookupOffset2 = state.contextLookupOffset1 + 256;
}

// ---------------------------------------------------------------------------
// Header parsing helpers.
// ---------------------------------------------------------------------------

/// Port of `Decode.decodeVarLenUnsignedByte`; caller must have refilled.
int _readVarLenUnsignedByte(BitReader reader) {
  reader.fillBitWindow();
  if (reader.readFewBits(1) != 0) {
    final n = reader.readFewBits(3);
    if (n == 0) {
      return 1;
    }
    return reader.readFewBits(n) + (1 << n);
  }
  return 0;
}

/// Reads one Huffman code description, restoring the reader on input shortage.
int? _tryHuffmanCode(
  BitReader reader,
  int alphabetSizeMax,
  int alphabetSizeLimit,
  Uint32List group,
  int tableIndex,
) {
  final memento = reader.save();
  final used = readHuffmanCode(
    alphabetSizeMax,
    alphabetSizeLimit,
    group,
    tableIndex,
    reader,
  );
  if (used == null) {
    reader.restore(memento);
    return null;
  }
  reader.discard(memento);
  return used;
}

/// Starts a context map: decodes the tree count and handles the one-tree case.
///
/// Returns `null` on success (check [DecoderState.contextMapNumTrees]) or a
/// suspension status.
BrotliStatus? _startContextMap(
  BitReader reader,
  DecoderState state,
  bool distanceMap,
) {
  final size = distanceMap
      ? state.numDistanceBlockTypes << numDistanceContextBits
      : state.numLiteralBlockTypes << numLiteralContextBits;
  if (distanceMap) {
    state.distContextMap = _ensureBytes(state.distContextMap, size);
  } else {
    state.contextMap = _ensureBytes(state.contextMap, size);
  }
  state.contextMapSize = size;
  if (!reader.refill()) {
    return BrotliStatus.needMoreInput;
  }
  state.contextMapNumTrees = _readVarLenUnsignedByte(reader) + 1;
  state.contextMapIndex = 0;
  if (state.contextMapNumTrees == 1) {
    final map = distanceMap ? state.distContextMap : state.contextMap;
    map.fillRange(0, size, 0);
  }
  return null;
}

/// Reads the zero-RLE parameters for a context map.
///
/// This is a separate resumable step from the tree read: the tree read may
/// suspend (and be retried), and retrying must not re-read these bits.
BrotliStatus? _readContextMapRleParams(BitReader reader, DecoderState state) {
  if (!reader.refill()) {
    return BrotliStatus.needMoreInput;
  }
  reader.fillBitWindow();
  final useRleForZeros = reader.readFewBits(1);
  state.contextMapMaxRunPrefix = useRleForZeros != 0
      ? reader.readFewBits(4) + 1
      : 0;
  final alphabetSize = state.contextMapNumTrees + state.contextMapMaxRunPrefix;
  final tableSize = huffmanTableSizeLimit(alphabetSize);
  state.contextMapTable = _ensureUint32(state.contextMapTable, tableSize + 1);
  state.contextMapTableIndex = tableSize;
  // The scratch table starts at slot 0; the last slot holds the base offset.
  state.contextMapTable[tableSize] = 0;
  return null;
}

/// Reads the context-map Huffman code description.
BrotliStatus? _readContextMapTree(BitReader reader, DecoderState state) {
  final alphabetSize = state.contextMapNumTrees + state.contextMapMaxRunPrefix;
  final tableSize = state.contextMapTableIndex;
  final used = _tryHuffmanCode(
    reader,
    alphabetSize,
    alphabetSize,
    state.contextMapTable,
    tableSize,
  );
  if (used == null) {
    return BrotliStatus.needMoreInput;
  }
  if (used > tableSize) {
    throw BrotliException(
      BrotliErrorCode.internalError,
      'context-map Huffman table grew past its bound',
    );
  }
  return null;
}

/// Decodes the context-map symbols (including zero runs), resumably.
BrotliStatus? _readContextMapSymbols(
  BitReader reader,
  DecoderState state,
  bool distanceMap,
) {
  final map = distanceMap ? state.distContextMap : state.contextMap;
  final size = state.contextMapSize;
  final table = state.contextMapTable;
  final tableIndex = state.contextMapTableIndex;
  final maxRunPrefix = state.contextMapMaxRunPrefix;
  while (state.contextMapIndex < size) {
    if (!reader.refill()) {
      return BrotliStatus.needMoreInput;
    }
    reader.fillBitWindow();
    final code = readSymbol(table, tableIndex, reader);
    if (code == 0) {
      map[state.contextMapIndex++] = 0;
    } else if (code <= maxRunPrefix) {
      reader.fillBitWindow();
      var repetitions = (1 << code) + reader.readFewBits(code);
      while (repetitions > 0) {
        if (state.contextMapIndex >= size) {
          throw BrotliException(
            BrotliErrorCode.invalidContextMap,
            'context-map zero run overruns the map',
            inputOffset: reader.bytesConsumed,
          );
        }
        map[state.contextMapIndex++] = 0;
        repetitions--;
      }
    } else {
      map[state.contextMapIndex++] = code - maxRunPrefix;
    }
  }
  return null;
}

/// Reads the MTF flag and inverse-transforms the context map if requested.
BrotliStatus? _finishContextMap(
  BitReader reader,
  DecoderState state,
  bool distanceMap,
) {
  if (!reader.refill()) {
    return BrotliStatus.needMoreInput;
  }
  reader.fillBitWindow();
  if (reader.readFewBits(1) != 0) {
    final map = distanceMap ? state.distContextMap : state.contextMap;
    final mtf = state.mtf;
    for (var i = 0; i < 256; i++) {
      mtf[i] = i;
    }
    for (var i = 0; i < state.contextMapSize; i++) {
      final index = map[i] & 0xFF;
      map[i] = mtf[index];
      if (index != 0) {
        final value = mtf[index];
        for (var j = index; j > 0; j--) {
          mtf[j] = mtf[j - 1];
        }
        mtf[0] = value;
      }
    }
  }
  return null;
}

/// Port of `Decode.calculateDistanceLut`, filling the reusable state arrays.
void _fillDistanceLut(DecoderState state) {
  final extraBits = state.distExtraBits;
  final offsets = state.distOffset;
  final npostfix = state.distancePostfixBits;
  final ndirect = state.numDirectDistanceCodes;
  final postfix = 1 << npostfix;
  final limit = state.distanceAlphabetSizeLimit;
  var bits = 1;
  var half = 0;
  var i = numDistanceShortCodes;
  for (var j = 0; j < ndirect && i < limit; j++, i++) {
    extraBits[i] = 0;
    offsets[i] = j + 1;
  }
  while (i < limit) {
    final base = ndirect + ((((2 + half) << bits) - 4) << npostfix) + 1;
    for (var j = 0; j < postfix && i < limit; j++, i++) {
      extraBits[i] = bits;
      offsets[i] = base + j;
    }
    bits = bits + half;
    half = half ^ 1;
  }
}

// ---------------------------------------------------------------------------
// Small allocation helpers: grow, never shrink, so metablocks reuse buffers.
// ---------------------------------------------------------------------------

int _treeGroupLength(int alphabetSizeLimit, int treeCount) =>
    treeCount + treeCount * huffmanTableSizeLimit(alphabetSizeLimit);

Uint8List _ensureBytes(Uint8List buffer, int size) =>
    buffer.length >= size ? buffer : Uint8List(size);

Uint32List _ensureUint32(Uint32List buffer, int size) =>
    buffer.length >= size ? buffer : Uint32List(size);

Int32List _ensureInt32(Int32List buffer, int size) =>
    buffer.length >= size ? buffer : Int32List(size);

int _min(int a, int b) => a < b ? a : b;

// ---------------------------------------------------------------------------
// Whole-metablock fast path.
// ---------------------------------------------------------------------------

/// Decodes the current compressed metablock in one fused loop.
///
/// The generic state machine is resumable at every symbol; this path gives that
/// up for speed and is therefore only called when the caller has proven that
/// the entire metablock fits in the ring buffer and in the caller's output
/// slice (so no flush, suspension or memento is needed). Conditions are checked
/// by `BrotliDecoderCore._canUseFastMetablock`:
///
/// * closed input (one-shot or a fully buffered streaming chunk);
/// * no compound/shared dictionary (the resumable dictionary copies are left to
///   the generic path; RFC static words are handled inline);
/// * `pos + metaBlockLength + 542 <= ringBuffer.length` and the same bound fits
///   in the caller's output slice, so no fence can be crossed.
///
/// Returns `true` when the metablock finished (`phase` becomes
/// [DecodePhase.blockStart]). Returns `false` if a cold feature forced a fall
/// back; state is then coherent and the generic loop may continue.

bool decodeCompressedMetablockFast(BitReader reader, DecoderState state) {
  final ring = state.ringBuffer;
  final ringData = ByteData.sublistView(ring);
  final mask = state.ringBufferMask;
  var pos = state.pos;
  var meta = state.metaBlockLength;
  if (meta <= 0) {
    state.phase = DecodePhase.blockStart;
    return true;
  }
  if (pos + meta > state.ringBufferSize ||
      pos + meta + maxTransformedWordLength > ring.length ||
      state.outputUsed + pos + meta > state.outputLength) {
    return false;
  }

  while (meta > 0) {
    if (!reader.hasSafeguard && !reader.refill()) {
      throw BrotliException(
        BrotliErrorCode.truncatedInput,
        'input ended inside a compressed metablock',
        inputOffset: reader.tailBytes,
      );
    }
    if (state.commandBlockLength == 0) {
      state.commandBlockLength = _decodeBlockTypeAndLength(
        reader,
        state,
        1,
        state.numCommandBlockTypes,
      );
      state.commandTreeIdx = state.rings[7];
    }
    state.commandBlockLength--;

    reader.fillBitWindow();
    final commandGroup = state.commandTreeGroup;
    final commandBase = commandGroup[state.commandTreeIdx];
    final commandBits = reader.peekBits(15);
    var commandOffset = commandBase + (commandBits & 0xFF);
    var commandEntry = commandGroup[commandOffset];
    var commandRootLength = commandEntry >> 16;
    var commandSymbol = commandEntry & 0xFFFF;
    if (commandRootLength > 8) {
      final commandMask = (1 << commandRootLength) - 1;
      commandOffset += commandSymbol + ((commandBits & commandMask) >> 8);
      commandEntry = commandGroup[commandOffset];
      reader.dropBits((commandEntry >> 16) + 8);
      commandSymbol = commandEntry & 0xFFFF;
    } else {
      reader.dropBits(commandRootLength);
    }
    final commandCode = commandSymbol << 2;
    final extraBitsPacked = commandLookup[commandCode];
    // The command symbol decode left at most 15 bits consumed from a filled
    // 32-bit window, so 17 bits are guaranteed. Insert codes 20..23 and copy
    // codes up to 23 carry 10..24 extra bits each, so long commands refill
    // before each field; the common short command reads both directly.
    final insertExtraBits = extraBitsPacked & 0xFF;
    final copyExtraBits = extraBitsPacked >> 8;
    final wideExtra = insertExtraBits + copyExtraBits > 17;
    if (wideExtra) reader.fillBitWindow();
    final insertLength =
        commandLookup[commandCode + 1] + reader.readBits(insertExtraBits);
    if (wideExtra) reader.fillBitWindow();
    final copyLength =
        commandLookup[commandCode + 2] + reader.readBits(copyExtraBits);
    final distanceContext = commandLookup[commandCode + 3];

    // ---- literals ---------------------------------------------------------
    var remainingInsert = insertLength;
    while (remainingInsert > 0) {
      if (state.literalBlockLength == 0) {
        if (!reader.refill()) {
          throw BrotliException(
            BrotliErrorCode.truncatedInput,
            'input ended at a literal block switch',
            inputOffset: reader.tailBytes,
          );
        }
        _literalBlockSwitch(reader, state);
      }
      var run = remainingInsert < state.literalBlockLength
          ? remainingInsert
          : state.literalBlockLength;
      // Bound the run so every symbol can be decoded without an input
      // shortage: at most 15 bits per symbol, and a 32-bit refill burns a full
      // 4-byte window word. Symbols that fit in the accumulator need no
      // window bytes at all, which is what makes the final bytes of a closed
      // stream work.
      if (!reader.hasSafeguard && !reader.refill()) {
        throw BrotliException(
          BrotliErrorCode.truncatedInput,
          'input ended while reading literals',
          inputOffset: reader.tailBytes,
        );
      }
      reader.fillBitWindow();
      final windowBits = reader.filled >= 4 ? (reader.filled - 4) * 8 : 0;
      final maxByInput = (reader.unusedBits + windowBits) ~/ 15;
      if (run > maxByInput) {
        if (maxByInput <= 0) {
          final refilled = reader.refill();
          if (!refilled || (reader.endOfStreamReached && reader.filled == 0)) {
            throw BrotliException(
              BrotliErrorCode.truncatedInput,
              'input ended while reading literals',
              inputOffset: reader.tailBytes,
            );
          }
          continue;
        }
        run = maxByInput;
      }
      final group = state.literalTreeGroup;
      final useTrivial =
          state.trivialLiteralContext || state.literalBlockTrivial;
      final written = reader.decodeLiteralRun(
        ring,
        mask,
        pos,
        run,
        group,
        group[state.literalTreeIdx],
        useTrivial,
        state.literalBaseByContext,
        state.contextLookupOffset1,
        state.contextLookupOffset2,
        kContextLookupTable,
      );
      pos += written;
      remainingInsert -= written;
      state.literalBlockLength -= written;
    }

    meta -= insertLength;
    if (meta <= 0) {
      break;
    }

    // ---- distance ---------------------------------------------------------
    state.pos = pos;
    state.metaBlockLength = meta;
    state.copyLength = copyLength;
    state.implicitDistance = distanceContext < 0;
    state.distanceContext = state.implicitDistance ? 0 : distanceContext;
    state.j = 0;

    if (!reader.hasSafeguard && !reader.refill()) {
      throw BrotliException(
        BrotliErrorCode.truncatedInput,
        'input ended while reading a distance',
        inputOffset: reader.tailBytes,
      );
    }
    var distanceSymbol = 0;
    if (state.implicitDistance) {
      state.distance = state.rings[state.distRbIdx];
    } else {
      if (state.distanceBlockLength == 0) {
        state.distanceBlockLength = _decodeBlockTypeAndLength(
          reader,
          state,
          2,
          state.numDistanceBlockTypes,
        );
        state.distContextMapSlice = state.rings[9] << numDistanceContextBits;
      }
      state.distanceBlockLength--;
      final distanceTreeIdx =
          state.distContextMap[state.distContextMapSlice +
              state.distanceContext] &
          0xFF;
      reader.fillBitWindow();
      final distanceGroup = state.distanceTreeGroup;
      final distanceBase = distanceGroup[distanceTreeIdx];
      final distanceBits = reader.peekBits(15);
      var distanceOffset = distanceBase + (distanceBits & 0xFF);
      var distanceEntry = distanceGroup[distanceOffset];
      var distanceRootLength = distanceEntry >> 16;
      var distanceValue = distanceEntry & 0xFFFF;
      if (distanceRootLength > 8) {
        final distanceMask = (1 << distanceRootLength) - 1;
        distanceOffset += distanceValue + ((distanceBits & distanceMask) >> 8);
        distanceEntry = distanceGroup[distanceOffset];
        reader.dropBits((distanceEntry >> 16) + 8);
        distanceValue = distanceEntry & 0xFFFF;
      } else {
        reader.dropBits(distanceRootLength);
      }
      distanceSymbol = distanceValue;
      if (distanceSymbol < numDistanceShortCodes) {
        final ringIndex =
            (state.distRbIdx + distanceShortCodeIndexOffset[distanceSymbol]) &
            3;
        state.distance =
            state.rings[ringIndex] +
            distanceShortCodeValueOffset[distanceSymbol];
      } else {
        final extraBits = state.distExtraBits[distanceSymbol];
        reader.fillBitWindow();
        final bits = reader.readBits(extraBits);
        state.distance =
            state.distOffset[distanceSymbol] +
            (bits << state.distancePostfixBits);
      }
    }

    if (state.distance <= 0 || state.distance > maxAllowedDistance) {
      throw BrotliException(
        BrotliErrorCode.invalidDistance,
        'invalid backward reference distance ${state.distance}',
        inputOffset: reader.bytesConsumed,
      );
    }
    // Sticky like the generic path: once the window has filled, `pos` wraps
    // with the ring buffer and must not shrink the reachable distance again.
    final maxBackward = state.maxBackwardDistance;
    if (state.maxDistance != maxBackward && pos < maxBackward) {
      state.maxDistance = pos;
    } else {
      state.maxDistance = maxBackward;
    }

    if (state.distance > state.maxDistance) {
      _applyDictionaryReference(reader, state);
      pos = state.pos;
      meta = state.metaBlockLength;
      if (state.phase != DecodePhase.mainLoop) {
        // A static word crossed the fence (cannot happen for eligible calls);
        // hand the rest back to the generic state machine.
        return false;
      }
      continue;
    }

    if (distanceSymbol > 0) {
      state.distRbIdx = (state.distRbIdx + 1) & 3;
      state.rings[state.distRbIdx] = state.distance;
    }
    if (copyLength > meta) {
      throw BrotliException(
        BrotliErrorCode.invalidDistance,
        'copy length $copyLength overruns the metablock ($meta bytes left)',
        inputOffset: reader.bytesConsumed,
      );
    }

    // ---- copy -------------------------------------------------------------
    final distance = state.distance;
    final src = (pos - distance) & mask;
    if (src + copyLength > state.ringBufferSize) {
      // The source wraps past the end of a small window; the destination
      // never does (`pos + meta <= ringBufferSize`). Forward byte copy is
      // overlap-safe.
      for (var i = 0; i < copyLength; i++) {
        ring[pos + i] = ring[(src + i) & mask];
      }
    } else if (distance == 1) {
      ring.fillRange(pos, pos + copyLength, ring[src]);
    } else if (copyLength <= 16) {
      // Short matches dominate the binary corpus; a byte loop avoids the
      // call/bounds overhead of `setRange` and is overlap-safe.
      for (var i = 0; i < copyLength; i++) {
        ring[pos + i] = ring[src + i];
      }
    } else if (distance >= copyLength) {
      ring.setRange(pos, pos + copyLength, ring, src);
    } else if (distance >= 8) {
      // Overlapping with distance >= 8: forward word copies only touch bytes
      // that were already written. The helper is 64-bit on the VM and 32-bit
      // on the Web (dart2js rejects Uint64 accessors).
      copyOverlappingWide(ringData, ring, pos, src, copyLength);
    } else {
      // Short distances (1..7): expand by doubling `setRange` chunks of at
      // most `distance` bytes, which keeps every read behind the write cursor.
      var copied = distance;
      ring.setRange(pos, pos + copied, ring, src);
      while (copied < copyLength) {
        final chunk = copied < copyLength - copied
            ? copied
            : copyLength - copied;
        ring.setRange(pos + copied, pos + copied + chunk, ring, pos);
        copied += chunk;
      }
    }
    pos += copyLength;
    meta -= copyLength;
  }

  state.pos = pos;
  state.metaBlockLength = meta;
  state.phase = DecodePhase.blockStart;
  return true;
}
