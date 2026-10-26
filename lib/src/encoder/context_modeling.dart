/// Literal context modeling for the encoder (RFC 7932 §7.1).
///
/// A compressed meta-block may declare a *literal context mode* and a
/// *literal context map* of `NBLTYPESL << 6` entries. For every literal the
/// decoder derives a 6-bit context id from the two previous bytes
/// (`BROTLI_CONTEXT(p1, p2) = lut[p1] | lut[256 + p2]`) and uses
/// `context_map[context]` to select which literal Huffman tree to read the
/// literal with. Splitting the literal alphabet into a few conditional
/// histograms is the single largest text-compression win after match finding:
/// the byte after a space and the byte after a letter have very different
/// distributions, and separate trees capture that.
///
/// This file ports the encoder-side heuristics of `c/enc/encode.c`:
///
/// * [chooseLiteralContextCount] - `DecideOverLiteralContextModeling` /
///   `ChooseContextMap`: samples 64-byte strides every 4 KiB, builds a 3x3
///   bigram of UTF-8 prefix classes (ASCII, leading byte, continuation byte)
///   and compares the Shannon entropy of 1, 2 and 3 contexts. Fewer than three
///   contexts are used unless the estimated saving exceeds the header cost.
/// * [kStaticContextMapSimpleUtf8] / [kStaticContextMapContinuation] - the two
///   static 64-entry maps the reference ships: a 2-context map that separates
///   ASCII bytes from UTF-8 leading/continuation bytes, and a 3-context map
///   that separates continuation bytes from everything else.
///
/// The entropy estimate uses [deterministicLog2], which is computed with only
/// IEEE-754 `+ - * /` (no `dart:math.log`), so the VM, dart2js and dart2wasm
/// all take the same decision on the same input.
library;

import 'dart:typed_data';

import '../common/bit_utils.dart';
import '../common/context_lookup.dart';

/// `BROTLI_LITERAL_CONTEXT_BITS`: the context id is 6 bits wide.
const int kLiteralContextBits = 6;

/// Number of literal contexts per block type (`1 << kLiteralContextBits`).
const int kNumLiteralContexts = 1 << kLiteralContextBits;

/// `BROTLI_CONTEXT_UTF8` (the `ContextType` enum value used in the bit stream).
const int kLiteralContextModeUtf8 = 2;

/// `MIN_QUALITY_FOR_CONTEXT_MODELING`.
const int kMinQualityForLiteralContexts = 5;

/// `MIN_QUALITY_FOR_HQ_CONTEXT_MODELING`: below this quality the 3-context
/// model is assumed to be too expensive.
const int kMinQualityForThreeContexts = 7;

/// Minimum meta-block length for which context modeling is considered.
const int kMinLengthForLiteralContexts = 64;

