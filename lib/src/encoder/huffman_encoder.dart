/// Huffman encoding for RFC 7932: depth-limited tree construction, canonical
/// (bit-reversed) codes, and the code-length RLE serialisation of the tree.
///
/// This is a close port of the reference `c/enc/entropy_encode.c` plus
/// `BrotliStoreHuffmanTree` / `StoreSimpleHuffmanTree` from
/// `c/enc/brotli_bit_stream.c`. Those routines encode *format rules*, not
/// heuristics, so they are deliberately kept verbatim:
///
/// * [createHuffmanTree] builds a Huffman tree with a maximum depth of 15
///   (5 for the code-length code) by raising a `count_limit` floor and
///   retrying, exactly like the reference implementation;
/// * [convertBitDepthsToSymbols] assigns canonical codes in symbol order and
///   reverses them because the bit stream is LSB-first;
/// * [storeHuffmanTree] RLE-encodes the code lengths (symbol 16 repeats the
///   previous non-zero length 3..6 times, symbol 17 repeats zeros 3..10 times)
///   and Huffman-codes those RLE symbols with a 5-bit-limited tree whose
///   lengths are written with the fixed 6-symbol code from the spec;
/// * codes with at most four used symbols are written as a *simple* code, and
///   a single used symbol is written as four bits `0001` plus the symbol.
///
/// All arithmetic is 32-bit safe (no `1 << 31` is ever evaluated for a mask,
/// every product goes through [mul32] where needed, no shift count >= 32).
library;

import 'dart:typed_data';

import 'bit_writer.dart';

/// Size of the scratch Huffman tree (2 * largest alphabet + 1).
const int kMaxHuffmanTreeSize = 2 * 704 + 1;

/// Number of symbols in the code-length alphabet (depths 0..17).
const int kNumCodeLengthCodes = 18;

/// RLE symbol: repeat the previous non-zero code length.
const int kRepeatPreviousCodeLength = 16;

/// RLE symbol: repeat a zero code length.
const int kRepeatZeroCodeLength = 17;

/// `BROTLI_INITIAL_REPEATED_CODE_LENGTH`.
const int kInitialRepeatedCodeLength = 8;

/// Order in which code-length-code lengths are transmitted
/// (`kStorageOrder` from `brotli_bit_stream.c`).
const List<int> kCodeLengthCodeOrder = <int>[
  1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
];

/// Fixed Huffman code used to write code-length-code lengths, symbols.
const List<int> kHuffmanBitLengthHuffmanCodeSymbols = <int>[
  0, 7, 3, 2, 1, 15, //
];

/// Fixed Huffman code used to write code-length-code lengths, bit lengths.
const List<int> kHuffmanBitLengthHuffmanCodeBitLengths = <int>[
  2, 4, 3, 2, 2, 4, //
];

/// Shell-sort gaps used by [HuffmanEncoder].
const List<int> kShellGaps = <int>[132, 57, 23, 10, 4, 1];

/// Pre-reversed 4-bit values used by [_reverseBits].
const List<int> _kReverseBitsLut = <int>[
  0x0, 0x8, 0x4, 0xC, 0x2, 0xA, 0x6, 0xE, //
  0x1, 0x9, 0x5, 0xD, 0x3, 0xB, 0x7, 0xF,
];

/// Builds and serialises Huffman trees into a [BitWriter].
///
/// One instance owns all scratch buffers and is reused for every tree of every
/// meta-block, so encoding produces no per-tree allocations.
final class HuffmanEncoder {
  HuffmanEncoder()
    : _treeCount = Uint32List(kMaxHuffmanTreeSize),
      _treeLeft = Int32List(kMaxHuffmanTreeSize),
      _treeRight = Int32List(kMaxHuffmanTreeSize),
      _treeSymbols = Uint8List(704),
      _treeExtraBits = Uint8List(704),
      _codeLengthDepth = Uint8List(kNumCodeLengthCodes),
      _codeLengthBits = Uint16List(kNumCodeLengthCodes),
      _codeLengthHistogram = Uint32List(kNumCodeLengthCodes),
      _depthStack = Int32List(16),
      _scratchA = Int32List(4);

  // Huffman tree pool: three parallel arrays instead of an object per node.
  final Uint32List _treeCount;
  final Int32List _treeLeft;
  final Int32List _treeRight;

  // Brotli representation of a tree (RLE symbols + their extra bits).
  final Uint8List _treeSymbols;
  final Uint8List _treeExtraBits;

