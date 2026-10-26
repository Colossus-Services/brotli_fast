/// RFC 7932 insert/copy length codes, command prefixes and distance codes.
///
/// These are the exact tables and formulas used by the reference encoder
/// (`c/enc/command.h`, `c/enc/prefix.h`, `c/enc/backward_references.c`), ported
/// to 32-bit-safe Dart. The command stream itself is stored in [CommandBuffer]
/// as parallel typed arrays so a full block produces no per-command garbage.
///
/// Bit layout recap (all values are written LSB-first by `BitWriter`):
///
/// ```text
/// command symbol  (0..703)     = CombineLengthCodes(inscode, copycode, last)
/// insert extra bits            = insertLen - kInsBase[inscode]
/// copy extra bits              = copyLenCode - kCopyBase[copycode]
/// ... literals ...
/// distance symbol + extra bits (only when copyLen != 0 && cmdPrefix >= 128)
/// ```
library;

import 'dart:typed_data';

import '../common/bit_utils.dart';

/// Number of literal symbols in the RFC 7932 literal alphabet.
const int numLiteralSymbols = 256;

/// Number of insert-and-copy length symbols ("command" alphabet).
const int numCommandSymbols = 704;

/// Number of short distance codes (the implicit distance cache references).
const int numDistanceShortCodes = 16;

/// Distance alphabet size for `NPOSTFIX == 0` and `NDIRECT == 0`.
///
/// `BROTLI_DISTANCE_ALPHABET_SIZE(0, 0, 24) = 16 + 0 + (24 << 1)`.
const int numDistanceSymbols = 64;

/// `BROTLI_WINDOW_GAP`: distances larger than `(1 << lgwin) - 16` are illegal.
const int windowGap = 16;

/// Insert-length code bases (`kBrotliInsBase`).
const List<int> kInsBase = <int>[
  0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, //
  34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594,
];

/// Insert-length extra-bit counts (`kBrotliInsExtra`).
const List<int> kInsExtra = <int>[
  0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, //
  4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24,
];

/// Copy-length code bases (`kBrotliCopyBase`).
const List<int> kCopyBase = <int>[
  2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, //
  22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118,
];

/// Copy-length extra-bit counts (`kBrotliCopyExtra`).
const List<int> kCopyExtra = <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, //
  3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24,
];

/// `Log2FloorNonZero` from the reference encoder; [value] must be positive.
int log2FloorNonZero(int value) {
  assert(value > 0);
  return log2Floor(value);
}

/// Returns the insert-length code for [insertLen] (`GetInsertLengthCode`).
int getInsertLengthCode(int insertLen) {
  assert(insertLen >= 0);
  if (insertLen < 6) return insertLen;
  if (insertLen < 130) {
    final nbits = log2FloorNonZero(insertLen - 2) - 1;
    return (nbits << 1) + ((insertLen - 2) >> nbits) + 2;
  }
  if (insertLen < 2114) return log2FloorNonZero(insertLen - 66) + 10;
  if (insertLen < 6210) return 21;
  if (insertLen < 22594) return 22;
  return 23;
}

/// Returns the copy-length code for [copyLen] (`GetCopyLengthCode`).
int getCopyLengthCode(int copyLen) {
  assert(copyLen >= 2);
  if (copyLen < 10) return copyLen - 2;
  if (copyLen < 134) {
    final nbits = log2FloorNonZero(copyLen - 6) - 1;
    return (nbits << 1) + ((copyLen - 6) >> nbits) + 4;
  }
  if (copyLen < 2118) return log2FloorNonZero(copyLen - 70) + 12;
  return 23;
}

/// Combines insert and copy length codes into a command prefix code.
///
/// Ported verbatim from `CombineLengthCodes`; the `0x520D40` constant encodes
/// the four command-prefix groups of RFC 7932 §5.
int combineLengthCodes(int insCode, int copyCode, bool useLastDistance) {
  final bits64 = (copyCode & 0x7) | ((insCode & 0x7) << 3);
  if (useLastDistance && insCode < 8 && copyCode < 16) {
    return copyCode < 8 ? bits64 : (bits64 | 64);
  }
  var offset = 2 * ((copyCode >> 3) + 3 * (insCode >> 3));
  offset = (offset << 5) + 0x40 + ((0x520D40 >> offset) & 0xC0);
  return offset | bits64;
}

/// Returns the command prefix code for an insert/copy length pair.
int getLengthCode(int insertLen, int copyLen, bool useLastDistance) {
  return combineLengthCodes(
    getInsertLengthCode(insertLen),
    getCopyLengthCode(copyLen),
    useLastDistance,
  );
}