/// `kStaticContextMapSimpleUTF8`: 2 contexts (ASCII vs UTF-8 lead byte).
const List<int> kStaticContextMapSimpleUtf8 = <int>[
  0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// `kStaticContextMapContinuation`: 3 contexts (continuation bytes split off).
const List<int> kStaticContextMapContinuation = <int>[
  1, 1, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// UTF-8 slice of [kContextLookupTable]: `lut[p1] | lut[256 + p2]`.
final Uint8List kUtf8ContextLookup = Uint8List.sublistView(
  kContextLookupTable,
  2 * 512,
  3 * 512,
);

/// `2 / ln(2)`, the scale factor of the `atanh` form of log2.
const double _kTwoOverLn2 = 2.8853900817779268;

/// Natural extension of [log2Floor] to fractional values, with `log2(0) == 0`.
///
/// Uses `log2(v) = e + log2(1 + f)` with `f = v / 2^e - 1` and the `atanh`
/// series `log2(1 + f) = (2/ln2) * (y + y^3/3 + y^5/5 + ...)` where
/// `y = f / (2 + f) <= 1/3`. Ten terms are accurate to well below 1e-10, far
/// tighter than the 0.02-bit decision thresholds, and the series uses only
/// IEEE-754 basic operations, so every target computes the same bits.
///
/// Arguments below `2^16` are memoised (histogram clustering calls this a lot,
/// and merged meta-block histograms routinely hold counts in the thousands).
/// The cache only stores the result of a pure function in an unboxed
/// `Float64List`, so it cannot change any decision.
@pragma('vm:prefer-inline')
double deterministicLog2(int v) {
  if (v <= 1) return 0.0;
  if (v < _log2Cache.length) {
    final cached = _log2Cache[v];
    if (cached >= 0.0) return cached;
    final value = _computeLog2(v);
    _log2Cache[v] = value;
    return value;
  }
  return _computeLog2(v);
}

final Float64List _log2Cache = Float64List(1 << 16)
  ..fillRange(0, 1 << 16, -1.0);

double _computeLog2(int v) {
  final exponent = log2Floor(v);
  final scale = 1 << exponent; // exact in a double for v < 2^53
  final f = (v - scale) / scale;
  final y = f / (2.0 + f);
  final y2 = y * y;
  var sum = y;
  var term = y;
  var denominator = 3.0;
  for (var i = 0; i < 10; i++) {
    term *= y2;
    sum += term / denominator;
    denominator += 2.0;
  }
  return exponent + _kTwoOverLn2 * sum;
}

/// `EstimateEntropy(population, size)`: Shannon entropy in bits.
///
/// `total * log2(total) - sum(p * log2(p))`; the caller divides by the total to
/// obtain bits per symbol. [population] must be a `Uint32List` (or any list of
/// non-negative ints) of at least [size] entries.
double estimateEntropy(Uint32List population, int size) {
  var total = 0;
  var sum = 0.0;
  for (var i = 0; i < size; i++) {
    final p = population[i];
    total += p;
    sum += p * deterministicLog2(p);
  }
  return total * deterministicLog2(total) - sum;
}

/// One literal context map: `contextMap[contextId]` selects a literal tree.
final class LiteralContextModel {
  /// Creates a model for [numClusters] literal trees.
  const LiteralContextModel(this.numClusters, this.contextMap);

  /// Number of literal Huffman trees (`NTREESL`), 2 or 3.
  final int numClusters;

  /// 64 entries; every value is in `[0, numClusters)`.
  final Uint8List contextMap;
}

/// The reference 2-context UTF-8 model.
final LiteralContextModel kSimpleUtf8Contexts = LiteralContextModel(
  2,
  Uint8List.fromList(kStaticContextMapSimpleUtf8),
);

/// The reference 3-context UTF-8 model.
final LiteralContextModel kContinuationContexts = LiteralContextModel(
  3,
  Uint8List.fromList(kStaticContextMapContinuation),
);

/// `BROTLI_MAX_STATIC_CONTEXTS`: the complex UTF-8 map uses 13 literal trees.
const int kMaxStaticContexts = 13;

/// `kStaticContextMapComplexUTF8`: 64 context ids -> 13 literal trees.
///
/// The map groups contexts by what a decoded byte usually means: letters,
/// digits, spaces, punctuation after a space, and "special" bytes (11/12).
const List<int> kStaticContextMapComplexUtf8 = <int>[
  11, 11, 12, 12, // 0 special
  0, 0, 0, 0, // 4 lf
  1, 1, 9, 9, // 8 space
  2, 2, 2, 2, // !, first after space/lf and after something else
  1, 1, 1, 1, // "
  8, 3, 3, 3, // %
  1, 1, 1, 1, // ({[
  2, 2, 2, 2, // }])
  8, 4, 4, 4, // :;
  8, 7, 4, 4, // .
  8, 0, 0, 0, // >
  3, 3, 3, 3, // [0..9]
  5, 5, 10, 5, // [A-Z]
  5, 5, 10, 5,
  6, 6, 6, 6, // [a-z]
  6, 6, 6, 6,
];

/// The complex 13-context UTF-8 model.
final LiteralContextModel kComplexUtf8Contexts = LiteralContextModel(
  kMaxStaticContexts,
  Uint8List.fromList(kStaticContextMapComplexUtf8),
);

/// `ShouldUseComplexStaticContextMap`.
///
/// Only long inputs (`size_hint >= 1 MiB`) are candidates. The decision samples
/// 64-byte strides every 4 KiB and compares the entropy of the literal top-5-bit
/// histogram with and without the 13 complex contexts: it is taken when the
/// contextual entropy is at most 3 bits and saves at least 0.2 bits per symbol,
/// which the reference tuned on the silesia corpus.
bool shouldUseComplexStaticContextMap(
  Uint8List input,
  int start,
  int length, {
  required int sizeHint,
  required int quality,
}) {
  if (sizeHint < (1 << 20)) return false;
  if (quality < kMinQualityForLiteralContexts || length < 64) return false;
  final end = start + length;
  final combined = Uint32List(32);
  final contextHistogram = Uint32List(kMaxStaticContexts * 32);
  var total = 0;
  for (var pos = start; pos + 64 <= end; pos += 4096) {
    for (var p = pos + 2; p < pos + 64; p++) {
      final literal = input[p];
      final context = kStaticContextMapComplexUtf8[literalContextId(input, p)];
      total++;
      combined[literal >> 3]++;
      contextHistogram[context * 32 + (literal >> 3)]++;
    }
  }
  if (total == 0) return false;
  final entropy1 = estimateEntropy(combined, 32) / total;
  var entropy2 = 0.0;
  for (var i = 0; i < kMaxStaticContexts; i++) {
    entropy2 += estimateEntropy(
      Uint32List.sublistView(contextHistogram, i * 32, i * 32 + 32),
      32,
    );
  }
  entropy2 /= total;
  return entropy2 <= 3.0 && entropy1 - entropy2 >= 0.2;
}

/// UTF-8 prefix class used by the bigram sampler: 0 for ASCII, 1 for a leading
/// byte (`11xxxxxx`) and 2 for a continuation byte (`10xxxxxx`).
const List<int> _kPrefixClass = <int>[0, 0, 1, 2];

/// `ChooseContextMap`: decides between 1, 2 and 3 literal contexts.
///
/// [input] is the whole input and `input[start .. start + length)` is the
/// meta-block being compressed. Returns 1 when context modeling is not worth
/// its header (or the block is too short / quality too low).
int chooseLiteralContextCount(
  Uint8List input,
  int start,
  int length,
  int quality,
) {
  if (quality < kMinQualityForLiteralContexts ||
      length < kMinLengthForLiteralContexts) {
    return 1;
  }
  final end = start + length;
  // Bi-gram of UTF-8 prefix classes: index = previous * 3 + current.
  final bigram = Uint32List(9);
  // To keep the analysis cheap, only 64-byte strides at every 4 KiB are
  // examined; that is what the reference does as well.
  for (var pos = start; pos + 64 <= end; pos += 4096) {
    var previous = _kPrefixClass[input[pos] >> 6] * 3;
    for (var p = pos + 1; p < pos + 64; p++) {
      final current = _kPrefixClass[input[p] >> 6];
      bigram[previous + current]++;
      previous = current * 3;
    }
  }

  final monogram = Uint32List(3);
  final twoPrefix = Uint32List(6);
  for (var i = 0; i < 9; i++) {
    monogram[i % 3] += bigram[i];
    twoPrefix[i % 6] += bigram[i];
  }
  final entropy1 = estimateEntropy(monogram, 3);
  final entropy2 =
      estimateEntropy(twoPrefix, 3) +
      estimateEntropy(Uint32List.sublistView(twoPrefix, 3, 6), 3);
  var entropy3 = 0.0;
  for (var i = 0; i < 3; i++) {
    final threeGram = Uint32List.sublistView(bigram, 3 * i, 3 * i + 3);
    entropy3 += estimateEntropy(threeGram, 3);
  }

  final total = monogram[0] + monogram[1] + monogram[2];
  if (total == 0) return 1;
  final inv = 1.0 / total;
  final e1 = entropy1 * inv;
  final e2 = entropy2 * inv;
  var e3 = entropy3 * inv;
  if (quality < kMinQualityForThreeContexts) {
    // 3 context models are a bit slower; do not use them at lower qualities.
    e3 = e1 * 10.0;
  }
  // If the expected saving is less than 0.2 bits per symbol, skip context
  // modeling in exchange for faster decoding.
  if (e1 - e2 < 0.2 && e1 - e3 < 0.2) return 1;
  if (e2 - e3 < 0.02) return 2;
  return 3;
}

/// Returns the static context model to use for a meta-block, or `null` when
/// the block should keep a single literal tree.
LiteralContextModel? chooseLiteralContextModel(
  Uint8List input,
  int start,
  int length,
  int quality, {
  int? sizeHint,
}) {
  if (shouldUseComplexStaticContextMap(
    input,
    start,
    length,
    sizeHint: sizeHint ?? length,
    quality: quality,
  )) {
    return kComplexUtf8Contexts;
  }
  switch (chooseLiteralContextCount(input, start, length, quality)) {
    case 1:
      return null;
    case 2:
      return kSimpleUtf8Contexts;
    default:
      return kContinuationContexts;
  }
}

/// 6-bit literal context id of the byte at [pos] (UTF-8 mode).
///
/// The two previous *input* bytes are used, with zeros before the start of the
/// stream; this matches the decoder's `prev_byte` / `prev_byte2` state, which
/// crosses meta-block (and uncompressed-block) boundaries.
int literalContextId(Uint8List input, int pos) {
  final p1 = pos > 0 ? input[pos - 1] : 0;
  final p2 = pos > 1 ? input[pos - 2] : 0;
  return kUtf8ContextLookup[p1] | kUtf8ContextLookup[256 + p2];
}
