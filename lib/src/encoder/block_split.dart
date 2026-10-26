/// Block splitting and histogram clustering for the encoder (RFC 7932 §6).
///
/// A compressed meta-block may use several *block types* per symbol category
/// (literals, commands, distances). Each block type owns its own entropy code;
/// the symbol stream announces the switch at each block boundary with a
/// `BlockSwitch` code. This is what lets one meta-block adapt its statistics to
/// heterogeneous content (e.g. English text followed by binary data) without
/// paying for a per-segment meta-block header.
///
/// This file ports the *decision* half of `c/enc/block_splitter.c` plus a
/// deterministic histogram clustering inspired by `c/enc/cluster_inc.h`:
///
/// * every category's symbol vector is cut into contiguous chunks of about
///   `symbolsPerHistogram` symbols (capped at `maxHistograms` chunks);
/// * the chunk histograms are merged greedily: the pair whose merge is cheapest
///   is merged first as long as the merge is (nearly) free or more clusters
///   than the category's cap remain;
/// * adjacent chunks that end up in the same cluster collapse into one block,
///   and block types are renumbered by first appearance (the first block is
///   always type 0, which is what the decoder assumes);
/// * per-type histograms are rebuilt from the exact block boundaries, and
///   literal histograms are grouped by `(block type, context)` like the
///   reference's `MapStaticContexts`.
///
/// Deliberate divergence from the reference: C runs a Viterbi pass
/// (`FindBlocks`) with per-symbol entropy-code assignment and several
/// refinement iterations before clustering. We start from uniform chunks and
/// skip that refinement. The encoder compares the split stream against the
/// non-split stream and keeps the smaller one, so the simplification can only
/// cost ratio, never correctness.
library;

import 'dart:typed_data';

import 'command.dart';
import 'context_modeling.dart';
import 'distance_params.dart';

/// Maximum number of chunks considered for literals (`kMaxLiteralHistograms`).
const int kMaxLiteralHistograms = 100;

/// Maximum number of chunks considered for commands (`kMaxCommandHistograms`).
const int kMaxCommandHistograms = 50;

/// Target symbols per literal histogram (`kSymbolsPerLiteralHistogram`).
const int kSymbolsPerLiteralHistogram = 544;

/// Target symbols per command histogram (`kSymbolsPerCommandHistogram`).
const int kSymbolsPerCommandHistogram = 530;

/// Target symbols per distance histogram (`kSymbolsPerDistanceHistogram`).
const int kSymbolsPerDistanceHistogram = 544;

/// Below this symbol count no splitting is attempted
/// (`kMinLengthForBlockSplitting`).
const int kMinLengthForBlockSplitting = 128;

/// `BROTLI_NUM_BLOCK_LEN_SYMBOLS`.
const int kNumBlockLengthCodes = 26;

/// Block length prefix code bases (`_kBrotliPrefixCodeRanges`).
const List<int> kBlockLengthCodeOffset = <int>[
  1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, //
  305, 369, 497, 753, 1265, 2289, 4337, 8433, 16625,
];

/// Block length prefix code extra-bit counts (`_kBrotliPrefixCodeRanges`).
const List<int> kBlockLengthCodeExtraBits = <int>[
  2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, //
  12, 13, 24,
];

/// Default caps on the number of block types per category.
const int kMaxLiteralBlockTypes = 16;
const int kMaxCommandBlockTypes = 8;
const int kMaxDistanceBlockTypes = 8;

/// Minimum entropy saving (bits) for an extra block type to be worth its tree.
const double kBlockClusterMergeThreshold = 96.0;

/// Returns the block-length prefix code for [length] (`BlockLengthPrefixCode`).
int blockLengthPrefixCode(int length) {
  assert(length >= 1);
  var code = length >= 177 ? (length >= 753 ? 20 : 14) : (length >= 41 ? 7 : 0);
  while (code < kNumBlockLengthCodes - 1 &&
      length >= kBlockLengthCodeOffset[code + 1]) {
    code++;
  }
  return code;
}

/// One category's block partition: block types and their symbol lengths.
final class BlockSplit {
  /// Creates a split with [numBlocks] blocks stored in [types]/[lengths].
  const BlockSplit(this.numTypes, this.numBlocks, this.types, this.lengths);

