/// RFC 7932 format constants and derived lookup tables.
///
/// Values are shared by the decoder and the encoder. Keep all arithmetic in
/// 32-bit space; see `bit_utils.dart`.
library;

import 'dart:typed_data';

import 'bit_utils.dart';

// Alphabet sizes.
const int numLiteralCodes = 256;
const int numCommandCodes = 704;
const int numBlockLengthCodes = 26;
const int numDistanceShortCodes = 16;
const int numLiteralContextBits = 6;
const int numDistanceContextBits = 2;

// Window bits.
const int minLargeWindowBits = 10;
const int maxLargeWindowBits = 30;

// Distance limits.
const int maxDistanceBits = 24;
const int maxLargeWindowDistanceBits = 62;
const int maxAllowedDistance = 0x7FFFFFFC;

// Code-length alphabet.
const int codeLengthCodes = 18;
const List<int> codeLengthCodeOrder = <int>[
  1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
];

/// Static table size limit for an alphabet; index is `(size + 31) >> 5`.
const List<int> maxHuffmanTableSize = <int>[
  256, 402, 436, 468, 500, 534, 566, 598, 630, 662, 694, 726, //
  758, 790, 822, 854, 886, 920, 952, 984, 1016, 1048, 1080,
];

int huffmanTableSizeLimit(int alphabetSize) {
  var index = (alphabetSize + 31) >> 5;
  if (index < 0) index = 0;
  if (index >= maxHuffmanTableSize.length) {
    index = maxHuffmanTableSize.length - 1;
  }
  return maxHuffmanTableSize[index];
}

/// Static Huffman table for the code-length code lengths.
const List<int> fixedCodeLengthTable = <int>[
  0x020000,
  0x020004,
  0x020003,
  0x030002,
  0x020000,
  0x020004,
  0x020003,
  0x040001,
  0x020000,
  0x020004,
  0x020003,
  0x030002,
  0x020000,
  0x020004,
  0x020003,
  0x040005,
];

const List<int> blockLengthOffset = <int>[
  1,
  5,
  9,
  13,
  17,
  25,
  33,
  41,
  49,
  65,
  81,
  97,
  113,
  145,
  177,
  209,
  241,
  305,
  369,
  497,
  753,
  1265,
  2289,
  4337,
  8433,
  16625,
];

const List<int> blockLengthNBits = <int>[
  2,
  2,
  2,
  2,
  3,
  3,
  3,
  3,
  4,
  4,
  4,
  4,
  5,
  5,
  5,
  5,
  6,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  24,
];

const List<int> insertLengthNBits = <int>[
  0,
  0,
  0,
  0,
  0,
  0,
  1,
  1,
  2,
  2,
  3,
  3,
  4,
  4,
  5,
  5,
  6,
  7,
  8,
  9,
  10,
  12,
  14,
  24,
];

const List<int> copyLengthNBits = <int>[
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
  1,
  2,
  2,
  3,
  3,
  4,
  4,
  5,
  5,
  6,
  7,
  8,
  9,
  10,
  24,
];

const List<int> distanceShortCodeIndexOffset = <int>[
  0,
  3,
  2,
  1,
  0,
  0,
  0,
  0,
  0,
  0,
  3,
  3,
  3,
  3,
  3,
  3,
];

const List<int> distanceShortCodeValueOffset = <int>[
  0,
  0,
  0,
  0,
  -1,
  1,
  -2,
  2,
  -3,
  3,
  -1,
  1,
  -2,
  2,
  -3,
  3,
];

/// Command lookup: 4 values per command code.
///
/// `0`: insert/copy extra bits (insert in low byte, copy in high byte)
/// `1`: insert length offset
/// `2`: copy length offset
/// `3`: distance context id
///
/// Built once at startup from the same formula as the reference decoder.
final Int32List commandLookup = _buildCommandLookup();

Int32List _buildCommandLookup() {
  final insertLengthOffsets = Int32List(24);
  final copyLengthOffsets = Int32List(24);
  copyLengthOffsets[0] = 2;
  for (var i = 0; i < 23; i++) {
    insertLengthOffsets[i + 1] =
        insertLengthOffsets[i] + (1 << insertLengthNBits[i]);
    copyLengthOffsets[i + 1] = copyLengthOffsets[i] + (1 << copyLengthNBits[i]);
  }

  final table = Int32List(numCommandCodes * 4);
  for (var cmdCode = 0; cmdCode < numCommandCodes; cmdCode++) {
    var rangeIdx = cmdCode >> 6;
    var distanceContextOffset = -4;
    if (rangeIdx >= 2) {
      rangeIdx -= 2;
      distanceContextOffset = 0;
    }
    final insertCode =
        (((0x29850 >> (rangeIdx * 2)) & 0x3) << 3) | ((cmdCode >> 3) & 7);
    final copyCode = (((0x26244 >> (rangeIdx * 2)) & 0x3) << 3) | (cmdCode & 7);
    final copyLengthOffset = copyLengthOffsets[copyCode];
    final distanceContext =
        distanceContextOffset +
        (copyLengthOffset < 5 ? copyLengthOffset : 5) -
        2;
    final index = cmdCode * 4;
    table[index] =
        insertLengthNBits[insertCode] | (copyLengthNBits[copyCode] << 8);
    table[index + 1] = insertLengthOffsets[insertCode];
    table[index + 2] = copyLengthOffset;
    table[index + 3] = distanceContext;
  }
  return table;
}

int distanceAlphabetSize(int npostfix, int ndirect, int maxndistbits) {
  return numDistanceShortCodes + ndirect + 2 * (maxndistbits << npostfix);
}

int distanceAlphabetLimit(int maxDistance, int npostfix, int ndirect) {
  final minimum = ndirect + (2 << npostfix);
  if (maxDistance < minimum) {
    return -1;
  }
  final offset = ((maxDistance - ndirect) >> npostfix) + 4;
  final ndistbits = log2Floor(offset) - 1;
  final group = ((ndistbits - 1) << 1) | ((offset >> ndistbits) & 1);
  return ((group - 1) << npostfix) +
      (1 << npostfix) +
      ndirect +
      numDistanceShortCodes;
}
