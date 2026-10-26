/// Entropy cost model used by the high-effort parsers of qualities 10 and 11.
///
/// The lower tiers decide matches with a fixed heuristic score
/// (`BackwardReferenceScore`), which is only a rough proxy for the real bit
/// cost. The guided parser instead asks this model how many bits a literal,
/// command symbol, distance symbol or extra-bit field is expected to cost,
/// using the histograms of a parse that was already produced. Feeding the model
/// with the *previous* pass's output is the same idea as the reference's HQ
/// (Zopfli-style) pass: parse, build statistics from that parse, parse again
/// with costs derived from those statistics.
///
/// Costs are Shannon-style (`log2(total) - log2(count)`) like
/// `ZopfliCalculateEntropy`; they are only used for comparisons, so no tree
/// overhead term is needed.
library;

import 'dart:typed_data';

import 'command.dart';
import 'context_modeling.dart' show deterministicLog2;
import 'distance_params.dart';

/// Fallback cost for a symbol that never occurred (`kInfinityCost` in spirit).
const double kRareSymbolCost = 24.0;

/// Smallest cost assigned to a symbol, in bits.
///
/// A pure entropy model gives a symbol that is the only one in its histogram a
/// cost of zero, which would make a byte literal of highly repetitive data
/// "free" and mislead the parser into never copying. The floor (plus the small
/// constant below) keeps literals priced.
const double kMinSymbolCost = 0.1;

/// Fixed per-symbol overhead added to the entropy estimate (tree modelling).
const double kSymbolCostBias = 0.2;

/// Cost in bits of a symbol with [count] occurrences out of [total].
double symbolCost(int total, int count) {
  if (count <= 0 || total <= 0) return kRareSymbolCost;
  final bits =
      deterministicLog2(total) - deterministicLog2(count) + kSymbolCostBias;
  return bits < kMinSymbolCost ? kMinSymbolCost : bits;
}

/// Bit costs for literals, command symbols and distance symbols.
final class ParseCostModel {
  ParseCostModel({
    required this.literalCost,
    required this.commandCost,
    required this.distanceCost,
  });

  /// Builds a model from an already produced parse.
  ///
  /// Literals are counted per byte value, commands per `cmd_prefix` symbol and
  /// distances per distance symbol with the default `(0, 0)` parameters (the
  /// meta-block parameters are chosen later and only shift symbols slightly).
  factory ParseCostModel.fromCommands(
    Uint8List input,
    int start,
    int length,
    CommandBuffer commands,
  ) {
    final literalHistogram = Uint32List(numLiteralSymbols);
    final commandHistogram = Uint32List(numCommandSymbols);
    final distanceHistogram = Uint32List(numDistanceSymbols);
    var pos = start;
    final bits = Int32List(1);
    final extra = Int32List(1);
    for (var i = 0; i < commands.count; i++) {
      final insertLen = commands.insertLen[i];
      for (var j = 0; j < insertLen; j++) {
        literalHistogram[input[pos++]]++;
      }
      pos += commands.copyLen[i];
      commandHistogram[commands.cmdPrefix[i]]++;
      if (commands.copyLen[i] != 0 && commands.cmdPrefix[i] >= 128) {
        final packed = encodeDistanceCode(
          commands.distCode[i],
          kDefaultDistanceParams,
          bits,
          extra,
        );
        distanceHistogram[packed & 0x3FF]++;
      }
    }
    assert(pos == start + length || pos <= start + length);
    var literalTotal = 0;
    for (final c in literalHistogram) {
      literalTotal += c;
    }
    var commandTotal = 0;
    for (final c in commandHistogram) {
      commandTotal += c;
    }
    var distanceTotal = 0;
    for (final c in distanceHistogram) {
      distanceTotal += c;
    }
    final literalCost = Float64List(numLiteralSymbols);
    for (var i = 0; i < numLiteralSymbols; i++) {
      literalCost[i] = symbolCost(literalTotal, literalHistogram[i]);
    }
    final commandCost = Float64List(numCommandSymbols);
    for (var i = 0; i < numCommandSymbols; i++) {
      commandCost[i] = symbolCost(commandTotal, commandHistogram[i]);
    }
    final distanceCost = Float64List(numDistanceSymbols);
    for (var i = 0; i < numDistanceSymbols; i++) {
      distanceCost[i] = symbolCost(distanceTotal, distanceHistogram[i]);
    }
    return ParseCostModel(
      literalCost: literalCost,
      commandCost: commandCost,
      distanceCost: distanceCost,
    );
  }

  /// Bit cost of each literal byte value.
  final Float64List literalCost;

  /// Bit cost of each command symbol.
  final Float64List commandCost;

  /// Bit cost of each distance symbol (default parameters).
  ///
  /// Its length is the distance alphabet size.
  final Float64List distanceCost;

  /// Bit cost of encoding one copy of [copyLen] bytes at [distanceCode],
  /// assuming [insertLen] literals precede it.
  ///
  /// Allocation free and table driven: this is called tens of times per input
  /// position by the guided parser.
  double copyCost(int insertLen, int copyLen, int distanceCode) {
    final insCode = getInsertLengthCode(insertLen);
    final copyCode = getCopyLengthCode(copyLen);
    final useLast = distanceCode == 0;
    final command = combineLengthCodes(insCode, copyCode, useLast);
    var cost = commandCost[command] + kInsExtra[insCode] + kCopyExtra[copyCode];
    if (!useLast) {
      // Default distance parameters (0, 0), inlined `PrefixEncodeCopyDistance`.
      if (distanceCode >= numDistanceShortCodes) {
        final dist = (1 << 2) + (distanceCode - numDistanceShortCodes);
        final bucket = log2FloorNonZero(dist) - 1;
        final prefixBit = (dist >> bucket) & 1;
        final symbol = numDistanceShortCodes + (2 * (bucket - 1) + prefixBit);
        cost += distanceCost[symbol < distanceCost.length ? symbol : 0];
        cost += bucket;
      } else {
        cost += distanceCost[distanceCode];
      }
    }
    return cost;
  }
}