  /// A split with a single block type (and a single block of [length]).
  factory BlockSplit.single(int length) {
    if (length == 0) {
      return BlockSplit(1, 0, Uint8List(0), Uint32List(0));
    }
    return BlockSplit(
      1,
      1,
      Uint8List.fromList(<int>[0]),
      Uint32List.fromList(<int>[length]),
    );
  }

  /// Number of distinct block types (`1` when the category is not split).
  final int numTypes;

  /// Number of blocks (a block is a maximal run of one block type).
  final int numBlocks;

  /// Block type of each block (`0 <= type < numTypes`).
  final Uint8List types;

  /// Number of symbols in each block.
  final Uint32List lengths;
}

/// `BlockTypeCodeCalculator`: codes a block type relative to the previous two.
///
/// The initial state (last = 1, second-last = 0) mirrors the encoder: the first
/// block is never coded and always has type 0, after which both sides of the
/// stream agree on the (second-last = 1, last = 0) state.
final class BlockTypeCodeCalculator {
  int _lastType = 1;
  int _secondLastType = 0;

  /// Returns the code for [type] and advances the state (`NextBlockTypeCode`).
  int next(int type) {
    final code = type == _lastType + 1
        ? 1
        : (type == _secondLastType ? 0 : type + 2);
    _secondLastType = _lastType;
    _lastType = type;
    return code;
  }
}

/// Entropy-based cost of a histogram (bits), plus a small tree-size penalty.
///
/// Mirrors `BrotliPopulationCost` closely enough for the greedy merge: the
/// entropy term dominates for large blocks and the per-symbol penalty biases
/// merges towards fewer, smaller alphabets. Uses [deterministicLog2] so the
/// clustering is identical on the VM and on the web.
double histogramCost(Uint32List histogram, int alphabetSize) {
  var total = 0;
  var entropy = 0.0;
  var used = 0;
  for (var i = 0; i < alphabetSize; i++) {
    final count = histogram[i];
    if (count == 0) continue;
    total += count;
    entropy += count * deterministicLog2(count);
    used++;
  }
  if (total == 0) return 0.0;
  return total * deterministicLog2(total) - entropy + 4.0 * used;
}

/// Sorted indices of the non-zero entries of [histogram].
Uint16List _nonZeroSymbols(Uint32List histogram, int alphabetSize) {
  var n = 0;
  for (var i = 0; i < alphabetSize; i++) {
    if (histogram[i] != 0) n++;
  }
  final out = Uint16List(n);
  n = 0;
  for (var i = 0; i < alphabetSize; i++) {
    if (histogram[i] != 0) out[n++] = i;
  }
  return out;
}

/// Sorted union of two sorted index lists.
Uint16List _unionSymbols(Uint16List a, Uint16List b) {
  final out = Uint16List(a.length + b.length);
  var x = 0;
  var y = 0;
  var n = 0;
  while (x < a.length || y < b.length) {
    if (y >= b.length || (x < a.length && a[x] < b[y])) {
      out[n++] = a[x++];
    } else if (x >= a.length || b[y] < a[x]) {
      out[n++] = b[y++];
    } else {
      out[n++] = a[x++];
      y++;
    }
  }
  return Uint16List.sublistView(out, 0, n);
}

