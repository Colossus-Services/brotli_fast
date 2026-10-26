/// Distance parameter search (`NPOSTFIX` / `NDIRECT`) and distance prefix
/// re-encoding.
///
/// RFC 7932 §4 lets a meta-block choose how distances are split into a prefix
/// symbol and extra bits: `NPOSTFIX` (0..3) adds low bits to the prefix symbol
/// and `NDIRECT` reserves `NDIRECT` distance codes that need no extra bits.
/// The default `(0, 0)` is a sensible generic choice, but data whose explicit
/// distances cluster in a narrow range (binary formats, font tables, images)
/// codes better with a few direct codes, and data with distances spread over
/// powers of two benefits from `NPOSTFIX > 0`.
///
/// This is the encoder half of that decision, ported from
/// `c/enc/metablock.c`:
///
/// * [chooseDistanceParams] evaluates the candidate grid (`NPOSTFIX` 0..3,
///   `NDIRECT` a multiple of `1 << NPOSTFIX` up to 15) by rebuilding the
///   distance symbol histogram for each candidate and estimating
///   `population_cost(histogram) + extra_bits`; the search stops at the first
///   non-improving candidate per `NPOSTFIX`, like the reference;
/// * [encodeDistanceCode] maps a parameter-independent distance code to the
///   prefix symbol / extra bits for a given parameter pair (this is
///   `PrefixEncodeCopyDistance`, already used by the default path);
/// * [DistanceParams.alphabetSize] is the distance alphabet the tree reader
///   derives from `(NPOSTFIX, NDIRECT)`.
library;

import 'dart:typed_data';

import '../common/format_tables.dart' as tables;
import 'block_split.dart' show histogramCost;
import 'command.dart';

/// Largest `NPOSTFIX` allowed by RFC 7932 (`BROTLI_MAX_NPOSTFIX`).
const int kMaxNpostfix = 3;

/// Largest `NDIRECT` allowed by RFC 7932 (`BROTLI_MAX_NDIRECT`).
const int kMaxNdirect = 120;

/// Number of distance bits in a regular (non-large-window) stream.
const int kMaxDistanceBits = 24;

/// Number of distance bits used for large-window streams (lgwin 25..30).
///
/// The reference reads large-window distance trees over this many bits worth of
/// symbols (BROTLI_LARGE_MAX_DISTANCE_BITS); distances themselves are bounded
/// by maxAllowedDistance.
const int kMaxLargeDistanceBits = 62;

/// One `(NPOSTFIX, NDIRECT)` choice and the derived quantities.
final class DistanceParams {
  /// Creates a parameter pair and derives its alphabet / distance limit.
  ///
  /// [maxDistanceBits] is 24 for regular streams and 30 for large-window
  /// streams; it widens the distance alphabet and the largest representable
  /// distance. The alphabet never exceeds the decoder's limit for
  /// maxAllowedDistance (distanceAlphabetLimit).
  DistanceParams(
    this.npostfix,
    this.ndirect, {
    this.maxDistanceBits = kMaxDistanceBits,
  }) : assert(npostfix >= 0 && npostfix <= kMaxNpostfix),
       assert(ndirect >= 0 && ndirect <= kMaxNdirect),
       assert(
         (ndirect >> npostfix) << npostfix == ndirect,
         'ndirect must be a '
         'multiple of 1 << npostfix',
       ),
       alphabetSize = _alphabetSize(npostfix, ndirect, maxDistanceBits),
       maxDistance = maxDistanceBits <= kMaxDistanceBits
           ? distanceMaxValue(npostfix, ndirect)
           : tables.maxAllowedDistance;

  /// Distance bits this parameter pair was derived for (24 or 30).
  final int maxDistanceBits;

  /// Extra low bits taken from the distance instead of the extra-bit field.
  final int npostfix;

  /// Number of prefix codes that carry the distance directly (no extra bits).
  final int ndirect;

  /// Distance alphabet size implied by the parameters.
  final int alphabetSize;

  /// Largest distance this parameter pair can express (RFC 7932 limit).
  final int maxDistance;

  /// Whether this is the default `(0, 0)` pair.
  bool get isDefault => npostfix == 0 && ndirect == 0;

  @override
  String toString() => 'DistanceParams($npostfix, $ndirect)';
}

/// The default distance parameters used by the lower quality tiers.
final DistanceParams kDefaultDistanceParams = DistanceParams(0, 0);

