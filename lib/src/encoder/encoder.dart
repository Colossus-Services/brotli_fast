/// Brotli (RFC 7932) encoder: entry point, block loops and streaming.
///
/// Three strategies share the same framing skeleton:
///
/// * **fast tier** (qualities 0..5 at the default window, no dictionary;
///   `fast_encoder.dart`) - one lazy or greedy parse and one tree set per
///   meta-block. Text at quality 0/1 uses the greedy path below instead.
/// * **greedy** (quality 0/1) - greedy LZ77 (`lz77.dart`) with a single-slot
///   hash match finder and the trivial meta-block layout
///   (`metablock_writer.dart`).
/// * **high ratio** (qualities 2..11 outside the fast tier, and every quality
///   from 6 up) - hash chains with lazy matching (`backward_references.dart`
///   with [HashChainMatcher]): the best *scored* match over 8..256 candidates
///   per bucket and the last-distance cache, plus a one-step look-ahead. Higher
///   qualities add literal context modeling, block splitting, distance
///   parameter search, static/compound dictionary rewrites and cost-guided
///   parses as extra candidates; see [chainParamsForQuality] and the
///   `kMinQualityFor*` constants.
///
/// Each meta-block is compared with its uncompressed framing and rewound if
/// compression did not pay off, so incompressible input still produces
/// ~input-size output.
///
/// The stream always ends with an explicit empty last meta-block, so no
/// uncompressed block ever has to be the last block (which the format forbids).
///
/// Exact bit layout (LSB-first), derived from `c/enc/encode.c`
/// `EncodeWindowBits`, `MakeUncompressedStream` and RFC 7932:
///
/// ```text
/// stream      = window_bits, meta_block*, last_block
/// window_bits = lgwin == 16        -> 1 bit  : 0
///               lgwin == 17        -> 7 bits : 1
///               10 <= lgwin <= 15  -> 7 bits : ((lgwin - 8) << 4) | 1
///               18 <= lgwin <= 24  -> 4 bits : ((lgwin - 17) << 1) | 1
/// meta_block  = 0                        // ISLAST
///               mnibbles-4               // 2 bits, mnibbles in {4,5,6}
///               MLEN-1                   // mnibbles * 4 bits
///               1                        // ISUNCOMPRESSED
///               0-pad to byte boundary
///               MLEN raw bytes
/// last_block  = 1                        // ISLAST
///               1                        // ISEMPTY
///               0-pad to byte boundary
/// ```
///
/// `MLEN` is limited to `2^24`, so larger inputs are split into several blocks.
library;

import 'dart:typed_data';

import '../common/errors.dart';
import '../dictionary.dart';
import '../options.dart';
import 'backward_references.dart';
import 'bit_writer.dart';
import 'block_split.dart';
import 'command.dart';
import 'compound_dictionary.dart';
import 'context_modeling.dart';
import 'cost_model.dart';
import 'distance_params.dart';
import 'fast_encoder.dart';
import 'guided_parse.dart';
import 'lz77.dart';
import 'match_finder.dart';
import 'metablock_writer.dart';
import 'optimal_parse.dart';
import 'split_metablock_writer.dart';
import 'static_dictionary.dart';

/// Smallest RFC 7932 window size accepted by the encoder.
const int _kMinLgwin = 10;

/// Largest regular (non-large-window) RFC 7932 window size.
const int _kMaxLgwin = 24;

/// Largest window accepted by the large-window extension (25..30).
const int _kMaxLargeLgwin = 30;

/// Input block size for quality 0 (fast, 4-byte minimum match).
const int kQuality0BlockSize = 1 << 16;

/// Input block size for quality 1 (6-byte minimum match).
const int kQuality1BlockSize = 1 << 17;

/// Input block size for the chain path (qualities 2..11).
///
/// The reference encoder uses `lgblock = 16` at quality 4 and relies on block
/// splitting to recover adaptivity; below quality 6 we emit one Huffman tree
/// set per block, so a 128 KiB block (two tree sets per 256 KiB) measures
/// better on text and much better on RLE-heavy input.
const int kChainBlockSize = 1 << 17;

/// Hash-chain parameters for every chain-path quality, mirroring
/// `ChooseHasher` in `c/enc/quality.h` for the `lgwin > 16`, `size_hint <
/// 1 MiB` case (H5/H6 chains):
///
/// | quality | bucket bits | candidates | last distances |
/// |---------|-------------|------------|----------------|
/// | 2, 3, 4 | 14          | 8          | 4              |
/// | 5       | 14          | 16         | 4              |
/// | 6       | 14          | 32         | 4              |
/// | 7       | 15          | 64         | 10             |
/// | 8       | 15          | 128        | 10             |
/// | 9..11   | 15          | 256        | 16             |
///
/// Qualities 2..4 share one configuration: 8 candidates and the seeded (cheap)
/// lazy look-ahead. Quality 5 raises the candidate count and switches to the
/// full lazy search; higher qualities raise it further. Qualities 10/11 reuse
/// the quality 9 chain and add the cost-model-guided parses on top.
final class ChainParams {
  const ChainParams({
    required this.bucketBits,
    required this.blockBits,
    required this.numLastDistances,
  });

