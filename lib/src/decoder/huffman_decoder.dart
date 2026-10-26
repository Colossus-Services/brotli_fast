/// Canonical Huffman decoding tables for Brotli.
///
/// Direct port of `java/org/brotli/dec/Huffman.java` and the symbol/code
/// decoding parts of `Decode.java`:
///
/// * [buildHuffmanTable] builds a canonical lookup table: a root table of
///   `1 << rootBits` slots plus secondary tables for longer codes. Every slot
///   is `(bitLength << 16) | symbol`, except root slots that point at a
///   secondary table: `(rootBits + tableBits) << 16 | (tableOffset - slot)`.
/// * [readHuffmanCode] parses a complete code description (simple 1..4-symbol
///   code or complex code-length code) from a [BitReader] and builds its table.
/// * [readSymbol] and [readBlockLength] decode symbols through a built table.
///
/// Values stored in `Uint32List` slots are always in `[0, 2^32)`; no Dart
/// `>>>`, `~` or 32-bit shifts are used, so the code is exact on the web.
library;

import 'dart:typed_data';

import '../common/bit_utils.dart';
import '../common/errors.dart';
import '../common/format_tables.dart';
import 'bit_reader.dart';

/// Number of root-table index bits used by the decoder.
const int huffmanRootBits = 8;

/// Mask for the root-table index.
const int _rootMask = (1 << huffmanRootBits) - 1;

/// Maximum code length in bits (RFC 7932).
const int maxHuffmanCodeLength = 15;

/// A code length that repeats the previous non-zero length.
const int _repeatPreviousCode = 16;

/// Bit length used when building the code-length Huffman table.
const int _codeLengthRootBits = 5;

/// Initial `prevCodeLen` for code-length decoding.
const int _defaultCodeLength = 8;

/// Reads a canonical Huffman code description and builds its decode table.
///
/// [tableGroup] is a flat pool of 32-bit slots; `tableGroup[tableIndex]` is the
/// slot where the root table starts (the caller normally assigns the next free
/// offset there, exactly like Java's `group[i] = next`). The function writes at
/// most [`huffmanTableSizeLimit(alphabetSizeLimit)`] slots.
///
/// Returns the number of slots used, or `null` when the reader ran out of input
/// before the description ended. In that case the caller must restore its
/// [BitReaderMemento] and retry once more bytes are available.
///
/// Malformed descriptions throw [BrotliErrorCode.invalidHuffmanCode].
///
/// [alphabetSizeMax] controls the width of the simple-code symbol fields, while
/// [alphabetSizeLimit] validates the symbols and sizes the alphabet (they differ
/// for the distance alphabet in large-window mode).
int? readHuffmanCode(
  int alphabetSizeMax,
  int alphabetSizeLimit,
  Uint32List tableGroup,
  int tableIndex,
  BitReader reader,
) {
  if (!reader.refill()) {
    return null;
  }
  reader.fillBitWindow();
  final simpleCodeOrSkip = reader.readFewBits(2);
  if (simpleCodeOrSkip == 1) {
    return _readSimpleHuffmanCode(
      alphabetSizeMax,
      alphabetSizeLimit,
      tableGroup,
      tableIndex,
      reader,
    );
  }
  return _readComplexHuffmanCode(
    alphabetSizeLimit,
    simpleCodeOrSkip,
    tableGroup,
    tableIndex,
    reader,
  );
}