  // Scratch for the code-length code tree.
  final Uint8List _codeLengthDepth;
  final Uint16List _codeLengthBits;
  final Uint32List _codeLengthHistogram;

  final Int32List _depthStack;
  final Int32List _scratchA;

  int _treeSymbolsCount = 0;

  /// Builds a Huffman tree over [histogram] and stores it into [writer].
  ///
  /// [histogramLength] is the number of histogram entries to consider and
  /// [alphabetSize] is the alphabet size (used only to size the symbol field of
  /// a *simple* tree). On return [depth] holds the code length of each symbol
  /// (0 = unused) and [bits] the LSB-first canonical code value. The caller
  /// must treat both arrays as valid only for symbols that occur in the
  /// histogram (single-symbol trees leave other entries untouched).
  void buildAndStore(
    Uint32List histogram,
    int histogramLength,
    int alphabetSize,
    BitWriter writer,
    Uint8List depth,
    Uint16List bits,
  ) {
    var count = 0;
    final symbols = _scratchA;
    // The reference declares `s4[4] = {0}` locally; our scratch array persists
    // between calls, so clear it to keep the all-zero histogram case (count 0)
    // writing symbol 0 rather than the previous tree's first symbol.
    symbols[0] = 0;
    symbols[1] = 0;
    symbols[2] = 0;
    symbols[3] = 0;
    for (var i = 0; i < histogramLength; i++) {
      if (histogram[i] != 0) {
        if (count < 4) symbols[count] = i;
        if (count > 4) break;
        count++;
      }
    }

    var maxBits = 0;
    var counter = alphabetSize - 1;
    while (counter != 0) {
      counter >>= 1;
      maxBits++;
    }

    if (count <= 1) {
      // Four bits with value 1 ("simple code"), then NSYM - 1 == 0, then the
      // single symbol. 0 bits are consumed per decoded symbol.
      writer.writeBits(4, 1);
      writer.writeBits(maxBits, symbols[0]);
      depth[symbols[0]] = 0;
      bits[symbols[0]] = 0;
      return;
    }

    depth.fillRange(0, histogramLength, 0);
    createHuffmanTree(histogram, histogramLength, 15, depth);
    convertBitDepthsToSymbols(depth, histogramLength, bits);

    if (count <= 4) {
      _storeSimpleHuffmanTree(depth, symbols, count, maxBits, writer);
    } else {
      storeHuffmanTree(depth, histogramLength, writer);
    }
  }

  /// Builds a depth-limited Huffman tree from [data] (`BrotliCreateHuffmanTree`).
  ///
  /// [treeLimit] is the maximum code length (15 for main trees, 5 for the
  /// code-length code). The loop doubles a fake minimum population count until
  /// a tree within the depth limit exists; the resulting tree is always full,
  /// which is what the decoder's completeness check requires.
  void createHuffmanTree(
    Uint32List data,
    int length,
    int treeLimit,
    Uint8List depth,
  ) {
    assert(treeLimit <= 15);
    var countLimit = 1;
    while (true) {
      var n = 0;
      for (var i = length; i != 0;) {
        i--;
        final value = data[i];
        if (value != 0) {
          _treeCount[n] = value > countLimit ? value : countLimit;
          _treeLeft[n] = -1;
          _treeRight[n] = i;
          n++;
        }
      }
      if (n == 0) {
        // All-zero histogram: nothing to build (callers special-case <= 1).
        return;
      }
      if (n == 1) {
        depth[_treeRight[0]] = 1;
        return;
      }

      _sortItems(n);

      // Layout: [0, n) leaves, [n] sentinel, [n + 1, 2n) parents, plus one
      // trailing sentinel after the last parent.
      _setSentinel(n);
      _setSentinel(n + 1);
      var i = 0;
      var j = n + 1;
      for (var k = n - 1; k != 0; k--) {
        int left;
        int right;
        if (_treeCount[i] <= _treeCount[j]) {
          left = i;
          i++;
        } else {
          left = j;
          j++;
        }
        if (_treeCount[i] <= _treeCount[j]) {
          right = i;
          i++;
        } else {
          right = j;
          j++;
        }
        final end = 2 * n - k;
        _treeCount[end] = (_treeCount[left] + _treeCount[right]) & 0xFFFFFFFF;
        _treeLeft[end] = left;
        _treeRight[end] = right;
        _setSentinel(end + 1);
      }

      if (_setDepth(2 * n - 1, depth, treeLimit)) return;
      countLimit *= 2;
      if (countLimit > 0x40000000) {
        // Unreachable for realistic histograms; avoids an infinite loop if a
        // pathological input ever defeats the depth limit.
        throw StateError('unable to build a depth-limited Huffman tree');
      }
    }
  }