  final int bucketBits;
  final int blockBits;
  final int numLastDistances;
}

/// Returns the chain-matcher parameters for [quality] (clamped to `2..9`).
ChainParams chainParamsForQuality(int quality) {
  if (quality <= 4) {
    return const ChainParams(bucketBits: 14, blockBits: 3, numLastDistances: 4);
  }
  if (quality == 5) {
    return const ChainParams(bucketBits: 14, blockBits: 4, numLastDistances: 4);
  }
  if (quality == 6) {
    return const ChainParams(bucketBits: 14, blockBits: 5, numLastDistances: 4);
  }
  if (quality == 7) {
    return const ChainParams(
      bucketBits: 15,
      blockBits: 6,
      numLastDistances: 10,
    );
  }
  if (quality == 8) {
    return const ChainParams(
      bucketBits: 15,
      blockBits: 7,
      numLastDistances: 10,
    );
  }
  return const ChainParams(bucketBits: 15, blockBits: 8, numLastDistances: 16);
}

/// Lowest quality that uses literal context modeling; below this a single
/// literal Huffman tree is emitted (`MIN_QUALITY_FOR_CONTEXT_MODELING` is 5 in
/// the reference, but qualities 4/5 keep the faster single-tree layout).
const int kMinQualityForContextModeling = 6;

/// Lowest quality that tries block splitting (`MIN_QUALITY_FOR_BLOCK_SPLIT` is
/// 4 in the reference; lower tiers stay on their faster path and the split is
/// only kept when it actually shrinks the block).
const int kMinQualityForBlockSplitting = 6;

/// Lowest quality that uses the full (non-seeded) lazy look-ahead; qualities
/// 2..4 seed the look-ahead with the current match length like the reference
/// does below `MIN_QUALITY_FOR_EXTENSIVE_REFERENCE_SEARCH`.
const int kMinQualityForExtensiveSearch = 5;

/// Lowest quality that searches `NPOSTFIX` / `NDIRECT` per meta-block. The
/// search only re-encodes distances (never the LZ77 parse), so lower tiers keep
/// their byte-stable `(0, 0)` output.
const int kMinQualityForDistanceParams = 8;

/// Lowest quality that applies the RLE-friendly histogram adjustment before
/// building the Huffman trees (`MIN_QUALITY_FOR_OPTIMIZE_HISTOGRAMS`).
const int kMinQualityForOptimizedHistograms = 8;

/// Lowest quality that also runs a cost-model-guided parse (see
/// `guided_parse.dart`). The guided parse is an extra candidate: it is kept only
/// when it serialises smaller than the lazy chain parse, so quality 10 can
/// never be worse than quality 9.
const int kMinQualityForGuidedParsing = 10;

/// Lowest quality that tries static-dictionary matches as an extra parse.
const int kMinQualityForStaticDictionary = 5;

/// Blocks shorter than this skip the dictionary rewrite (nothing to gain).
const int kMinDictionaryBlockSize = 64;

/// Lowest quality that runs a second, deeper guided pass (two-literal lazy
/// look-ahead) on top of the quality 10 pass, so quality 11 is always at least
/// as good as quality 10.
const int kMinQualityForDeeperGuidedParsing = 11;

/// Blocks shorter than this skip the guided passes: the cost model and the
/// extra serialisations do not pay off on tiny blocks.
const int kMinGuidedParseBlockSize = 4096;