/// Maps a real backward [distance] to a distance code.
///
/// Codes `0..15` are the short codes (distance-cache references, no extra
/// bits); larger codes are `distance + 15` and are prefix-coded by
/// [prefixEncodeCopyDistance]. Mirrors `ComputeDistanceCode` including its two
/// 28-bit nibble tables (which encode `cache[i] ± 1..3`).
int computeDistanceCode(int distance, int maxDistance, Int32List distCache) {
  if (distance <= maxDistance) {
    if (distance == distCache[0]) return 0;
    if (distance == distCache[1]) return 1;
    final distancePlus3 = distance + 3;
    final offset0 = distancePlus3 - distCache[0];
    if (offset0 >= 0 && offset0 < 7) {
      return (0x9750468 >> (4 * offset0)) & 0xF;
    }
    final offset1 = distancePlus3 - distCache[1];
    if (offset1 >= 0 && offset1 < 7) {
      return (0xFDB1ACE >> (4 * offset1)) & 0xF;
    }
    if (distance == distCache[2]) return 2;
    if (distance == distCache[3]) return 3;
  }
  return distance + numDistanceShortCodes - 1;
}

/// Prefix-encodes a distance code (`PrefixEncodeCopyDistance`).
///
/// Returns the distance *symbol* and writes the number of extra bits and the
/// extra-bit value to [outBits] / [outExtra]. Stage 1 always uses
/// `ndirect == 0` and `npostfix == 0`, but the general formula is kept because
/// it is only three extra terms.
///
/// The C encoder packs symbol and bit count as `symbol | (nbits << 10)`; this
/// helper returns the same packing to keep the command buffer compact.
int prefixEncodeCopyDistance(
  int distanceCode,
  int numDirectCodes,
  int postfixBits,
  Int32List outBits,
  Int32List outExtra,
) {
  final shortThreshold = numDistanceShortCodes + numDirectCodes;
  if (distanceCode < shortThreshold) {
    outBits[0] = 0;
    outExtra[0] = 0;
    return distanceCode;
  }
  final postfixMask = (1 << postfixBits) - 1;
  final dist = (1 << (postfixBits + 2)) + (distanceCode - shortThreshold);
  final bucket = log2FloorNonZero(dist) - 1;
  final prefixBit = (dist >> bucket) & 1;
  final postfix = dist & postfixMask;
  final offset = (2 + prefixBit) << bucket;
  final nbits = bucket - postfixBits;
  final symbol =
      numDistanceShortCodes +
      numDirectCodes +
      ((2 * (nbits - 1) + prefixBit) << postfixBits) +
      postfix;
  outBits[0] = nbits;
  outExtra[0] = (dist - offset) >> postfixBits;
  return symbol | (nbits << 10);
}

/// Packs the insert/copy extra bits into the order the decoder reads them.
///
/// The reference implementation computes
/// `(copyExtraValue << insertExtraBits) | insertExtraValue` and writes it as a
/// single wide field. Here the same bit sequence is emitted as two `writeBits`
/// calls (low insert bits first, then copy bits), which is identical LSB-first
/// and avoids any write wider than 24 bits.
int commandInsertExtraValue(int insertLen, int insCode) =>
    insertLen - kInsBase[insCode];

/// Copy extra-bit value for [copyLen] (equal to `copyLenCode` in Stage 1).
int commandCopyExtraValue(int copyLen, int copyCode) =>
    copyLen - kCopyBase[copyCode];

/// One block's worth of LZ77 commands, stored as parallel typed arrays.
///
/// Field meaning per command `i`:
/// * [insertLen]  - literal bytes before the copy;
/// * [copyLen]    - copy length (0 only for the final insert-only command);
/// * [cmdPrefix]  - command alphabet symbol;
/// * [distPrefix] - distance symbol in bits `0..9`, extra-bit count in
///   bits `10..15` (the C `dist_prefix_` layout), encoded with the default
///   distance parameters (`NPOSTFIX = NDIRECT = 0`);
/// * [distExtra]  - distance extra-bit value (default parameters);
/// * [distCode]   - parameter-independent distance code (0..15 are the short
///   cache codes, larger values are `distance + 15`); used to re-encode the
///   distances when a meta-block picks non-default distance parameters.
final class CommandBuffer {
  /// Creates a buffer holding up to [capacity] commands.
  CommandBuffer(int capacity)
    : capacity = capacity,
      insertLen = Uint32List(capacity),
      copyLen = Uint32List(capacity),
      cmdPrefix = Uint16List(capacity),
      distPrefix = Uint16List(capacity),
      distExtra = Uint32List(capacity),
      distCode = Uint32List(capacity);