  /// Converts code lengths in [depth] to canonical, bit-reversed codes.
  ///
  /// `BrotliConvertBitDepthsToSymbols`: canonical codes are assigned in symbol
  /// order per length, then bit-reversed because the stream is LSB-first.
  void convertBitDepthsToSymbols(Uint8List depth, int len, Uint16List bits) {
    final counts = _blCount;
    final nextCode = _nextCode;
    for (var i = 0; i < 16; i++) {
      counts[i] = 0;
    }
    for (var i = 0; i < len; i++) {
      counts[depth[i]]++;
    }
    counts[0] = 0;
    var code = 0;
    nextCode[0] = 0;
    for (var i = 1; i < 16; i++) {
      code = (code + counts[i - 1]) << 1;
      nextCode[i] = code;
    }
    for (var i = 0; i < len; i++) {
      final d = depth[i];
      if (d != 0) bits[i] = _reverseBits(d, nextCode[d]++);
    }
  }

  final Int32List _blCount = Int32List(16);
  final Int32List _nextCode = Int32List(16);

  /// Writes the code lengths of [depth]`[0..num)` as a Brotli tree.
  ///
  /// This is the complex path only; simple codes are handled by
  /// [_storeSimpleHuffmanTree].
  void storeHuffmanTree(Uint8List depth, int num, BitWriter writer) {
    _treeSymbolsCount = _writeHuffmanTree(depth, num);
    final histogram = _codeLengthHistogram;
    for (var i = 0; i < kNumCodeLengthCodes; i++) {
      histogram[i] = 0;
    }
    for (var i = 0; i < _treeSymbolsCount; i++) {
      histogram[_treeSymbols[i]]++;
    }

    var numCodes = 0;
    var onlyCode = 0;
    for (var i = 0; i < kNumCodeLengthCodes; i++) {
      if (histogram[i] != 0) {
        if (numCodes == 0) {
          onlyCode = i;
          numCodes = 1;
        } else if (numCodes == 1) {
          numCodes = 2;
          break;
        }
      }
    }

    final codeDepth = _codeLengthDepth;
    final codeBits = _codeLengthBits;
    codeDepth.fillRange(0, kNumCodeLengthCodes, 0);
    createHuffmanTree(histogram, kNumCodeLengthCodes, 5, codeDepth);
    convertBitDepthsToSymbols(codeDepth, kNumCodeLengthCodes, codeBits);

    _storeCodeLengthCode(numCodes, codeDepth, writer);

    if (numCodes == 1) {
      // A single code-length symbol is implicit: the decoder's table maps all
      // bit patterns to it consuming zero bits.
      codeDepth[onlyCode] = 0;
    }

    for (var i = 0; i < _treeSymbolsCount; i++) {
      final symbol = _treeSymbols[i];
      writer.writeBits(codeDepth[symbol], codeBits[symbol]);
      if (symbol == kRepeatPreviousCodeLength) {
        writer.writeBits(2, _treeExtraBits[i]);
      } else if (symbol == kRepeatZeroCodeLength) {
        writer.writeBits(3, _treeExtraBits[i]);
      }
    }
  }

  /// Serialises the 18 code-length-code lengths (`BrotliStoreHuffmanTreeOf
  /// HuffmanTreeToBitMask`).
  void _storeCodeLengthCode(
    int numCodes,
    Uint8List codeDepth,
    BitWriter writer,
  ) {
    var skipSome = 0;
    var codesToStore = kNumCodeLengthCodes;
    if (numCodes > 1) {
      while (codesToStore > 0) {
        if (codeDepth[kCodeLengthCodeOrder[codesToStore - 1]] != 0) break;
        codesToStore--;
      }
    }
    if (codeDepth[kCodeLengthCodeOrder[0]] == 0 &&
        codeDepth[kCodeLengthCodeOrder[1]] == 0) {
      skipSome = 2;
      if (codeDepth[kCodeLengthCodeOrder[2]] == 0) skipSome = 3;
    }
    writer.writeBits(2, skipSome);
    for (var i = skipSome; i < codesToStore; i++) {
      final l = codeDepth[kCodeLengthCodeOrder[i]];
      writer.writeBits(
        kHuffmanBitLengthHuffmanCodeBitLengths[l],
        kHuffmanBitLengthHuffmanCodeSymbols[l],
      );
    }
  }