/// Compresses one complete buffer into a Brotli stream.
///
/// Qualities 0..5 at the default window without a dictionary take the fast
/// tier (`fast_encoder.dart`), except text at quality 0/1, which the greedy
/// path below handles better. Everything else takes the high-ratio path: hash
/// chains with lazy matching, and from quality 6 on literal context modeling
/// and block splitting, from quality 8 searched distance parameters, and at
/// 10/11 cost-model-guided parses. Every candidate encoding of a meta-block
/// is only kept when it is smaller, and every meta-block falls back to
/// uncompressed storage when that is smaller still.
///
/// [BrotliEncodeOptions.lgwin] (`10..24`, or `25..30` for large-window
/// streams) is written to the stream header and bounds backward distances at
/// `(1 << lgwin) - 16`.
///
/// An empty input produces the canonical single byte `0x06` (16-bit window,
/// empty last meta-block), matching the C encoder's special case.
Uint8List encode(Uint8List input, BrotliEncodeOptions options) {
  final quality = _clamp(options.quality, 0, 11);
  final largeWindow = options.largeWindow;
  if (!largeWindow && options.lgwin > _kMaxLgwin) {
    throw BrotliException(
      BrotliErrorCode.unsupportedFeature,
      'lgwin ${options.lgwin} needs largeWindow: true (large-window streams) ',
    );
  }
  final lgwin = largeWindow
      ? _clamp(options.lgwin, _kMinLgwin, _kMaxLargeLgwin)
      : _clamp(options.lgwin, _kMinLgwin, _kMaxLgwin);

  if (input.isEmpty) {
    // For any configured window, [0x06] = window 16 + `11` empty last block.
    return Uint8List.fromList(const <int>[0x06]);
  }

  final writer = BitWriter(initialCapacity: input.length + 16);
  _writeWindowBits(
    writer,
    lgwin,
    largeWindow: largeWindow && lgwin > _kMaxLgwin,
  );

  final fastParams = fastParamsFor(input, options);
  if (fastParams != null) {
    writeFastMetaBlocks(writer, input, fastParams);
  } else if (quality <= 1) {
    _writeGreedyCompressedBlocks(writer, input, quality, lgwin);
  } else {
    _writeChainCompressedBlocks(
      writer,
      input,
      quality,
      lgwin,
      sizeHint: options.sizeHint ?? input.length,
      dictionary: options.dictionary,
    );
  }

  writer.writeBits(1, 1); // ISLAST
  writer.writeBits(1, 1); // ISEMPTY
  writer.alignToByte();

  final output = writer.toBytes();
  assert(
    output.length <= maxCompressedSize(input.length),
    'compressed output exceeds maxCompressedSize',
  );
  return output;
}

/// Upper bound on the size of [encode] output for [inputSize] bytes.
///
/// Mirrors `BrotliEncoderMaxCompressedSize`: `input + 2 + 4*(input>>14) + 4`,
/// i.e. stream header, up to 4 overhead bytes per 16 KiB of input (uncompressed
/// meta-block headers plus worst-case fallback framing) and the final empty
/// block. The bound is intentionally loose; every encoder stage must never
/// produce more bytes than uncompressed framing, which this module guarantees
/// by rewinding blocks that do not compress.
///
/// Returns `2` for empty input (the canonical single-byte stream plus slack),
/// and `0` only if the bound would overflow the platform `int`.
int maxCompressedSize(int inputSize) {
  if (inputSize < 0) {
    throw ArgumentError.value(inputSize, 'inputSize', 'must be non-negative');
  }
  if (inputSize == 0) return 2;
  // `~/` instead of `>>` so the computation is 32-bit safe on the web.
  final numLargeBlocks = inputSize ~/ 16384;
  final overhead = 2 + 4 * numLargeBlocks + 3 + 1;
  final result = inputSize + overhead;
  return result < inputSize ? 0 : result;
}

/// Writes the RFC 7932 window-bits header for [lgwin] (`10..24`).
void _writeWindowBits(BitWriter writer, int lgwin, {bool largeWindow = false}) {
  if (largeWindow && lgwin > _kMaxLgwin) {
    // Non-RFC large-window extension: 14 bits ((lgwin & 0x3F) << 8) | 0x11.
    // Bit layout: 1 (not 16), 000 (no 17..24 code), 001 (large window),
    // 0 (reserved), then the 6-bit window size.
    writer.writeBits(14, ((lgwin & 0x3F) << 8) | 0x11);
    return;
  }
  if (lgwin == 16) {
    writer.writeBits(1, 0);
  } else if (lgwin == 17) {
    writer.writeBits(7, 1);
  } else if (lgwin > 17) {
    writer.writeBits(4, ((lgwin - 17) << 1) | 1);
  } else {
    writer.writeBits(7, ((lgwin - 8) << 4) | 1);
  }
}

/// Persistent state of the greedy block loop (qualities 0/1).
///
/// The [BrotliEncoder] keeps one of these alive so consecutive [add]/[flush]
/// calls continue the same stream with the same match finder and distance
/// cache.
final class _GreedyState {
  _GreedyState({
    required this.finder,
    required this.commands,
    required this.metaBlockWriter,
    required this.distCache,
  });

  /// Creates the state for [quality] (0/1), sized for [blockSize].
  factory _GreedyState.forQuality(int quality, int blockSize) {
    final minMatch = quality == 0 ? 4 : 6;
    return _GreedyState(
      finder: MatchFinder(
        tableBits: quality == 0 ? 16 : 17,
        minMatch: minMatch,
      ),
      // A copy always covers at least `minMatch` bytes, so this capacity can
      // never be exceeded; the extra entries cover the trailing insert-only
      // command.
      commands: CommandBuffer(blockSize ~/ minMatch + 2),
      metaBlockWriter: MetaBlockWriter(),
      distCache: createInitialDistanceCache(),
    );
  }