/// [histogramCost] of the element-wise sum of [a] and [b].
///
/// Sparse histograms walk the union of their non-zero symbols ([nonZeroA],
/// [nonZeroB]): exactly the entries the dense loop does not skip, in the same
/// increasing order, so both walks give bit-identical results. Dense ones
/// (binary literals use most of the 256 symbols) are faster with the plain
/// loop, so the walk is chosen per pair.
double _combinedHistogramCost(
  Uint32List a,
  Uint16List nonZeroA,
  Uint32List b,
  Uint16List nonZeroB,
  int alphabetSize,
) {
  if ((nonZeroA.length + nonZeroB.length) * 4 > alphabetSize) {
    var total = 0;
    var entropy = 0.0;
    var used = 0;
    for (var i = 0; i < alphabetSize; i++) {
      final count = a[i] + b[i];
      if (count == 0) continue;
      total += count;
      entropy += count * deterministicLog2(count);
      used++;
    }
    if (total == 0) return 0.0;
    return total * deterministicLog2(total) - entropy + 4.0 * used;
  }
  var total = 0;
  var entropy = 0.0;
  var used = 0;
  var x = 0;
  var y = 0;
  final na = nonZeroA.length;
  final nb = nonZeroB.length;
  while (x < na || y < nb) {
    final int symbol;
    if (y >= nb || (x < na && nonZeroA[x] < nonZeroB[y])) {
      symbol = nonZeroA[x++];
    } else if (x >= na || nonZeroB[y] < nonZeroA[x]) {
      symbol = nonZeroB[y++];
    } else {
      symbol = nonZeroA[x++];
      y++;
    }
    final count = a[symbol] + b[symbol];
    total += count;
    entropy += count * deterministicLog2(count);
    used++;
  }
  if (total == 0) return 0.0;
  return total * deterministicLog2(total) - entropy + 4.0 * used;
}

/// Greedy histogram clustering (`BrotliHistogramCombine`-like).
///
/// Merges the cheapest pair of clusters repeatedly while either more than
/// [maxClusters] remain or the cheapest merge still saves at least
/// [mergeThreshold] bits. Fills [clusterOf] (one entry per input histogram) and
/// writes the merged histograms into [merged] (`maxClusters * alphabetSize`).
///
/// Pair costs are cached, so every merge only recomputes the pairs that involve
/// the merged cluster (`O(k^2)` histogram combinations in total instead of
/// `O(k^3)`).
///
/// Returns the number of clusters.
int clusterHistograms(
  List<Uint32List> histograms,
  int alphabetSize,
  int maxClusters,
  double mergeThreshold,
  Uint8List clusterOf,
  Uint32List merged,
) {
  final count = histograms.length;
  if (count == 0) return 0;
  final live = List<bool>.filled(count, true);
  final mergeInto = List<int>.filled(count, -1);
  final members = <Uint32List>[
    for (final h in histograms) Uint32List.fromList(h.sublist(0, alphabetSize)),
  ];
  final costs = List<double>.filled(count, 0.0);
  for (var i = 0; i < count; i++) {
    costs[i] = histogramCost(members[i], alphabetSize);
  }
  // Pair costs only visit symbols present in either cluster: a 530-symbol
  // command chunk touches a small part of the 704-symbol alphabet.
  final nonZero = <Uint16List>[
    for (final m in members) _nonZeroSymbols(m, alphabetSize),
  ];
  final pairCost = Float64List(count * count)
    ..fillRange(0, count * count, double.infinity);

  void updatePair(int i, int j) {
    if (i > j) {
      final t = i;
      i = j;
      j = t;
    }
    pairCost[i * count + j] =
        _combinedHistogramCost(
          members[i],
          nonZero[i],
          members[j],
          nonZero[j],
          alphabetSize,
        ) -
        costs[i] -
        costs[j];
  }

  for (var i = 0; i < count; i++) {
    for (var j = i + 1; j < count; j++) {
      updatePair(i, j);
    }
  }

  var numClusters = count;
  while (numClusters > 1) {
    var bestI = -1;
    var bestJ = -1;
    var bestDiff = double.infinity;
    for (var i = 0; i < count; i++) {
      if (!live[i]) continue;
      for (var j = i + 1; j < count; j++) {
        if (!live[j]) continue;
        final diff = pairCost[i * count + j];
        if (diff < bestDiff) {
          bestDiff = diff;
          bestI = i;
          bestJ = j;
        }
      }
    }
    if (bestI < 0) break;
    if (numClusters <= maxClusters && bestDiff >= mergeThreshold) break;
    final a = members[bestI];
    final b = members[bestJ];
    for (var k = 0; k < alphabetSize; k++) {
      a[k] = a[k] + b[k];
    }
    nonZero[bestI] = _unionSymbols(nonZero[bestI], nonZero[bestJ]);
    costs[bestI] = histogramCost(a, alphabetSize);
    live[bestJ] = false;
    mergeInto[bestJ] = bestI;
    numClusters--;
    for (var l = 0; l < count; l++) {
      if (!live[l] || l == bestI) continue;
      updatePair(bestI, l);
    }
  }

  // Cluster indexes in order of first appearance (deterministic).
  final index = List<int>.filled(count, -1);
  var next = 0;
  for (var i = 0; i < count; i++) {
    if (!live[i]) continue;
    index[i] = next;
    final base = next * alphabetSize;
    final source = members[i];
    for (var k = 0; k < alphabetSize; k++) {
      merged[base + k] = source[k];
    }
    next++;
  }
  for (var i = 0; i < count; i++) {
    var root = i;
    while (!live[root]) {
      root = mergeInto[root];
    }
    clusterOf[i] = index[root];
  }
  return next;
}