  /// Writes a *simple* Huffman code (1..4 used symbols).
  void _storeSimpleHuffmanTree(
    Uint8List depth,
    Int32List symbols,
    int numSymbols,
    int maxBits,
    BitWriter writer,
  ) {
    writer.writeBits(2, 1); // simple code marker
    writer.writeBits(2, numSymbols - 1); // NSYM - 1

    // Least popular (deepest) symbol is written last; sort by depth.
    for (var i = 0; i < numSymbols; i++) {
      for (var j = i + 1; j < numSymbols; j++) {
        if (depth[symbols[j]] < depth[symbols[i]]) {
          final tmp = symbols[j];
          symbols[j] = symbols[i];
          symbols[i] = tmp;
        }
      }
    }

    for (var i = 0; i < numSymbols; i++) {
      writer.writeBits(maxBits, symbols[i]);
    }
    if (numSymbols == 4) {
      // Tree select: 1 means depths [1, 2, 3, 3], 0 means all depth 2.
      writer.writeBits(1, depth[symbols[0]] == 1 ? 1 : 0);
    }
  }

  /// Converts [depth]`[0..length)` into the RLE tree representation.
  ///
  /// Returns the number of symbols written to `_treeSymbols`; extra-bit values
  /// are written to `_treeExtraBits` (`BrotliWriteHuffmanTree`).
  int _writeHuffmanTree(Uint8List depth, int length) {
    // Trailing zero depths are not transmitted: the decoder stops as soon as
    // the Kraft sum is complete, so emitting them would desynchronise.
    var newLength = length;
    for (var i = 0; i < length; i++) {
      if (depth[length - i - 1] == 0) {
        newLength--;
      } else {
        break;
      }
    }

    var useRleForNonZero = false;
    var useRleForZero = false;
    if (length > 50) {
      _decideOverRleUse(depth, newLength);
      useRleForNonZero = _useRleForNonZero;
      useRleForZero = _useRleForZero;
    }

    var treeSize = 0;
    var previousValue = kInitialRepeatedCodeLength;
    var i = 0;
    while (i < newLength) {
      final value = depth[i];
      var reps = 1;
      if ((value != 0 && useRleForNonZero) || (value == 0 && useRleForZero)) {
        while (i + reps < newLength && depth[i + reps] == value) {
          reps++;
        }
      }
      if (value == 0) {
        treeSize = _writeRepetitionsZeros(reps, treeSize);
      } else {
        treeSize = _writeRepetitions(previousValue, value, reps, treeSize);
        previousValue = value;
      }
      i += reps;
    }
    return treeSize;
  }

  bool _useRleForNonZero = false;
  bool _useRleForZero = false;

  /// Computes whether the code lengths benefit from RLE (`DecideOverRleUse`).
  ///
  /// Results are stored in [_useRleForNonZero] / [_useRleForZero].
  void _decideOverRleUse(Uint8List depth, int length) {
    var totalRepsZero = 0;
    var totalRepsNonZero = 0;
    var countRepsZero = 1;
    var countRepsNonZero = 1;
    var i = 0;
    while (i < length) {
      final value = depth[i];
      var reps = 1;
      while (i + reps < length && depth[i + reps] == value) {
        reps++;
      }
      if (reps >= 3 && value == 0) {
        totalRepsZero += reps;
        countRepsZero++;
      }
      if (reps >= 4 && value != 0) {
        totalRepsNonZero += reps;
        countRepsNonZero++;
      }
      i += reps;
    }
    _useRleForNonZero = totalRepsNonZero > countRepsNonZero * 2;
    _useRleForZero = totalRepsZero > countRepsZero * 2;
  }

  /// Emits `repetitions` copies of [value] (non-zero) using symbol 16.
  int _writeRepetitions(
    int previousValue,
    int value,
    int repetitions,
    int treeSize,
  ) {
    assert(repetitions > 0);
    if (previousValue != value) {
      _treeSymbols[treeSize] = value;
      _treeExtraBits[treeSize] = 0;
      treeSize++;
      repetitions--;
    }
    if (repetitions == 7) {
      _treeSymbols[treeSize] = value;
      _treeExtraBits[treeSize] = 0;
      treeSize++;
      repetitions--;
    }
    if (repetitions < 3) {
      for (var i = 0; i < repetitions; i++) {
        _treeSymbols[treeSize] = value;
        _treeExtraBits[treeSize] = 0;
        treeSize++;
      }
    } else {
      final start = treeSize;
      repetitions -= 3;
      while (true) {
        _treeSymbols[treeSize] = kRepeatPreviousCodeLength;
        _treeExtraBits[treeSize] = repetitions & 0x3;
        treeSize++;
        repetitions >>= 2;
        if (repetitions == 0) break;
        repetitions--;
      }
      _reverseRange(treeSize, start);
    }
    return treeSize;
  }