/// Reads up to four symbols written verbatim and applies a predefined
/// histogram (histogram ids 1..5).
int _readSimpleHuffmanCode(
  int alphabetSizeMax,
  int alphabetSizeLimit,
  Uint32List tableGroup,
  int tableIndex,
  BitReader reader,
) {
  if (alphabetSizeMax < 2) {
    throw BrotliException(
      BrotliErrorCode.invalidHuffmanCode,
      'simple Huffman code needs an alphabet of at least 2 symbols',
    );
  }
  final codeLengths = Uint32List(alphabetSizeLimit);
  final symbols = Uint32List(4);
  final maxBits = 1 + log2Floor(alphabetSizeMax - 1);
  final numSymbols = reader.readFewBits(2) + 1;
  for (var i = 0; i < numSymbols; i++) {
    reader.fillBitWindow();
    final symbol = reader.readFewBits(maxBits);
    if (symbol >= alphabetSizeLimit) {
      throw BrotliException(
        BrotliErrorCode.invalidHuffmanCode,
        'simple Huffman symbol $symbol is out of range',
        inputOffset: reader.bytesConsumed,
      );
    }
    symbols[i] = symbol;
  }
  for (var i = 0; i < numSymbols - 1; i++) {
    for (var j = i + 1; j < numSymbols; j++) {
      if (symbols[i] == symbols[j]) {
        throw BrotliException(
          BrotliErrorCode.invalidHuffmanCode,
          'duplicate simple Huffman symbol ${symbols[i]}',
          inputOffset: reader.bytesConsumed,
        );
      }
    }
  }

  var histogramId = numSymbols;
  if (numSymbols == 4) {
    histogramId += reader.readFewBits(1);
  }
  switch (histogramId) {
    case 1:
      codeLengths[symbols[0]] = 1;
      break;
    case 2:
      codeLengths[symbols[0]] = 1;
      codeLengths[symbols[1]] = 1;
      break;
    case 3:
      codeLengths[symbols[0]] = 1;
      codeLengths[symbols[1]] = 2;
      codeLengths[symbols[2]] = 2;
      break;
    case 4: // uniform 4-symbol histogram
      codeLengths[symbols[0]] = 2;
      codeLengths[symbols[1]] = 2;
      codeLengths[symbols[2]] = 2;
      codeLengths[symbols[3]] = 2;
      break;
    case 5: // prioritized 4-symbol histogram
      codeLengths[symbols[0]] = 1;
      codeLengths[symbols[1]] = 2;
      codeLengths[symbols[2]] = 3;
      codeLengths[symbols[3]] = 3;
      break;
    default:
      throw BrotliException(
        BrotliErrorCode.invalidHuffmanCode,
        'unknown simple Huffman histogram $histogramId',
      );
  }
  return buildHuffmanTable(
    tableGroup,
    tableIndex,
    huffmanRootBits,
    codeLengths,
    alphabetSizeLimit,
  );
}

/// Reads the 18 code-length-code lengths, then the symbol code lengths.
int? _readComplexHuffmanCode(
  int alphabetSizeLimit,
  int skip,
  Uint32List tableGroup,
  int tableIndex,
  BitReader reader,
) {
  final codeLengths = Uint32List(alphabetSizeLimit);
  final codeLengthCodeLengths = Uint32List(codeLengthCodes);
  var space = 32;
  var numCodes = 0;
  for (var i = skip; i < codeLengthCodes; i++) {
    final codeLengthIndex = codeLengthCodeOrder[i];
    reader.fillBitWindow();
    final entry = fixedCodeLengthTable[reader.peekBits(4)];
    reader.dropBits(entry >> 16);
    final value = entry & 0xFFFF;
    codeLengthCodeLengths[codeLengthIndex] = value;
    if (value != 0) {
      space -= 32 >> value;
      numCodes++;
      if (space <= 0) {
        break;
      }
    }
  }
  if (space != 0 && numCodes != 1) {
    throw BrotliException(
      BrotliErrorCode.invalidHuffmanCode,
      'corrupted Huffman code-length histogram',
      inputOffset: reader.bytesConsumed,
    );
  }
  if (!_readHuffmanCodeLengths(
    codeLengthCodeLengths,
    alphabetSizeLimit,
    codeLengths,
    reader,
  )) {
    return null;
  }
  return buildHuffmanTable(
    tableGroup,
    tableIndex,
    huffmanRootBits,
    codeLengths,
    alphabetSizeLimit,
  );
}