/// Splits one symbol vector into block types (`SplitByteVector`-like).
///
/// [symbols] holds `length` symbols in `[0, alphabetSize)`. Chunks of about
/// [symbolsPerHistogram] symbols are clustered down to at most [maxTypes]
/// types; adjacent chunks of the same type become one block.
BlockSplit splitSymbols(
  Uint16List symbols,
  int length,
  int alphabetSize,
  int symbolsPerHistogram,
  int maxHistograms,
  int maxTypes,
) {
  if (length < kMinLengthForBlockSplitting) {
    return BlockSplit.single(length);
  }
  var numChunks = (length + symbolsPerHistogram - 1) ~/ symbolsPerHistogram;
  if (numChunks < 1) numChunks = 1;
  if (numChunks > maxHistograms) numChunks = maxHistograms;
  if (numChunks == 1) {
    return BlockSplit.single(length);
  }

  // Contiguous, nearly equal chunks.
  final chunkLengths = Uint32List(numChunks);
  final base = length ~/ numChunks;
  final rem = length % numChunks;
  for (var i = 0; i < numChunks; i++) {
    chunkLengths[i] = base + (i < rem ? 1 : 0);
  }
  final chunkHistograms = <Uint32List>[
    for (var i = 0; i < numChunks; i++) Uint32List(alphabetSize),
  ];
  var index = 0;
  for (var chunk = 0; chunk < numChunks; chunk++) {
    final end = index + chunkLengths[chunk];
    final histogram = chunkHistograms[chunk];
    for (var i = index; i < end; i++) {
      histogram[symbols[i]]++;
    }
    index = end;
  }

  final clusterOf = Uint8List(numChunks);
  final merged = Uint32List(maxTypes * alphabetSize);
  final numClusters = clusterHistograms(
    chunkHistograms,
    alphabetSize,
    maxTypes,
    kBlockClusterMergeThreshold,
    clusterOf,
    merged,
  );

  // Collapse adjacent chunks with the same cluster into blocks; renumber types
  // by first appearance so type 0 is first (the first block is never coded and
  // the decoder assumes type 0).
  final typeRemap = List<int>.filled(numClusters, -1);
  var nextType = 0;
  final blockTypes = <int>[];
  final blockLengths = <int>[];
  var currentCluster = -1;
  for (var chunk = 0; chunk < numChunks; chunk++) {
    final cluster = clusterOf[chunk];
    final chunkLen = chunkLengths[chunk];
    if (cluster != currentCluster) {
      var type = typeRemap[cluster];
      if (type < 0) {
        type = nextType++;
        typeRemap[cluster] = type;
      }
      blockTypes.add(type);
      blockLengths.add(chunkLen);
      currentCluster = cluster;
    } else {
      blockLengths[blockLengths.length - 1] += chunkLen;
    }
  }
  return BlockSplit(
    nextType,
    blockTypes.length,
    Uint8List.fromList(blockTypes),
    Uint32List.fromList(blockLengths),
  );
}

/// Everything the split meta-block writer needs for one meta-block.
final class MetaBlockSplit {
  MetaBlockSplit({
    required this.literalSplit,
    required this.commandSplit,
    required this.distanceSplit,
    required this.numLiteralContexts,
    required this.numLiteralTrees,
    required this.literalContextMap,
    required this.literalHistograms,
    required this.commandHistograms,
    required this.distanceHistograms,
    required this.literalBlockTypesByIndex,
    required this.commandBlockTypesByIndex,
    required this.distanceBlockTypesByIndex,
  });