  /// Maximum number of commands this buffer can hold.
  final int capacity;

  /// Number of valid commands at the front of the arrays.
  int count = 0;

  final Uint32List insertLen;
  final Uint32List copyLen;
  final Uint16List cmdPrefix;
  final Uint16List distPrefix;
  final Uint32List distExtra;

  /// Parameter-independent distance code per command; can exceed 65535 for
  /// far copies, hence 32 bits.
  final Uint32List distCode;

  /// Scratch outputs for [prefixEncodeCopyDistance].
  final Int32List _bitsScratch = Int32List(1);
  final Int32List _extraScratch = Int32List(1);

  /// Drops all commands.
  void clear() {
    count = 0;
  }

  /// Appends a literal run of [insertLen] bytes followed by a copy.
  ///
  /// [distance] must already be a legal backward distance
  /// (`1 <= distance <= maxDistance`). The distance cache [distCache] is
  /// updated exactly like the decoder's four-entry ring buffer.
  void addCopy(
    int insertLen,
    int copyLen,
    int distance,
    int maxDistance,
    Int32List distCache,
  ) {
    assert(count < capacity, 'command buffer overflow');
    assert(insertLen >= 0 && copyLen >= 2);
    final insCode = getInsertLengthCode(insertLen);
    final copyCode = getCopyLengthCode(copyLen);
    final distanceCode = computeDistanceCode(distance, maxDistance, distCache);
    final useLastDistance = distanceCode == 0;
    final packed = prefixEncodeCopyDistance(
      distanceCode,
      0,
      0,
      _bitsScratch,
      _extraScratch,
    );
    final index = count;
    this.insertLen[index] = insertLen;
    this.copyLen[index] = copyLen;
    cmdPrefix[index] = combineLengthCodes(insCode, copyCode, useLastDistance);
    distPrefix[index] = packed & 0x3FF | (_bitsScratch[0] << 10);
    distExtra[index] = _extraScratch[0];
    distCode[index] = distanceCode;
    count = index + 1;
    if (distanceCode > 0 && distance <= maxDistance) {
      _pushDistance(distCache, distance);
    }
  }

  /// Appends `insertLen` literals followed by a copy whose distance is given as
  /// the parameter-independent distance code, without touching the cache.
  ///
  /// The decoder keeps its distance ring unchanged for dictionary references,
  /// so a rewritten parse must not push them.
  void addCopyWithCode(int insertLen, int copyLen, int distanceCode) {
    assert(count < capacity, 'command buffer overflow');
    assert(insertLen >= 0 && copyLen >= 2);
    final insCode = getInsertLengthCode(insertLen);
    final copyCode = getCopyLengthCode(copyLen);
    final useLastDistance = distanceCode == 0;
    final packed = prefixEncodeCopyDistance(
      distanceCode,
      0,
      0,
      _bitsScratch,
      _extraScratch,
    );
    final index = count;
    this.insertLen[index] = insertLen;
    this.copyLen[index] = copyLen;
    cmdPrefix[index] = combineLengthCodes(insCode, copyCode, useLastDistance);
    distPrefix[index] = packed & 0x3FF | (_bitsScratch[0] << 10);
    distExtra[index] = _extraScratch[0];
    distCode[index] = distanceCode;
    count = index + 1;
  }

  /// Appends the trailing insert-only command of a block.
  ///
  /// Mirrors `InitInsertCommand`: `copyLen == 0`, copy length code fixed to 4
  /// (symbol 2) and `useLastDistance == false`, so the decoder never reads a
  /// distance symbol for it.
  void addInsertOnly(int insertLen) {
    assert(count < capacity, 'command buffer overflow');
    final index = count;
    this.insertLen[index] = insertLen;
    copyLen[index] = 0;
    cmdPrefix[index] = getLengthCode(insertLen, 4, false);
    distPrefix[index] = numDistanceShortCodes;
    distExtra[index] = 0;
    distCode[index] = numDistanceShortCodes;
    count = index + 1;
  }

  static void _pushDistance(Int32List distCache, int distance) {
    distCache[3] = distCache[2];
    distCache[2] = distCache[1];
    distCache[1] = distCache[0];
    distCache[0] = distance;
  }
}

/// The distance cache starts as `[4, 11, 15, 16]` (RFC 7932 §4).
Int32List createInitialDistanceCache() =>
    Int32List.fromList(<int>[4, 11, 15, 16]);
