/// Greedy LZ77 command generation ("trawling") for quality 0/1.
///
/// This is the algorithm of `c/enc/compress_fragment_two_pass.c`
/// `CreateCommands`, adapted to absolute input positions (whole input in
/// memory) and to an arbitrary window:
///
/// * scan forward with a stride that grows (`skip >> 5`) while no match is
///   found, so incompressible data is skipped quickly (~5% speed for ~0.1%
///   density on compressible data, a large win on JPEG/ZIP);
/// * try `dist_cache[0]` first (the last emitted distance), then the single
///   slot recorded for the current hash;
/// * after a match, insert the hashes of the positions inside the copy and
///   immediately try to chain another match with no intervening literals.
///
/// The emitted [CommandBuffer] is compact (typed arrays only); the hot loop
/// allocates nothing.
library;

import 'dart:typed_data';

import 'command.dart';
import 'match_finder.dart';

/// Minimum block size for which match searching is attempted.
///
/// Below this the block becomes one insert-only command; the reference encoder
/// uses `BROTLI_WINDOW_GAP` (16) for the same reason.
const int kMinSearchableBlockSize = 16;

/// Generates the command stream for `input[start .. start + blockSize)`.
///
/// [finder] is persistent across calls (hash slots from earlier blocks stay
/// usable); [distCache] carries the four-entry distance cache across blocks and
/// is updated for every emitted copy. [maxDistance] is
/// `(1 << lgwin) - 16` and bounds every copy distance.
void generateCommands(
  Uint8List input,
  int start,
  int blockSize,
  MatchFinder finder,
  CommandBuffer commands,
  Int32List distCache,
  int maxDistance,
) {
  final table = finder.table;
  final minMatch = finder.minMatch;
  final blockEnd = start + blockSize;
  var nextEmit = start;
  var lastDistance = distCache[0];

  if (blockSize >= kMinSearchableBlockSize) {
    final ipLimit = blockEnd - minMatch;
    var ip = start + 1;
    var nextHash = finder.hashAt(input, ip);

    outer:
    while (true) {
      var skip = 32;
      var nextIp = ip;
      var candidate = -1;

      // Trawling: keep scanning until a match within the window is found.
      // `skip`/`nextIp`/`nextHash` intentionally survive a rejected candidate
      // (the reference does this with `goto trawl`).
      while (true) {
        while (true) {
          final hash = nextHash;
          final step = skip++ >> 5;
          ip = nextIp;
          nextIp = ip + step;
          if (nextIp > ipLimit) break outer;
          nextHash = finder.hashAt(input, nextIp);

          var fast = ip - lastDistance;
          if (fast < 0) fast = 0;
          if (fast < ip && isMatch(input, fast, ip, minMatch)) {
            table[hash] = ip + 1;
            candidate = fast;
            break;
          }

          candidate = table[hash] - 1;
          if (candidate < 0) candidate = start;
          table[hash] = ip + 1;
          if (isMatch(input, candidate, ip, minMatch)) break;
        }
        if (ip - candidate <= maxDistance) break;
      }

      // Emit the literals before this match plus the copy command.
      final base = ip;
      final matched =
          minMatch +
          findMatchLength(
            input,
            candidate + minMatch,
            ip + minMatch,
            blockEnd - ip - minMatch,
          );
      final distance = base - candidate;
      final insert = base - nextEmit;
      ip += matched;
      commands.addCopy(insert, matched, distance, maxDistance, distCache);
      lastDistance = distCache[0];
      nextEmit = ip;
      if (ip >= ipLimit) break;
      candidate = finder.insertAndLookup(input, ip);

      // Chain matches that start exactly at the previous copy's end.
      while (candidate >= 0 &&
          ip - candidate <= maxDistance &&
          isMatch(input, candidate, ip, minMatch)) {
        final nextBase = ip;
        final nextMatched =
            minMatch +
            findMatchLength(
              input,
              candidate + minMatch,
              ip + minMatch,
              blockEnd - ip - minMatch,
            );
        ip += nextMatched;
        lastDistance = nextBase - candidate;
        commands.addCopy(0, nextMatched, lastDistance, maxDistance, distCache);
        lastDistance = distCache[0];
        nextEmit = ip;
        if (ip >= ipLimit) break outer;
        candidate = finder.insertAndLookup(input, ip);
      }

      // The failed position was already inserted; resume one byte later.
      ip++;
      if (ip > ipLimit) break;
      nextHash = finder.hashAt(input, ip);
    }
  }

  if (nextEmit < blockEnd) {
    commands.addInsertOnly(blockEnd - nextEmit);
  }
}