/// Distance alphabet size (`BROTLI_DISTANCE_ALPHABET_SIZE`).
///
/// `16 + NDIRECT + (maxDistanceBits << (NPOSTFIX + 1))`: 16 short codes, the
/// direct codes and one extra-bit width per distance group per postfix class.
int distanceAlphabetSize(
  int npostfix,
  int ndirect, [
  int maxDistanceBits = kMaxDistanceBits,
]) => numDistanceShortCodes + ndirect + (maxDistanceBits << (npostfix + 1));

/// Alphabet size used by [DistanceParams], clamped to the decoder's limit.
int _alphabetSize(int npostfix, int ndirect, int maxDistanceBits) {
  // The reference reads large-window distance trees over
  // BROTLI_DISTANCE_ALPHABET_SIZE(..., BROTLI_LARGE_MAX_DISTANCE_BITS) symbols
  // (140 for (0, 0)), not over the reachable-code limit.
  return distanceAlphabetSize(npostfix, ndirect, maxDistanceBits);
}

/// Largest distance expressible with [npostfix]/[ndirect].
int distanceMaxValue(int npostfix, int ndirect) =>
    ndirect + (1 << (kMaxDistanceBits + npostfix + 2)) - (1 << (npostfix + 2));

/// Encodes a parameter-independent [distanceCode] as `symbol | nbits << 10`.
///
/// [outExtra] receives the extra-bit value. Codes below
/// `16 + ndirect` are emitted verbatim with no extra bits; larger codes are
/// prefix-encoded (`PrefixEncodeCopyDistance`).
int encodeDistanceCode(
  int distanceCode,
  DistanceParams params,
  Int32List outBits,
  Int32List outExtra,
) {
  final packed = prefixEncodeCopyDistance(
    distanceCode,
    params.ndirect,
    params.npostfix,
    outBits,
    outExtra,
  );
  return (packed & 0x3FF) | (outBits[0] << 10);
}

/// Estimates the cost in bits of coding the distance stream with [params].
///
/// Returns [double.infinity] when some distance cannot be represented (only
/// possible for absurd parameter pairs, never for `(0, 0)`); otherwise the
/// histogram population cost plus the extra-bit count
/// (`ComputeDistanceCost`).
double distanceCost(CommandBuffer commands, DistanceParams params) {
  final histogram = Uint32List(params.alphabetSize);
  final bits = Int32List(1);
  final extra = Int32List(1);
  var extraBits = 0;
  for (var i = 0; i < commands.count; i++) {
    if (commands.copyLen[i] == 0 || commands.cmdPrefix[i] < 128) continue;
    final distanceCode = commands.distCode[i];
    if (distanceCode >= numDistanceShortCodes) {
      final distance = distanceCode - numDistanceShortCodes + 1;
      if (distance > params.maxDistance) return double.infinity;
    }
    final packed = encodeDistanceCode(distanceCode, params, bits, extra);
    final symbol = packed & 0x3FF;
    if (symbol >= params.alphabetSize) return double.infinity;
    histogram[symbol]++;
    extraBits += packed >> 10;
  }
  return histogramCost(histogram, params.alphabetSize) + extraBits;
}

/// Chooses the distance parameters for one meta-block (`BrotliBuildMetaBlock`).
///
/// Explores `NPOSTFIX` 0..3 with `NDIRECT` multiples of `1 << NPOSTFIX` and
/// keeps the cheapest pair; the inner loop stops at the first candidate that is
/// worse than the best so far, and the next `NPOSTFIX` starts from half the
/// previous `NDIRECT`, exactly like the reference search.
DistanceParams chooseDistanceParams(
  CommandBuffer commands, {
  int maxDistanceBits = kMaxDistanceBits,
}) {
  var best = maxDistanceBits <= kMaxDistanceBits
      ? kDefaultDistanceParams
      : DistanceParams(0, 0, maxDistanceBits: maxDistanceBits);
  var bestCost = distanceCost(commands, best);
  if (commands.count == 0) return best;
  var ndirectMsb = 0;
  for (var npostfix = 0; npostfix <= kMaxNpostfix; npostfix++) {
    for (; ndirectMsb < 16; ndirectMsb++) {
      final ndirect = ndirectMsb << npostfix;
      // The parameter pair must be representable in the header.
      if (ndirect > kMaxNdirect) break;
      final candidate = DistanceParams(
        npostfix,
        ndirect,
        maxDistanceBits: maxDistanceBits,
      );
      final cost = distanceCost(commands, candidate);
      if (cost == double.infinity || cost > bestCost) break;
      bestCost = cost;
      best = candidate;
    }
    if (ndirectMsb > 0) ndirectMsb--;
    ndirectMsb ~/= 2;
  }
  return best;
}