  final BlockSplit literalSplit;
  final BlockSplit commandSplit;
  final BlockSplit distanceSplit;

  /// Number of literal contexts per block type (1, 2 or 3).
  final int numLiteralContexts;

  /// Number of literal Huffman trees (histogram clusters).
  final int numLiteralTrees;

  /// `literalSplit.numTypes * 64` entries mapping (block type, context) to a
  /// literal tree index.
  final Uint8List literalContextMap;

  /// `numLiteralTrees * 256` literal histograms.
  final Uint32List literalHistograms;

  /// `commandSplit.numTypes * 704` command histograms (one per block type).
  final Uint32List commandHistograms;

  /// `distanceSplit.numTypes * 64` distance histograms (one per block type).
  final Uint32List distanceHistograms;

  /// Block type of every literal symbol (in command order).
  final Uint8List literalBlockTypesByIndex;

  /// Block type of every command symbol.
  final Uint8List commandBlockTypesByIndex;

  /// Block type of every distance symbol.
  final Uint8List distanceBlockTypesByIndex;

  /// Whether any category is actually split.
  bool get hasSplits =>
      literalSplit.numTypes > 1 ||
      commandSplit.numTypes > 1 ||
      distanceSplit.numTypes > 1;
}

/// Builds the block split and the per-type histograms for one meta-block.
///
/// [input] is the whole input and `input[start .. start + length)` the
/// meta-block. [contexts] is the literal context model chosen for this block
/// (or `null` for a single literal tree); literals are then grouped by
/// `(block type, context)` exactly like the reference's `MapStaticContexts`.
MetaBlockSplit buildMetaBlockSplit(
  Uint8List input,
  int start,
  int length,
  CommandBuffer commands,
  LiteralContextModel? contexts, {
  DistanceParams? distanceParams,
  int maxLiteralTypes = kMaxLiteralBlockTypes,
  int maxCommandTypes = kMaxCommandBlockTypes,
  int maxDistanceTypes = kMaxDistanceBlockTypes,
}) {
  final numContexts = contexts == null ? 1 : contexts.numClusters;
  final staticMap = contexts?.contextMap;
  final distParams = distanceParams ?? kDefaultDistanceParams;
  final distanceAlphabet = distParams.alphabetSize;
  final distanceBits = Int32List(1);
  final distanceExtra = Int32List(1);

  // Pass 1: collect the literal vector, its context class, the command codes
  // and the distance codes.
  var literalCount = 0;
  var distanceCount = 0;
  for (var i = 0; i < commands.count; i++) {
    literalCount += commands.insertLen[i];
    if (commands.copyLen[i] != 0 && commands.cmdPrefix[i] >= 128) {
      distanceCount++;
    }
  }
  final literals = Uint16List(literalCount);
  final literalContextClass = Uint8List(literalCount);
  final commandSymbols = Uint16List(commands.count);
  final distanceSymbols = Uint16List(distanceCount);
  var literalIndex = 0;
  var distanceIndex = 0;
  var pos = start;
  for (var i = 0; i < commands.count; i++) {
    final insertLen = commands.insertLen[i];
    for (var j = 0; j < insertLen; j++) {
      literals[literalIndex] = input[pos];
      literalContextClass[literalIndex] = staticMap == null
          ? 0
          : staticMap[literalContextId(input, pos)];
      literalIndex++;
      pos++;
    }
    commandSymbols[i] = commands.cmdPrefix[i];
    pos += commands.copyLen[i];
    if (commands.copyLen[i] != 0 && commands.cmdPrefix[i] >= 128) {
      final packed = encodeDistanceCode(
        commands.distCode[i],
        distParams,
        distanceBits,
        distanceExtra,
      );
      distanceSymbols[distanceIndex++] = packed & 0x3FF;
    }
  }

  final literalSplit = splitSymbols(
    literals,
    literalCount,
    256,
    kSymbolsPerLiteralHistogram,
    kMaxLiteralHistograms,
    maxLiteralTypes,
  );
  final commandSplit = splitSymbols(
    commandSymbols,
    commands.count,
    numCommandSymbols,
    kSymbolsPerCommandHistogram,
    kMaxCommandHistograms,
    maxCommandTypes,
  );
  final distanceSplit = splitSymbols(
    distanceSymbols,
    distanceCount,
    distanceAlphabet,
    kSymbolsPerDistanceHistogram,
    kMaxCommandHistograms,
    maxDistanceTypes,
  );

  // Literal block type per literal symbol.
  final literalTypes = Uint8List(literalCount);
  {
    var index = 0;
    for (var b = 0; b < literalSplit.numBlocks; b++) {
      final type = literalSplit.types[b];
      final n = literalSplit.lengths[b];
      for (var k = 0; k < n; k++) {
        literalTypes[index + k] = type;
      }
      index += n;
    }
  }
  // Histograms of (block type, context) pairs, then cluster them.
  final numPairs = literalSplit.numTypes * numContexts;
  final pairHistograms = <Uint32List>[
    for (var i = 0; i < numPairs; i++) Uint32List(numLiteralSymbols),
  ];
  for (var i = 0; i < literalCount; i++) {
    final pair = literalTypes[i] * numContexts + literalContextClass[i];
    pairHistograms[pair][literals[i]]++;
  }
  final maxLiteralTrees = maxLiteralTypes * numContexts;
  final clusterOfPair = Uint8List(numPairs);
  final literalHistogramBuffer = Uint32List(
    maxLiteralTrees * numLiteralSymbols,
  );
  final numLiteralTrees = clusterHistograms(
    pairHistograms,
    numLiteralSymbols,
    maxLiteralTrees,
    kBlockClusterMergeThreshold,
    clusterOfPair,
    literalHistogramBuffer,
  );
  final literalHistograms = Uint32List.sublistView(
    literalHistogramBuffer,
    0,
    numLiteralTrees * numLiteralSymbols,
  );
  final literalContextMap = Uint8List(
    literalSplit.numTypes * kNumLiteralContexts,
  );
  for (var type = 0; type < literalSplit.numTypes; type++) {
    for (var ctx = 0; ctx < kNumLiteralContexts; ctx++) {
      final contextClass = staticMap == null ? 0 : staticMap[ctx];
      literalContextMap[type * kNumLiteralContexts + ctx] =
          clusterOfPair[type * numContexts + contextClass];
    }
  }

  // Command and distance histograms: one per block type.
  final commandHistograms = Uint32List(
    commandSplit.numTypes * numCommandSymbols,
  );
  final commandTypes = Uint8List(commands.count);
  {
    var index = 0;
    for (var b = 0; b < commandSplit.numBlocks; b++) {
      final type = commandSplit.types[b];
      final n = commandSplit.lengths[b];
      for (var k = 0; k < n; k++) {
        commandTypes[index + k] = type;
        commandHistograms[type * numCommandSymbols +
            commandSymbols[index + k]]++;
      }
      index += n;
    }
  }
  final distanceHistograms = Uint32List(
    distanceSplit.numTypes * distanceAlphabet,
  );
  final distanceTypes = Uint8List(distanceCount);
  {
    var index = 0;
    for (var b = 0; b < distanceSplit.numBlocks; b++) {
      final type = distanceSplit.types[b];
      final n = distanceSplit.lengths[b];
      for (var k = 0; k < n; k++) {
        distanceTypes[index + k] = type;
        distanceHistograms[type * distanceAlphabet +
            distanceSymbols[index + k]]++;
      }
      index += n;
    }
  }

  return MetaBlockSplit(
    literalSplit: literalSplit,
    commandSplit: commandSplit,
    distanceSplit: distanceSplit,
    numLiteralContexts: numContexts,
    numLiteralTrees: numLiteralTrees,
    literalContextMap: literalContextMap,
    literalHistograms: literalHistograms,
    commandHistograms: commandHistograms,
    distanceHistograms: distanceHistograms,
    literalBlockTypesByIndex: literalTypes,
    commandBlockTypesByIndex: commandTypes,
    distanceBlockTypesByIndex: distanceTypes,
  );
}