  final MatchFinder finder;
  final CommandBuffer commands;
  final MetaBlockWriter metaBlockWriter;
  final Int32List distCache;
}

/// Persistent state of the chain block loop (qualities 2..11).
final class _ChainState {
  _ChainState({
    required this.hasher,
    required this.commands,
    required this.metaBlockWriter,
    required this.splitWriter,
    required this.distCache,
  });

  /// Creates the state for [quality] (2..11), sized for [blockSize].
  factory _ChainState.forQuality(int quality, int blockSize) {
    final params = chainParamsForQuality(quality);
    return _ChainState(
      hasher: HashChainMatcher(
        bucketBits: params.bucketBits,
        blockBits: params.blockBits,
        numLastDistances: params.numLastDistances,
      ),
      // A copy covers at least 2 bytes, so this capacity can never be
      // exceeded.
      commands: CommandBuffer(blockSize ~/ 2 + 2),
      metaBlockWriter: MetaBlockWriter(),
      splitWriter: SplitMetaBlockWriter(),
      distCache: createSearchDistanceCache(),
    );
  }

  final HashChainMatcher hasher;
  final CommandBuffer commands;
  final MetaBlockWriter metaBlockWriter;
  final SplitMetaBlockWriter splitWriter;
  final Int32List distCache;
}

/// Quality 0/1 strategy: greedy LZ77 blocks with dynamic Huffman trees.
void _writeGreedyCompressedBlocks(
  BitWriter writer,
  Uint8List input,
  int quality,
  int lgwin, {
  int start = 0,
  int? end,
  _GreedyState? continuation,
}) {
  final blockSize = quality == 0 ? kQuality0BlockSize : kQuality1BlockSize;
  final maxDistance = (1 << lgwin) - windowGap;
  final distanceParams = _distanceParamsForLgwin(lgwin);
  final state = continuation ?? _GreedyState.forQuality(quality, blockSize);
  final finder = state.finder;
  final commands = state.commands;
  final metaBlockWriter = state.metaBlockWriter;
  final distCache = state.distCache;

  final stop = end ?? input.length;
  var offset = start;
  while (offset < stop) {
    final remaining = stop - offset;
    final length = remaining < blockSize ? remaining : blockSize;

    // The distance cache is decoder state: if this block is stored
    // uncompressed (because compression did not help) its commands never reach
    // the decoder, so the cache must be rolled back too.
    final saved0 = distCache[0];
    final saved1 = distCache[1];
    final saved2 = distCache[2];
    final saved3 = distCache[3];

    commands.clear();
    generateCommands(
      input,
      offset,
      length,
      finder,
      commands,
      distCache,
      maxDistance,
    );

    final mark = writer.mark();
    metaBlockWriter.store(
      writer,
      input,
      offset,
      length,
      commands,
      isLast: false,
      distanceParams: distanceParams,
    );
    final compressedBits = writer.bitPosition - mark;
    if (compressedBits > uncompressedMetaBlockBits(length, mark)) {
      writer.rewind(mark);
      distCache[0] = saved0;
      distCache[1] = saved1;
      distCache[2] = saved2;
      distCache[3] = saved3;
      writeUncompressedMetaBlock(writer, input, offset, length);
    }
    offset += length;
  }
}