/// Decodes the symbol code lengths from the code-length alphabet.
///
/// Returns `false` when [reader] needs more input; the caller restarts from its
/// memento. Throws for corrupted code-length tables.
bool _readHuffmanCodeLengths(
  Uint32List codeLengthCodeLengths,
  int numSymbols,
  Uint32List codeLengths,
  BitReader reader,
) {
  var symbol = 0;
  var prevCodeLen = _defaultCodeLength;
  var repeat = 0;
  var repeatCodeLen = 0;
  var space = 32768;

  // Speculative single-entry table group, exactly as in the Java decoder.
  final table = Uint32List(33);
  const tableIndex = 32;
  buildHuffmanTable(
    table,
    tableIndex,
    _codeLengthRootBits,
    codeLengthCodeLengths,
    codeLengthCodes,
  );
  final tableOffset = table[tableIndex];

  while (symbol < numSymbols && space > 0) {
    if (!reader.refill()) {
      return false;
    }
    reader.fillBitWindow();
    final entry = table[tableOffset + reader.peekBits(_codeLengthRootBits)];
    reader.dropBits(entry >> 16);
    final codeLen = entry & 0xFFFF;
    if (codeLen < _repeatPreviousCode) {
      repeat = 0;
      codeLengths[symbol++] = codeLen;
      if (codeLen != 0) {
        prevCodeLen = codeLen;
        space -= 32768 >> codeLen;
      }
    } else {
      final extraBits = codeLen - 14;
      var newLen = 0;
      if (codeLen == _repeatPreviousCode) {
        newLen = prevCodeLen;
      }
      if (repeatCodeLen != newLen) {
        repeat = 0;
        repeatCodeLen = newLen;
      }
      final oldRepeat = repeat;
      if (repeat > 0) {
        repeat -= 2;
        repeat = repeat << extraBits;
      }
      reader.fillBitWindow();
      repeat += reader.readFewBits(extraBits) + 3;
      final repeatDelta = repeat - oldRepeat;
      if (symbol + repeatDelta > numSymbols) {
        throw BrotliException(
          BrotliErrorCode.invalidHuffmanCode,
          'code-length repeat overruns the alphabet',
          inputOffset: reader.bytesConsumed,
        );
      }
      for (var i = 0; i < repeatDelta; i++) {
        codeLengths[symbol++] = repeatCodeLen;
      }
      if (repeatCodeLen != 0) {
        space -= repeatDelta << (15 - repeatCodeLen);
      }
    }
  }
  if (space != 0) {
    throw BrotliException(
      BrotliErrorCode.invalidHuffmanCode,
      'Huffman code lengths do not use the full code space',
      inputOffset: reader.bytesConsumed,
    );
  }
  codeLengths.fillRange(symbol, numSymbols, 0);
  return true;
}

/// Builds a canonical Huffman lookup table.
///
/// Port of `Huffman.buildHuffmanTable`. `tableGroup[tableIndex]` must hold the
/// slot where the root table starts; the number of slots used is returned.
///
/// Entries are `(bitLength << 16) | symbol`. A root entry whose bit length is
/// greater than [huffmanRootBits] is a pointer: its low 16 bits are the
/// relative offset of a secondary table and the length is
/// `huffmanRootBits + secondaryBits`.
int buildHuffmanTable(
  Uint32List tableGroup,
  int tableIndex,
  int rootBits,
  Uint32List codeLengths,
  int codeLengthsSize,
) {
  assert(rootBits >= 1 && rootBits <= 8);
  final tableOffset = tableGroup[tableIndex];
  final sorted = Uint32List(codeLengthsSize);
  final count = Uint32List(maxHuffmanCodeLength + 1);
  final offset = Uint32List(maxHuffmanCodeLength + 1);

  // Histogram of code lengths.
  for (var sym = 0; sym < codeLengthsSize; sym++) {
    final len = codeLengths[sym];
    assert(len <= maxHuffmanCodeLength, 'code length $len out of range');
    count[len]++;
  }

  // Offsets into the sorted symbol table, by code length.
  offset[1] = 0;
  for (var len = 1; len < maxHuffmanCodeLength; len++) {
    offset[len + 1] = offset[len] + count[len];
  }

  // Sort symbols by length, preserving symbol order within a length.
  for (var sym = 0; sym < codeLengthsSize; sym++) {
    final len = codeLengths[sym];
    if (len != 0) {
      sorted[offset[len]++] = sym;
    }
  }

  var tableBits = rootBits;
  var tableSize = 1 << tableBits;
  var totalSize = tableSize;

  // Special case: a code with a single symbol consumes zero bits.
  if (offset[maxHuffmanCodeLength] == 1) {
    final symbol = sorted[0];
    for (var k = 0; k < totalSize; k++) {
      tableGroup[tableOffset + k] = symbol;
    }
    return totalSize;
  }

  // Fill the root table.
  var key = 0; // Reversed prefix code.
  var symbol = 0;
  var step = 1;
  for (var len = 1; len <= rootBits; len++) {
    step <<= 1;
    while (count[len] > 0) {
      _replicateValue(
        tableGroup,
        tableOffset + key,
        step,
        tableSize,
        (len << 16) | sorted[symbol++],
      );
      key = _nextKey(key, len);
      count[len]--;
    }
  }

  // Fill secondary tables and point root slots at them.
  final mask = totalSize - 1;
  var low = -1;
  var currentOffset = tableOffset;
  step = 1;
  for (var len = rootBits + 1; len <= maxHuffmanCodeLength; len++) {
    step <<= 1;
    while (count[len] > 0) {
      if ((key & mask) != low) {
        currentOffset += tableSize;
        tableBits = _nextTableBitSize(count, len, rootBits);
        tableSize = 1 << tableBits;
        totalSize += tableSize;
        low = key & mask;
        tableGroup[tableOffset + low] =
            ((tableBits + rootBits) << 16) |
            (currentOffset - tableOffset - low);
      }
      _replicateValue(
        tableGroup,
        currentOffset + (key >> rootBits),
        step,
        tableSize,
        ((len - rootBits) << 16) | sorted[symbol++],
      );
      key = _nextKey(key, len);
      count[len]--;
    }
  }
  return totalSize;
}

