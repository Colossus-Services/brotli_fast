/// Lazy backward-reference search for the quality 4/5 encoder paths.
///
/// This is the algorithm of `c/enc/backward_references_inc.h`
/// `CreateBackwardReferences` with the `HashLongestMatch` hasher, adapted to
/// absolute input positions (the whole input is in memory):
///
/// * for every position, [HashChainMatcher.findLongestMatch] returns the best
///   *scored* match, not just the longest one;
/// * if a match was found, the next position is searched before committing:
///   when it is better by at least [kCostDiffLazy] (a byte of literal is worth
///   135, so ~1.3 literals) the current position is emitted as a literal and
///   the reference is delayed, up to four times in a row (this is the classic
///   1-step lazy matching that removes most of the greedy parse's damage);
/// * the last up-to-16 distances are tried first, and every emitted copy
///   updates the decoder's four-entry distance cache;
/// * after a copy, the hashes of the positions inside it are stored (minus a
///   tail that would run past the block) so later positions can match into it;
/// * a "literal spree" heuristic skips match lookups on incompressible data.
///
/// The emitted [CommandBuffer] is compact (typed arrays only); the hot loop
/// allocates nothing (both search results are reused).
library;

import 'dart:typed_data';

import 'command.dart';
import 'match_finder.dart';

/// Extra score the next-position match needs before the current one is delayed.
const int kCostDiffLazy = 175;

/// How many references may be delayed in a row (C: `< 4` check, i.e. 3 more).
const int kMaxDelayedBackwardReferences = 4;

/// Length of the "no match seen for this long" window after which lookups are
/// skipped (`LiteralSpreeLengthForSparseSearch`; 64 for quality < 9).
const int kLiteralSpreeLength = 64;

/// `HashTypeLength` / `StoreLookahead` of the chain hasher.
const int kHashTypeLength = 4;

/// Minimum block size for which match searching is attempted. Below this the
/// block becomes one insert-only command (`kMinSearchableBlockSize` in the
/// greedy path has the same value and meaning).
const int _kMinSearchableBlockSize = 16;

/// Fills [commands] with the LZ77 parse of `input[start .. start + blockSize)`.
///
/// [hasher] is persistent across calls, so copies may refer to earlier blocks.
/// [distanceCache] must have 16 entries (see [createSearchDistanceCache]); its
/// first four entries are the decoder's cache and are updated for every
/// emitted copy. [maxBackwardLimit] is `(1 << lgwin) - 16`.
///
/// When [commands] returns, the commands cover exactly [blockSize] input bytes:
/// either the last copy ends on the block boundary or a trailing insert-only
/// command emits the remaining literals.
void createBackwardReferences(
  Uint8List input,
  int start,
  int blockSize,
  HashChainMatcher hasher,
  CommandBuffer commands,
  Int32List distanceCache,
  int maxBackwardLimit, {
  required bool extensiveSearch,
}) {
  commands.clear();
  final numDistances = hasher.numLastDistances;
  final posEnd = start + blockSize;
  if (blockSize < _kMinSearchableBlockSize) {
    commands.addInsertOnly(blockSize);
    return;
  }

  // Positions at or after `storeEnd` cannot be hashed: the 4-byte hash would
  // read past the block. (`StoreLookahead() - 1 == 3`.)
  final storeEnd = posEnd - kHashTypeLength + 1;
  var position = start;
  var insertLength = 0;
  var applyRandomHeuristics = start + kLiteralSpreeLength;
  final sr = HasherSearchResult()..reset(kMinScore);
  final sr2 = HasherSearchResult()..reset(kMinScore);

  prepareDistanceCache(distanceCache, numDistances);

  while (position + kHashTypeLength < posEnd) {
    final maxLength = posEnd - position;
    var maxDistance = position < maxBackwardLimit ? position : maxBackwardLimit;

    sr.reset(kMinScore);
    hasher.findLongestMatch(
      input,
      distanceCache,
      numDistances,
      position,
      maxLength,
      maxDistance,
      sr,
    );

    if (sr.score > kMinScore) {
      // Look for something even better one byte ahead.
      var delayed = 0;
      var lazyMaxLength = maxLength - 1;
      while (true) {
        sr2.reset(kMinScore);
        // Qualities below 5 skip the full re-search when the match ahead cannot
        // plausibly beat the current one: seed it with the shortest acceptable
        // length so the scorer rejects weak candidates earlier.
        if (!extensiveSearch) {
          final seed = sr.len - 1;
          sr2.len = seed < lazyMaxLength ? seed : lazyMaxLength;
        }
        final lazyPosition = position + 1;
        final lazyMaxDistance = lazyPosition < maxBackwardLimit
            ? lazyPosition
            : maxBackwardLimit;
        hasher.findLongestMatch(
          input,
          distanceCache,
          numDistances,
          lazyPosition,
          lazyMaxLength,
          lazyMaxDistance,
          sr2,
        );
        if (sr2.score >= sr.score + kCostDiffLazy) {
          // Emit one literal now and start a match from the next byte.
          position++;
          insertLength++;
          sr.copyFrom(sr2);
          delayed++;
          if (delayed < kMaxDelayedBackwardReferences &&
              position + kHashTypeLength < posEnd) {
            lazyMaxLength--;
            continue;
          }
        }
        break;
      }

      applyRandomHeuristics = position + 2 * sr.len + kLiteralSpreeLength;

      final codingMaxDistance = position < maxBackwardLimit
          ? position
          : maxBackwardLimit;
      commands.addCopy(
        insertLength,
        sr.len,
        sr.distance,
        codingMaxDistance,
        distanceCache,
      );
      prepareDistanceCache(distanceCache, numDistances);
      insertLength = 0;

      // Store hashes for the positions inside the copy, but avoid hash
      // poisoning with RLE data: for very short distances the first positions
      // would all hash to the same bucket as the run we just matched.
      var rangeStart = position + 2;
      var rangeEnd = position + sr.len < storeEnd
          ? position + sr.len
          : storeEnd;
      if (sr.distance < (sr.len >> 2)) {
        final avoid = position + sr.len - (sr.distance << 2);
        if (avoid > rangeStart) rangeStart = avoid;
        if (rangeStart > rangeEnd) rangeStart = rangeEnd;
      }
      for (var i = rangeStart; i < rangeEnd; i++) {
        hasher.store(input, i);
      }
      position += sr.len;
    } else {
      insertLength++;
      position++;
      // No match for a long time: assume incompressible data and skip match
      // lookups (storing only every 2nd / 4th position). This is a large speed
      // win on JPEG/ZIP input and costs almost nothing on compressible data.
      if (position > applyRandomHeuristics) {
        if (position > applyRandomHeuristics + 4 * kLiteralSpreeLength) {
          final posJump = position + 16 < posEnd - 4
              ? position + 16
              : posEnd - 4;
          while (position < posJump) {
            hasher.store(input, position);
            insertLength += 4;
            position += 4;
          }
        } else {
          final posJump = position + 8 < posEnd - 3 ? position + 8 : posEnd - 3;
          while (position < posJump) {
            hasher.store(input, position);
            insertLength += 2;
            position += 2;
          }
        }
      }
    }
  }

  insertLength += posEnd - position;
  if (insertLength > 0) commands.addInsertOnly(insertLength);
}