/// Quality 2..11 strategy: hash chains with lazy matching.
///
/// The matcher and the distance cache are persistent across meta-blocks (the
/// hasher stores absolute positions, so a copy may reach into a previous
/// block). Everything else is shared with the greedy path: one tree set per
/// meta-block, per-block comparison against uncompressed framing and a rewind
/// with a distance-cache rollback when compression does not pay off.
///
/// From [kMinQualityForContextModeling] on, each meta-block decides whether
/// literal context modeling pays off (`ChooseContextMap` heuristic) and, if so,
/// codes literals with 2 or 3 context-conditioned Huffman trees. From
/// [kMinQualityForBlockSplitting] on, a block-split meta-block (several block
/// types per category) is serialised as an extra candidate; the smallest
/// candidate wins, so splitting can never make the output larger. From
/// [kMinQualityForDistanceParams] on the split candidate is also tried with a
/// searched `NPOSTFIX` / `NDIRECT` pair and with
/// [kMinQualityForOptimizedHistograms] on with RLE-friendly tree histograms;
/// both are again decided by the serialised size.
void _writeChainCompressedBlocks(
  BitWriter writer,
  Uint8List input,
  int quality,
  int lgwin, {
  int start = 0,
  int? end,
  int? sizeHint,
  BrotliDictionary? dictionary,
  _ChainState? continuation,
}) {
  const blockSize = kChainBlockSize;
  final maxBackwardLimit = (1 << lgwin) - windowGap;
  // Large-window streams carry up to 30-bit distances and need a wider
  // distance alphabet; regular streams keep the 64-symbol alphabet.
  final distanceMaxBits = lgwin > _kMaxLgwin
      ? kMaxLargeDistanceBits
      : kMaxDistanceBits;
  final defaultParams = distanceMaxBits <= kMaxDistanceBits
      ? kDefaultDistanceParams
      : DistanceParams(0, 0, maxDistanceBits: distanceMaxBits);
  final useContexts = quality >= kMinQualityForContextModeling;
  final useBlockSplitting = quality >= kMinQualityForBlockSplitting;
  final useGuidedParsing = quality >= kMinQualityForGuidedParsing;
  final useOptimalParsing = quality >= kMinQualityForGuidedParsing;
  final useStaticDictionary = quality >= kMinQualityForStaticDictionary;
  final compoundSize = dictionary?.length ?? 0;
  final compoundMatcher = useStaticDictionary && compoundSize > 0
      ? dictionaryMatcher(dictionary!)
      : null;
  final useDistanceParams = quality >= kMinQualityForDistanceParams;
  final optimizeHistograms = quality >= kMinQualityForOptimizedHistograms;
  final extensiveSearch = quality >= kMinQualityForExtensiveSearch;

  final state = continuation ?? _ChainState.forQuality(quality, blockSize);
  final hasher = state.hasher;
  final commands = state.commands;
  final metaBlockWriter = state.metaBlockWriter;
  final splitWriter = state.splitWriter;
  final distCache = state.distCache;

  final stop = end ?? input.length;
  var offset = start;
  while (offset < stop) {
    final remaining = stop - offset;
    final length = remaining < blockSize ? remaining : blockSize;

    // The distance cache is decoder state: if this block is stored
    // uncompressed (because compression did not help) its commands never reach
    // the decoder, so the cache must be rolled back too. Entries 4..15 are
    // derived and re-prepared from the first four.
    final saved0 = distCache[0];
    final saved1 = distCache[1];
    final saved2 = distCache[2];
    final saved3 = distCache[3];

    createBackwardReferences(
      input,
      offset,
      length,
      hasher,
      commands,
      distCache,
      maxBackwardLimit,
      extensiveSearch: extensiveSearch,
    );

    // Parse candidates: the lazy chain parse (every quality) and, from
    // kMinQualityForGuidedParsing on, cost-model-guided parses. Each parse is
    // serialised through the same candidate machinery (single tree set,
    // contexts, block split x distance params x RLE) and only the smallest
    // result is written, so a guided parse can never make a block larger and
    // must beat the chain parse to be kept.
    final contextModel = useContexts
        ? chooseLiteralContextModel(
            input,
            offset,
            length,
            quality,
            sizeHint: sizeHint ?? input.length,
          )
        : null;

    final mark = writer.mark();
    final uncompressedBits = uncompressedMetaBlockBits(length, mark);
    // 0 = single tree set, 1 = contexts, 2 = block split.
    var bestKind = 0;
    var bestParse = 0;
    MetaBlockSplit? bestSplit;
    var bestParams = defaultParams;
    var bestRle = false;
    var bestBits = -1;
    var wroteCandidate = false;

    final parses = <({CommandBuffer commands, Int32List endCache})>[
      (commands: commands, endCache: _snapshotDistanceCache(distCache)),
    ];

    void consider(void Function() write, int kind, int parseIndex) {
      if (wroteCandidate) writer.rewind(mark);
      write();
      wroteCandidate = true;
      final bits = writer.bitPosition - mark;
      if (bestBits < 0 || bits < bestBits) {
        bestBits = bits;
        bestKind = kind;
        bestParse = parseIndex;
      }
    }

    void evaluateParse(int parseIndex, CommandBuffer cmds) {
      consider(
        () {
          metaBlockWriter.store(
            writer,
            input,
            offset,
            length,
            cmds,
            isLast: false,
            distanceParams: defaultParams,
          );
        },
        0,
        parseIndex,
      );
      if (contextModel != null) {
        consider(
          () {
            metaBlockWriter.store(
              writer,
              input,
              offset,
              length,
              cmds,
              isLast: false,
              contexts: contextModel,
              distanceParams: defaultParams,
            );
          },
          1,
          parseIndex,
        );
      }
      // Only try splitting when the block actually compresses: if the
      // uncompressed fallback already wins, the (relatively expensive) split
      // analysis cannot change the outcome.
      if (!useBlockSplitting || bestBits >= uncompressedBits) return;
      final searched = useDistanceParams
          ? chooseDistanceParams(cmds, maxDistanceBits: distanceMaxBits)
          : defaultParams;
      // Only pay for a second split analysis when the search actually found a
      // cheaper distance coding; equal-cost pairs keep the default.
      final searchedIsBetter =
          !searched.isDefault &&
          distanceCost(cmds, searched) < distanceCost(cmds, defaultParams);
      final paramOptions = searchedIsBetter
          ? <DistanceParams>[defaultParams, searched]
          : <DistanceParams>[defaultParams];
      for (final params in paramOptions) {
        final candidate = buildMetaBlockSplit(
          input,
          offset,
          length,
          cmds,
          contextModel,
          distanceParams: params,
        );
        if (!candidate.hasSplits) continue;
        for (final rle in <bool>[false, if (optimizeHistograms) true]) {
          final before = bestBits;
          consider(
            () {
              splitWriter.store(
                writer,
                input,
                offset,
                length,
                cmds,
                candidate,
                isLast: false,
                distanceParams: params,
                optimizeHistograms: rle,
              );
            },
            2,
            parseIndex,
          );
          if (bestBits < before) {
            bestSplit = candidate;
            bestParams = params;
            bestRle = rle;
          }
        }
      }
    }

    evaluateParse(0, commands);

    // Bounded optimal (DP) candidate: a shortest-path parse priced by the
    // previous parse's histograms. It can defer copies by several literals,
    // which is what lets quality 10/11 beat the lazy parse on English text.
    if (useOptimalParsing &&
        length >= kMinGuidedParseBlockSize &&
        bestBits * 5 < uncompressedBits * 4) {
      var optimalModel = ParseCostModel.fromCommands(
        input,
        offset,
        length,
        commands,
      );
      final passes = quality >= kMinQualityForDeeperGuidedParsing ? 2 : 1;
      // The two passes search the same positions with the same caps and a
      // rolled-back matcher state, so the first pass fills a match cache the
      // second one reuses; that halves quality 11's dominant search cost
      // without changing the resulting parse.
      final matchLen = Int32List(passes > 1 ? length : 0);
      final matchDist = Int32List(passes > 1 ? length : 0);
      final matchValid = Uint8List(passes > 1 ? length : 0);
      for (var pass = 0; pass < passes; pass++) {
        distCache[0] = saved0;
        distCache[1] = saved1;
        distCache[2] = saved2;
        distCache[3] = saved3;
        final optimal = CommandBuffer(blockSize ~/ 2 + 2);
        hasher.beginJournal(length + 4);
        createOptimalBackwardReferences(
          input,
          offset,
          length,
          hasher,
          optimal,
          distCache,
          maxBackwardLimit,
          optimalModel,
          enumeratedLength: pass == 0 ? 24 : 12,
          matchCacheLen: passes > 1 ? matchLen : null,
          matchCacheDist: passes > 1 ? matchDist : null,
          matchCacheValid: passes > 1 ? matchValid : null,
        );
        hasher.rollbackJournal();
        hasher.endJournal();
        parses.add((
          commands: optimal,
          endCache: _snapshotDistanceCache(distCache),
        ));
        evaluateParse(parses.length - 1, optimal);
        optimalModel = ParseCostModel.fromCommands(
          input,
          offset,
          length,
          optimal,
        );
      }
    }

    // Static-dictionary candidate: dictionary words inside literal runs become
    // references. It is just another candidate, so it can never grow a block.
    if (useStaticDictionary && length >= kMinDictionaryBlockSize) {
      final dictionaryCommands = CommandBuffer(blockSize ~/ 2 + 2);
      final references = applyStaticDictionaryMatches(
        input,
        offset,
        length,
        commands,
        dictionaryCommands,
        maxBackwardLimit,
        compoundSize: compoundSize,
      );
      if (references > 0) {
        parses.add((
          commands: dictionaryCommands,
          endCache: parses[0].endCache,
        ));
        evaluateParse(parses.length - 1, dictionaryCommands);
      }
    }
    // Compound-dictionary candidate: input spans that occur in the attached
    // dictionary become raw copies from it. Another candidate, so it can only
    // be chosen when it serialises smaller.
    if (compoundMatcher != null) {
      final compoundCommands = CommandBuffer(blockSize ~/ 2 + 2);
      // Compound copies roll the decoder ring, so the rewrite tracks it and the
      // candidate carries its own end state.
      final compoundCache = Int32List.fromList(<int>[
        saved0,
        saved1,
        saved2,
        saved3,
      ]);
      final references = applyCompoundDictionaryMatches(
        input,
        offset,
        length,
        commands,
        compoundCommands,
        maxBackwardLimit,
        compoundMatcher,
        compoundCache,
      );
      if (references > 0) {
        parses.add((commands: compoundCommands, endCache: compoundCache));
        evaluateParse(parses.length - 1, compoundCommands);
      }
    }

    // Guided passes. Skipped when the chain parse barely compresses: then the
    // block is either stored raw or almost raw and repassing cannot pay off.
    if (useGuidedParsing &&
        length >= kMinGuidedParseBlockSize &&
        bestBits * 5 < uncompressedBits * 4) {
      var model = ParseCostModel.fromCommands(input, offset, length, commands);
      final passes = quality >= kMinQualityForDeeperGuidedParsing ? 2 : 1;
      for (var pass = 0; pass < passes; pass++) {
        distCache[0] = saved0;
        distCache[1] = saved1;
        distCache[2] = saved2;
        distCache[3] = saved3;
        final guided = CommandBuffer(blockSize ~/ 2 + 2);
        // The guided pass searches speculatively; every speculative search
        // inserts into the match table, so journal and roll those insertions
        // back. That keeps the table exactly as the chain parse left it, which
        // is what makes quality 10 a strict superset of quality 9's parse.
        hasher.beginJournal(length + 4);
        createGuidedBackwardReferences(
          input,
          offset,
          length,
          hasher,
          guided,
          distCache,
          maxBackwardLimit,
          model,
          lazySteps: 1,
        );
        hasher.rollbackJournal();
        hasher.endJournal();
        parses.add((
          commands: guided,
          endCache: _snapshotDistanceCache(distCache),
        ));
        evaluateParse(parses.length - 1, guided);
        model = ParseCostModel.fromCommands(input, offset, length, guided);
      }
    }

    // Re-emit the winner; it is the candidate that stays in the stream.
    final winner = parses[bestParse];
    writer.rewind(mark);
    switch (bestKind) {
      case 0:
        metaBlockWriter.store(
          writer,
          input,
          offset,
          length,
          winner.commands,
          isLast: false,
          distanceParams: defaultParams,
        );
      case 1:
        metaBlockWriter.store(
          writer,
          input,
          offset,
          length,
          winner.commands,
          isLast: false,
          contexts: contextModel,
          distanceParams: defaultParams,
        );
      default:
        splitWriter.store(
          writer,
          input,
          offset,
          length,
          winner.commands,
          bestSplit!,
          isLast: false,
          distanceParams: bestParams,
          optimizeHistograms: bestRle,
        );
    }
    bestBits = writer.bitPosition - mark;
    distCache[0] = winner.endCache[0];
    distCache[1] = winner.endCache[1];
    distCache[2] = winner.endCache[2];
    distCache[3] = winner.endCache[3];
    if (bestBits > uncompressedBits) {
      writer.rewind(mark);
      distCache[0] = saved0;
      distCache[1] = saved1;
      distCache[2] = saved2;
      distCache[3] = saved3;
      writeUncompressedMetaBlock(writer, input, offset, length);
    }
    offset += length;
  }
  // A one-shot state dies here; a streaming continuation keeps its matcher.
  if (continuation == null) hasher.release();
}