  /// Emits `repetitions` zeros using symbol 17.
  int _writeRepetitionsZeros(int repetitions, int treeSize) {
    if (repetitions == 11) {
      _treeSymbols[treeSize] = 0;
      _treeExtraBits[treeSize] = 0;
      treeSize++;
      repetitions--;
    }
    if (repetitions < 3) {
      for (var i = 0; i < repetitions; i++) {
        _treeSymbols[treeSize] = 0;
        _treeExtraBits[treeSize] = 0;
        treeSize++;
      }
    } else {
      final start = treeSize;
      repetitions -= 3;
      while (true) {
        _treeSymbols[treeSize] = kRepeatZeroCodeLength;
        _treeExtraBits[treeSize] = repetitions & 0x7;
        treeSize++;
        repetitions >>= 3;
        if (repetitions == 0) break;
        repetitions--;
      }
      _reverseRange(treeSize, start);
    }
    return treeSize;
  }

  void _reverseRange(int end, int start) {
    var lo = start;
    var hi = end - 1;
    while (lo < hi) {
      final tmpSymbol = _treeSymbols[lo];
      _treeSymbols[lo] = _treeSymbols[hi];
      _treeSymbols[hi] = tmpSymbol;
      final tmpExtra = _treeExtraBits[lo];
      _treeExtraBits[lo] = _treeExtraBits[hi];
      _treeExtraBits[hi] = tmpExtra;
      lo++;
      hi--;
    }
  }

  // -- tree pool helpers ----------------------------------------------------

  void _setSentinel(int index) {
    _treeCount[index] = 0xFFFFFFFF;
    _treeLeft[index] = -1;
    _treeRight[index] = -1;
  }

  bool _lessNode(int countA, int leftA, int rightA, int b) {
    if (countA != _treeCount[b]) return countA < _treeCount[b];
    return rightA > _treeRight[b];
  }

  void _copyNode(int from, int to) {
    _treeCount[to] = _treeCount[from];
    _treeLeft[to] = _treeLeft[from];
    _treeRight[to] = _treeRight[from];
  }

  void _sortItems(int n) {
    if (n < 13) {
      for (var i = 1; i < n; i++) {
        final count = _treeCount[i];
        final left = _treeLeft[i];
        final right = _treeRight[i];
        var k = i;
        var j = i - 1;
        while (true) {
          if (!_lessNode(count, left, right, j)) break;
          _copyNode(j, k);
          k = j;
          if (j == 0) break;
          j--;
        }
        _treeCount[k] = count;
        _treeLeft[k] = left;
        _treeRight[k] = right;
      }
    } else {
      var g = n < 57 ? 2 : 0;
      for (; g < 6; g++) {
        final gap = kShellGaps[g];
        for (var i = gap; i < n; i++) {
          final count = _treeCount[i];
          final left = _treeLeft[i];
          final right = _treeRight[i];
          var j = i;
          while (j >= gap && _lessNode(count, left, right, j - gap)) {
            _copyNode(j - gap, j);
            j -= gap;
          }
          _treeCount[j] = count;
          _treeLeft[j] = left;
          _treeRight[j] = right;
        }
      }
    }
  }

  bool _setDepth(int root, Uint8List depth, int maxDepth) {
    final stack = _depthStack;
    var level = 0;
    var p = root;
    stack[0] = -1;
    while (true) {
      if (_treeLeft[p] >= 0) {
        level++;
        if (level > maxDepth) return false;
        stack[level] = _treeRight[p];
        p = _treeLeft[p];
        continue;
      }
      depth[_treeRight[p]] = level;
      while (level >= 0 && stack[level] == -1) {
        level--;
      }
      if (level < 0) return true;
      p = stack[level];
      stack[level] = -1;
    }
  }

  /// `BrotliReverseBits`: reverses the low [numBits] bits of [value].
  static int _reverseBits(int numBits, int value) {
    var retval = _kReverseBitsLut[value & 0xF];
    var bits = value;
    for (var i = 4; i < numBits; i += 4) {
      retval = (retval << 4) | _kReverseBitsLut[(bits >> 4) & 0xF];
      bits >>= 4;
    }
    return retval >> ((0 - numBits) & 3);
  }
}
