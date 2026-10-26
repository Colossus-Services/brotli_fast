/// Cost-model-guided LZ77 parser for qualities 10 and 11.
///
/// The lazy parser in `backward_references.dart` decides with a fixed heuristic
/// score. This parser keeps that structure but evaluates the *expected bit
/// cost* of the alternatives with a [ParseCostModel] built from a previous
/// parse (see `cost_model.dart`): it considers the scored best match, the
/// distances in the distance cache, and a bounded set of copy lengths, and it
/// defers a copy for up to [lazySteps] literals when that is cheaper.
///
/// Running it repeatedly (each pass modelling the previous pass's histograms)
/// is the bounded, iterative variant of the reference's HQ / Zopfli parsing.
/// The resulting commands are always compared against the plain parse by the
/// caller, so a guided pass can never make the output worse.
library;

import 'dart:typed_data';

import 'backward_references.dart' show kHashTypeLength;
import 'command.dart';
import 'cost_model.dart';
import 'match_finder.dart';

/// Longest copy length for which every intermediate length is costed.
const int _kMaxEnumeratedLength = 16;

/// Cache distances whose maximal match is also considered as a copy candidate.
const int _kMaxCacheDistanceCandidates = 4;

/// Upper bound for a cache-distance match scan (the scored search finds the
/// long matches; this only compares recent distances cheaply).
const int _kMaxCacheMatchLength = 256;