/// Distance parameters (and thus the distance alphabet) for [lgwin].
DistanceParams _distanceParamsForLgwin(int lgwin) => lgwin > _kMaxLgwin
    ? DistanceParams(0, 0, maxDistanceBits: kMaxLargeDistanceBits)
    : kDefaultDistanceParams;

int _normalizeLgwin(BrotliEncodeOptions options) => options.largeWindow
    ? _clamp(options.lgwin, _kMinLgwin, _kMaxLargeLgwin)
    : _clamp(options.lgwin, _kMinLgwin, _kMaxLgwin);

Int32List _snapshotDistanceCache(Int32List cache) =>
    Int32List.fromList(<int>[cache[0], cache[1], cache[2], cache[3]]);

int _clamp(int value, int min, int max) {
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

/// Push-style streaming encoder producing one Brotli stream.
///
/// [add] appends input, [flush] ends the current meta-block so the bytes
/// written so far become decodable (it does not end the stream), and [finish]
/// writes the remaining input plus the empty last meta-block. Compressed bytes
/// are handed out by [takeOutput] whenever a byte boundary has been reached.
///
/// Streaming always uses the high-ratio path (the fast tier indexes the whole
/// input up front), so for qualities 0..5 the stream differs from — and is
/// usually slightly smaller than — the one-shot [encode] output. Input is
/// retained (the match finder stores absolute positions), so streaming bounds
/// latency, not memory.
final class StreamingEncoder {
  /// Creates an encoder for the given [options].
  StreamingEncoder(BrotliEncodeOptions options)
    : _quality = _clamp(options.quality, 0, 11),
      _largeWindow = options.largeWindow,
      _sizeHint = options.sizeHint,
      _dictionary = options.dictionary,
      _lgwin = _normalizeLgwin(options) {
    if (!_largeWindow && options.lgwin > _kMaxLgwin) {
      throw BrotliException(
        BrotliErrorCode.unsupportedFeature,
        'lgwin ${options.lgwin} needs largeWindow: true (large-window streams)',
      );
    }
    _writeWindowBits(
      _writer,
      _lgwin,
      largeWindow: _largeWindow && _lgwin > _kMaxLgwin,
    );
  }

  final int _quality;
  final int _lgwin;
  final bool _largeWindow;
  final int? _sizeHint;
  final BrotliDictionary? _dictionary;
  final BitWriter _writer = BitWriter(initialCapacity: 1 << 12);
  _GreedyState? _greedy;
  _ChainState? _chain;
  Uint8List _input = Uint8List(4096);
  int _inputLength = 0;
  int _written = 0;
  final List<Uint8List> _chunks = <Uint8List>[];
  bool _finished = false;

  /// Whether [finish] has been called.
  bool get isFinished => _finished;

  int get _blockSize => _quality <= 1
      ? (_quality == 0 ? kQuality0BlockSize : kQuality1BlockSize)
      : kChainBlockSize;

  /// Appends [bytes] to the stream.
  void add(Uint8List bytes) {
    _checkOpen('add');
    if (bytes.isEmpty) return;
    _append(bytes);
    _encodeFullBlocks();
  }

  /// Ends the current meta-block without ending the stream.
  ///
  /// The data added since the previous flush (or since the beginning) becomes a
  /// non-final meta-block, so it is available through [takeOutput].
  void flush() {
    _checkOpen('flush');
    _encodeFullBlocks();
    if (_inputLength > _written) {
      _encodeRange(_written, _inputLength);
    }
    _collect();
  }

  /// Finishes the stream: encodes the remaining input and the empty last
  /// meta-block. After this call [isFinished] is true and [add]/[flush]/[finish]
  /// throw [StateError].
  void finish() {
    _checkOpen('finish');
    _encodeFullBlocks();
    if (_inputLength > _written) {
      _encodeRange(_written, _inputLength);
    }
    _writer.writeBits(1, 1); // ISLAST
    _writer.writeBits(1, 1); // ISEMPTY
    _writer.alignToByte();
    _collect();
    _finished = true;
  }

  /// Returns the compressed bytes produced since the last call.
  ///
  /// Bytes are only complete at a byte boundary; sub-byte state stays inside
  /// the encoder, so a prefix returned before [finish] is not a full stream but
  /// is the beginning of one.
  Uint8List takeOutput() {
    if (_chunks.isEmpty) return Uint8List(0);
    var total = 0;
    for (final chunk in _chunks) {
      total += chunk.length;
    }
    final output = Uint8List(total);
    var position = 0;
    for (final chunk in _chunks) {
      output.setRange(position, position + chunk.length, chunk);
      position += chunk.length;
    }
    _chunks.clear();
    return output;
  }

  void _checkOpen(String operation) {
    if (_finished) {
      throw StateError('$operation called after finish()');
    }
  }

  void _append(Uint8List bytes) {
    final needed = _inputLength + bytes.length;
    if (needed > _input.length) {
      var capacity = _input.isEmpty ? 4096 : _input.length;
      while (capacity < needed) {
        capacity *= 2;
      }
      final grown = Uint8List(capacity)..setRange(0, _inputLength, _input);
      _input = grown;
    }
    _input.setRange(_inputLength, needed, bytes);
    _inputLength = needed;
  }

  void _encodeFullBlocks() {
    final blockSize = _blockSize;
    while (_inputLength - _written >= blockSize) {
      _encodeRange(_written, _written + blockSize);
      _collect();
    }
  }

  void _encodeRange(int start, int end) {
    if (_quality <= 1) {
      _greedy ??= _GreedyState.forQuality(_quality, _blockSize);
      _writeGreedyCompressedBlocks(
        _writer,
        _input,
        _quality,
        _lgwin,
        start: start,
        end: end,
        continuation: _greedy,
      );
    } else {
      _chain ??= _ChainState.forQuality(_quality, _blockSize);
      _writeChainCompressedBlocks(
        _writer,
        _input,
        _quality,
        _lgwin,
        start: start,
        end: end,
        sizeHint: _sizeHint ?? _inputLength,
        dictionary: _dictionary,
        continuation: _chain,
      );
    }
    _written = end;
  }

  void _collect() {
    final chunk = _writer.takeCompleteBytes();
    if (chunk.isNotEmpty) _chunks.add(chunk);
  }
}