/// Returns `reverse(reverse(key, len) + 1, len)` without bit reversal tables.
int _nextKey(int key, int len) {
  var step = 1 << (len - 1);
  while ((key & step) != 0) {
    step >>= 1;
  }
  if (step == 0) {
    // All `len` bits were set. A complete code has no longer codes after this
    // point, so keeping the key matches the reference implementation.
    return key;
  }
  return (key & (step - 1)) + step;
}

/// Stores [item] at `table[offset], table[offset + step], ...`.
void _replicateValue(
  Uint32List table,
  int offset,
  int step,
  int end,
  int item,
) {
  var position = end;
  while (position > 0) {
    position -= step;
    table[offset + position] = item;
  }
}

/// Width of the next secondary table.
int _nextTableBitSize(Uint32List count, int len, int rootBits) {
  var bits = len;
  var left = 1 << (bits - rootBits);
  while (bits < maxHuffmanCodeLength) {
    left -= count[bits];
    if (left <= 0) {
      break;
    }
    bits++;
    left <<= 1;
  }
  return bits - rootBits;
}

/// Decodes the next symbol from the bit stream.
///
/// [tableGroup] and [tableIndex] identify the table exactly like in
/// [buildHuffmanTable]. The reader is warmed up as needed, so callers do not
/// have to call [BitReader.fillBitWindow] themselves.
@pragma('vm:prefer-inline')
int readSymbol(Uint32List tableGroup, int tableIndex, BitReader reader) {
  reader.fillBitWindow();
  var offset = tableGroup[tableIndex];
  final bits15 = reader.peekBits(15);
  offset += bits15 & _rootMask;
  final entry = tableGroup[offset];
  final rootLength = entry >> 16;
  final symbol = entry & 0xFFFF;
  if (rootLength <= huffmanRootBits) {
    reader.dropBits(rootLength);
    return symbol;
  }
  // Secondary table: the entry carries its relative offset and total length.
  offset += symbol;
  final mask = (1 << rootLength) - 1;
  offset += (bits15 & mask) >> huffmanRootBits;
  final secondEntry = tableGroup[offset];
  reader.dropBits((secondEntry >> 16) + huffmanRootBits);
  return secondEntry & 0xFFFF;
}

/// Decodes a block length: a block-length symbol plus its extra bits.
int readBlockLength(Uint32List tableGroup, int tableIndex, BitReader reader) {
  final code = readSymbol(tableGroup, tableIndex, reader);
  final nbits = blockLengthNBits[code];
  reader.fillBitWindow();
  return blockLengthOffset[code] + reader.readBits(nbits);
}