/// Fills [commands] with a cost-guided parse of `input[start .. start + size)`.
///
/// [distanceCache] must hold the 16 prepared entries (as
/// [createSearchDistanceCache] builds them) and is advanced exactly like the
/// decoder's cache. [lazySteps] is how many literals the parser may insert to
/// reach a cheaper copy; [cacheDistances] bounds how many recent distances are
/// tried besides the scored best match.
void createGuidedBackwardReferences(
  Uint8List input,
  int start,
  int blockSize,
  HashChainMatcher hasher,
  CommandBuffer commands,
  Int32List distanceCache,
  int maxBackwardLimit,
  ParseCostModel model, {
  required int lazySteps,
  int cacheDistances = _kMaxCacheDistanceCandidates,
}) {
  commands.clear();
  final numDistances = hasher.numLastDistances;
  final posEnd = start + blockSize;
  if (blockSize < 16) {
    commands.addInsertOnly(blockSize);
    return;
  }
  var position = start;
  var insertLength = 0;
  prepareDistanceCache(distanceCache, numDistances);

  final sr = HasherSearchResult()..reset(kMinScore);
  // Average literal price, used to prefer long copies (a copy that covers
  // many bytes saves that many literals).
  var avgLiteralCost = 0.0;
  for (final c in model.literalCost) {
    avgLiteralCost += c;
  }
  avgLiteralCost /= model.literalCost.length;
  // Hard bound on match searches per block: a pathological cost model must not
  // turn a high-effort parse into an unbounded run. If the budget runs out the
  // rest of the block becomes an insert-only command, which simply loses the
  // candidate comparison against the chain parse.
  var searchesLeft = blockSize >> 2;

  // Returns the cheapest copy starting at [pos] with [insertLen] pending
  // literals, as (cost, len, distance); len == 0 when no copy was found.
  (double, int, int) bestCopy(int pos, int insertLen) {
    if (pos + kHashTypeLength >= posEnd || searchesLeft <= 0) {
      return (double.infinity, 0, 0);
    }
    searchesLeft--;
    final maxLength = posEnd - pos;
    final maxDistance = pos < maxBackwardLimit ? pos : maxBackwardLimit;
    if (maxDistance <= 0) return (double.infinity, 0, 0);
    var bestCost = double.infinity;
    var bestSaving = double.negativeInfinity;
    var bestLen = 0;
    var bestDistance = 0;

    void consider(int distance, int matchLen) {
      if (matchLen < 2 || distance <= 0) return;
      final distanceCode = computeDistanceCode(
        distance,
        maxDistance,
        distanceCache,
      );
      final limit = matchLen < _kMaxEnumeratedLength
          ? matchLen
          : _kMaxEnumeratedLength;
      for (var len = 2; len <= limit; len++) {
        final cost = model.copyCost(insertLen, len, distanceCode);
        // Maximise the saving over coding the covered bytes as literals.
        final saving = len * avgLiteralCost - cost;
        if (saving > bestSaving) {
          bestSaving = saving;
          bestCost = cost;
          bestLen = len;
          bestDistance = distance;
        }
      }
      if (matchLen > limit) {
        final cost = model.copyCost(insertLen, matchLen, distanceCode);
        final saving = matchLen * avgLiteralCost - cost;
        if (saving > bestSaving) {
          bestSaving = saving;
          bestCost = cost;
          bestLen = matchLen;
          bestDistance = distance;
        }
      }
    }

    sr.reset(kMinScore);
    hasher.findLongestMatch(
      input,
      distanceCache,
      numDistances,
      pos,
      maxLength,
      maxDistance,
      sr,
    );
    if (sr.score > kMinScore) {
      consider(sr.distance, sr.len);
    }
    final maxCandidates = cacheDistances < numDistances
        ? cacheDistances
        : numDistances;
    final scanLimit = maxLength < _kMaxCacheMatchLength
        ? maxLength
        : _kMaxCacheMatchLength;
    for (var i = 0; i < maxCandidates; i++) {
      final distance = distanceCache[i];
      if (distance <= 0 || distance > maxDistance || distance > pos) continue;
      final previous = pos - distance;
      // Cheap 4-byte filter before scanning the match length.
      if (read32le(input, previous) != read32le(input, pos)) continue;
      final len = findMatchLength(input, previous, pos, scanLimit);
      if (len >= 2) consider(distance, len);
    }
    return (bestCost, bestLen, bestDistance);
  }

  while (position + kHashTypeLength < posEnd) {
    final (copyCost, copyLen, copyDistance) = bestCopy(position, insertLength);
    var chosenLen = copyLen;
    var chosenDistance = copyDistance;
    var chosenCost = copyCost;
    if (copyLen != 0 && lazySteps > 0) {
      // Try inserting 1..lazySteps literals before the copy; the pending insert
      // length grows by the same amount and is part of the command cost.
      var literalBits = 0.0;
      var literalCount = 0;
      for (var step = 1; step <= lazySteps; step++) {
        if (position + step + kHashTypeLength >= posEnd) break;
        literalBits += model.literalCost[input[position + step - 1]];
        final (nextCost, nextLen, nextDistance) = bestCopy(
          position + step,
          insertLength + step,
        );
        if (nextLen == 0) break;
        if (literalBits + nextCost < chosenCost) {
          chosenCost = literalBits + nextCost;
          chosenLen = nextLen;
          chosenDistance = nextDistance;
          literalCount = step;
        }
      }
      for (var i = 0; i < literalCount; i++) {
        insertLength++;
        position++;
      }
    }

    if (chosenLen == 0) {
      insertLength++;
      position++;
      continue;
    }

    final codingMaxDistance = position < maxBackwardLimit
        ? position
        : maxBackwardLimit;
    commands.addCopy(
      insertLength,
      chosenLen,
      chosenDistance,
      codingMaxDistance,
      distanceCache,
    );
    prepareDistanceCache(distanceCache, numDistances);
    insertLength = 0;
    // Deliberately does NOT insert the positions covered by the copy into the
    // hash table: the guided parse must leave the matcher exactly as the chain
    // parse left it, so a later block's chain parse is identical to quality 9's
    // and a guided pass can only ever add a smaller candidate.
    position += chosenLen;
  }

  insertLength += posEnd - position;
  if (insertLength > 0) commands.addInsertOnly(insertLength);
}
