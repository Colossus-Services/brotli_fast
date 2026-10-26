/// RLE-friendly Huffman histogram adjustment.
///
/// The serialised form of a Huffman tree is a run-length coded list of code
/// lengths (`c/enc/entropy_encode.c`, `BrotliWriteHuffmanTree`): equal
/// consecutive lengths compress well. A histogram that is almost -- but not
/// quite -- constant over a range therefore produces a tree that is more
/// expensive to transmit than the entropy gain justifies.
///
/// [optimizeHuffmanCountsForRle] is a direct port of
/// `BrotliOptimizeHuffmanCountsForRle`: it collapses runs of similar counts to
/// their average (`sum / stride`, in 24.8 fixed point) so that neighbouring
/// symbols get equal code lengths, while leaving runs that already RLE well
/// untouched. It is a pure ratio optimisation: it only changes *counts*, never
/// which symbols are present, so the resulting tree still covers every emitted
/// symbol.
///
/// The reference calls it for the literal / command / distance histograms at
/// `MIN_QUALITY_FOR_OPTIMIZE_HISTOGRAMS` and above.
library;

import 'dart:typed_data';

/// `streak_limit` of the reference implementation (24.8 fixed point).
const int _kStreakLimit = 1240;

/// Adjusts [counts] (`counts[0 .. length)`), in place, to be more RLE-friendly.
///
/// [goodForRle] is a scratch array of at least [length] bytes. Returns `true`
/// when the counts changed.
bool optimizeHuffmanCountsForRle(
  Uint32List counts,
  int length,
  Uint8List goodForRle,
) {
  var nonzeroCount = 0;
  for (var i = 0; i < length; i++) {
    if (counts[i] != 0) nonzeroCount++;
  }
  if (nonzeroCount < 16) return false;
  while (length != 0 && counts[length - 1] == 0) {
    length--;
  }
  if (length == 0) return false;

  {
    var nonzeros = 0;
    var smallestNonzero = 1 << 30;
    for (var i = 0; i < length; i++) {
      if (counts[i] != 0) {
        nonzeros++;
        if (smallestNonzero > counts[i]) smallestNonzero = counts[i];
      }
    }
    if (nonzeros < 5) return false;
    if (smallestNonzero < 4) {
      final zeros = length - nonzeros;
      if (zeros < 6) {
        for (var i = 1; i < length - 1; i++) {
          if (counts[i - 1] != 0 && counts[i] == 0 && counts[i + 1] != 0) {
            counts[i] = 1;
          }
        }
      }
    }
    if (nonzeros < 28) return false;
  }

  // Mark the runs that are already RLE-friendly.
  goodForRle.fillRange(0, length, 0);
  {
    var symbol = counts[0];
    var step = 0;
    for (var i = 0; i <= length; i++) {
      if (i == length || counts[i] != symbol) {
        if ((symbol == 0 && step >= 5) || (symbol != 0 && step >= 7)) {
          for (var k = 0; k < step; k++) {
            goodForRle[i - k - 1] = 1;
          }
        }
        step = 1;
        if (i != length) symbol = counts[i];
      } else {
        step++;
      }
    }
  }

  // Collapse strides of similar counts (24.8 fixed point math).
  var stride = 0;
  var limit = 256 * (counts[0] + counts[1] + counts[2]) ~/ 3 + 420;
  var sum = 0;
  for (var i = 0; i <= length; i++) {
    var breaksStride = i == length;
    if (!breaksStride) {
      breaksStride = goodForRle[i] != 0 || (i != 0 && goodForRle[i - 1] != 0);
    }
    if (!breaksStride) {
      // The reference compares an unsigned expression: a count far *below* the
      // local average underflows to a huge value and therefore also ends the
      // stride. Emulate that explicitly (a plain signed comparison would not).
      final streak = 256 * counts[i] - limit + _kStreakLimit;
      breaksStride = streak >= 2 * _kStreakLimit || streak < 0;
    }
    if (breaksStride) {
      if (stride >= 4 || (stride >= 3 && sum == 0)) {
        var count = (sum + stride ~/ 2) ~/ stride;
        if (count == 0) count = 1;
        if (sum == 0) count = 0;
        for (var k = 0; k < stride; k++) {
          counts[i - k - 1] = count;
        }
      }
      stride = 0;
      sum = 0;
      if (i < length - 2) {
        limit = 256 * (counts[i] + counts[i + 1] + counts[i + 2]) ~/ 3 + 420;
      } else if (i < length) {
        limit = 256 * counts[i];
      } else {
        limit = 0;
      }
    }
    stride++;
    if (i != length) {
      sum += counts[i];
      if (stride >= 4) {
        limit = (256 * sum + stride ~/ 2) ~/ stride;
      }
      if (stride == 4) {
        limit += 120;
      }
    }
  }
  return true;
}
