import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_fast/src/common/bit_utils.dart' show log2Floor;
import 'package:brotli_fast/src/common/errors.dart';
import 'package:brotli_fast/src/common/format_tables.dart';
import 'package:brotli_fast/src/decoder/bit_reader.dart';
import 'package:brotli_fast/src/decoder/huffman_decoder.dart';
import 'package:test/test.dart';

import 'decoder_helpers.dart';

typedef _Table = ({Uint32List table, int index});

/// Allocates a table pool sized like the Java decoder's speculative group.
_Table _pool(int alphabetSize) {
  final table = Uint32List(huffmanTableSizeLimit(alphabetSize) + 1);
  final index = table.length - 1;
  table[index] = 0;
  return (table: table, index: index);
}

({Uint32List table, int index, int size}) _buildDirect(List<int> lengths) {
  final pool = _pool(lengths.length);
  final size = buildHuffmanTable(
    pool.table,
    pool.index,
    huffmanRootBits,
    Uint32List.fromList(lengths),
    lengths.length,
  );
  return (table: pool.table, index: pool.index, size: size);
}

/// Writes a symbol through the static code-length code (table `FIXED_TABLE`).
void _writeFixedLengthCode(BitSink sink, int value) {
  if (value == 0) {
    sink.writeBits(0, 2);
  } else if (value == 1) {
    sink.writeBits(7, 4);
  } else if (value == 2) {
    sink.writeBits(3, 3);
  } else if (value == 3) {
    sink.writeBits(2, 2);
  } else if (value == 4) {
    sink.writeBits(1, 2);
  } else if (value == 5) {
    sink.writeBits(15, 4);
  } else {
    throw ArgumentError('value $value is not in the fixed code-length table');
  }
}

/// Writes a complex code description whose code-length alphabet has 16 symbols
/// of code length 4 (enough to spell literal code lengths `0..15`).
void _writeComplexDefinition(BitSink sink, List<int> lengths) {
  sink.writeBits(0, 2); // complex code, no skipped code lengths
  for (final symbol in codeLengthCodeOrder) {
    _writeFixedLengthCode(sink, symbol < 16 ? 4 : 0);
  }
  for (final length in lengths) {
    sink.writeBits(_reverseBits(length, 4), 4);
  }
}

void _writeSimpleDefinition(
  BitSink sink, {
  required int alphabetSizeMax,
  required List<int> symbols,
  required int histogramId,
}) {
  sink.writeBits(1, 2); // simple code
  sink.writeBits(symbols.length - 1, 2);
  final maxBits = 1 + log2Floor(alphabetSizeMax - 1);
  for (final symbol in symbols) {
    sink.writeBits(symbol, maxBits);
  }
  if (symbols.length == 4) {
    sink.writeBits(histogramId - 4, 1);
  }
}

List<int> _canonicalCodes(List<int> lengths) {
  var maxLength = 0;
  for (final length in lengths) {
    if (length > maxLength) {
      maxLength = length;
    }
  }
  final count = List<int>.filled(maxLength + 1, 0);
  for (final length in lengths) {
    if (length > 0) {
      count[length]++;
    }
  }
  final nextCode = List<int>.filled(maxLength + 1, 0);
  var code = 0;
  for (var bits = 1; bits <= maxLength; bits++) {
    code = (code + count[bits - 1]) << 1;
    nextCode[bits] = code;
  }
  final codes = List<int>.filled(lengths.length, 0);
  for (var symbol = 0; symbol < lengths.length; symbol++) {
    final length = lengths[symbol];
    if (length != 0) {
      codes[symbol] = nextCode[length]++;
    }
  }
  return codes;
}

int _reverseBits(int value, int count) {
  var result = 0;
  for (var i = 0; i < count; i++) {
    result = (result << 1) | ((value >> i) & 1);
  }
  return result;
}

/// Complete code lengths for `symbolCount` symbols: `2^(k+1)` leaves at depth
/// `k` are redistributed between depth `k` and `k+1`.
List<int> _balancedLengths(int symbolCount) {
  if (symbolCount == 1) {
    return <int>[1];
  }
  var k = 0;
  while ((1 << (k + 1)) <= symbolCount) {
    k++;
  }
  final shortCount = (1 << (k + 1)) - symbolCount;
  final longCount = symbolCount - shortCount;
  return <int>[
    for (var i = 0; i < shortCount; i++) k,
    for (var i = 0; i < longCount; i++) k + 1,
  ];
}

/// Random complete code lengths, built by repeatedly splitting shallow leaves.
List<int> _randomLengths(int symbolCount, Random random) {
  if (symbolCount == 1) {
    return <int>[1];
  }
  final depths = <int>[0];
  while (depths.length < symbolCount) {
    var minimum = maxHuffmanCodeLength + 1;
    for (final depth in depths) {
      if (depth < minimum) {
        minimum = depth;
      }
    }
    final candidates = <int>[];
    for (var i = 0; i < depths.length; i++) {
      if (depths[i] < maxHuffmanCodeLength && depths[i] <= minimum + 2) {
        candidates.add(i);
      }
    }
    if (candidates.isEmpty) {
      throw StateError('could not complete the code-length tree');
    }
    final index = candidates[random.nextInt(candidates.length)];
    final newDepth = depths[index] + 1;
    depths[index] = newDepth;
    depths.add(newDepth);
  }
  return depths;
}

/// Writes every symbol of [order] with its canonical code.
void _writeSymbols(BitSink sink, List<int> lengths, Iterable<int> order) {
  final codes = _canonicalCodes(lengths);
  for (final symbol in order) {
    sink.writeBits(
      _reverseBits(codes[symbol], lengths[symbol]),
      lengths[symbol],
    );
  }
}

Matcher _invalidHuffman() => throwsBrotli(BrotliErrorCode.invalidHuffmanCode);

void main() {
  test('simple 1-symbol code decodes without consuming bits', () {
    final sink = BitSink();
    _writeSimpleDefinition(
      sink,
      alphabetSizeMax: 26,
      symbols: <int>[7],
      histogramId: 1,
    );
    final pool = _pool(26);
    final reader = BitReader.fromBytes(sink.toBytes());
    final size = readHuffmanCode(26, 26, pool.table, pool.index, reader);
    expect(size, 256);
    final consumedBefore = reader.bytesConsumed;
    expect(readSymbol(pool.table, pool.index, reader), 7);
    expect(reader.bytesConsumed, consumedBefore);
    for (var slot = 0; slot < 256; slot++) {
      expect(pool.table[slot], 7, reason: 'slot $slot');
    }
    expect(pool.table[pool.index], 0);
  });

  test('simple 2-symbol code decodes both codes', () {
    final sink = BitSink();
    _writeSimpleDefinition(
      sink,
      alphabetSizeMax: 26,
      symbols: <int>[5, 2],
      histogramId: 2,
    );
    // Canonical assignment is by symbol order: 2 -> 0, 5 -> 1.
    sink.writeBits(0, 1);
    sink.writeBits(1, 1);
    final pool = _pool(26);
    final reader = BitReader.fromBytes(sink.toBytes());
    expect(readHuffmanCode(26, 26, pool.table, pool.index, reader), 256);
    expect(readSymbol(pool.table, pool.index, reader), 2);
    expect(readSymbol(pool.table, pool.index, reader), 5);
    for (var slot = 0; slot < 256; slot++) {
      expect(pool.table[slot] >> 16, 1);
    }
    reader.checkHealth(true);
  });

  test('simple 3-symbol code uses lengths 1/2/2', () {
    final sink = BitSink();
    _writeSimpleDefinition(
      sink,
      alphabetSizeMax: 26,
      symbols: <int>[9, 4, 17],
      histogramId: 3,
    );
    final lengths = List<int>.filled(26, 0);
    lengths[9] = 1;
    lengths[4] = 2;
    lengths[17] = 2;
    // Symbols in stream order: 9 (len 1), 4 (len 2), 17 (len 2).
    _writeSymbols(sink, lengths, <int>[9, 4, 17]);
    final pool = _pool(26);
    final reader = BitReader.fromBytes(sink.toBytes());
    expect(readHuffmanCode(26, 26, pool.table, pool.index, reader), 256);
    expect(readSymbol(pool.table, pool.index, reader), 9);
    expect(readSymbol(pool.table, pool.index, reader), 4);
    expect(readSymbol(pool.table, pool.index, reader), 17);
  });

  test('simple 4-symbol uniform histogram decodes all symbols', () {
    final sink = BitSink();
    _writeSimpleDefinition(
      sink,
      alphabetSizeMax: 26,
      symbols: <int>[3, 1, 2, 0],
      histogramId: 4,
    );
    final lengths = List<int>.filled(26, 0);
    lengths[0] = 2;
    lengths[1] = 2;
    lengths[2] = 2;
    lengths[3] = 2;
    const order = <int>[3, 1, 2, 0];
    _writeSymbols(sink, lengths, order);
    final pool = _pool(26);
    final reader = BitReader.fromBytes(sink.toBytes());
    expect(readHuffmanCode(26, 26, pool.table, pool.index, reader), 256);
    for (final symbol in order) {
      expect(readSymbol(pool.table, pool.index, reader), symbol);
    }
  });

  test('simple 4-symbol prioritized histogram decodes all symbols', () {
    final sink = BitSink();
    _writeSimpleDefinition(
      sink,
      alphabetSizeMax: 26,
      symbols: <int>[3, 1, 2, 0],
      histogramId: 5,
    );
    final lengths = List<int>.filled(26, 0);
    lengths[3] = 1;
    lengths[1] = 2;
    lengths[2] = 3;
    lengths[0] = 3;
    const order = <int>[3, 1, 2, 0];
    _writeSymbols(sink, lengths, order);
    final pool = _pool(26);
    final reader = BitReader.fromBytes(sink.toBytes());
    expect(readHuffmanCode(26, 26, pool.table, pool.index, reader), 256);
    for (final symbol in order) {
      expect(readSymbol(pool.table, pool.index, reader), symbol);
    }
  });

  test('simple code uses alphabetSizeMax for the symbol width', () {
    final sink = BitSink();
    _writeSimpleDefinition(
      sink,
      alphabetSizeMax: 1128, // large-window distance alphabet
      symbols: <int>[543, 0],
      histogramId: 2,
    );
    // Canonical assignment by symbol order: 0 -> 0, 543 -> 1.
    sink.writeBits(0, 1);
    sink.writeBits(1, 1);
    final pool = _pool(544);
    final reader = BitReader.fromBytes(sink.toBytes());
    expect(readHuffmanCode(1128, 544, pool.table, pool.index, reader), 256);
    expect(readSymbol(pool.table, pool.index, reader), 0);
    expect(readSymbol(pool.table, pool.index, reader), 543);
  });

  test('simple code rejects duplicates and out-of-range symbols', () {
    final duplicate = BitSink();
    _writeSimpleDefinition(
      duplicate,
      alphabetSizeMax: 26,
      symbols: <int>[4, 4],
      histogramId: 2,
    );
    final duplicatePool = _pool(26);
    expect(
      () => readHuffmanCode(
        26,
        26,
        duplicatePool.table,
        duplicatePool.index,
        BitReader.fromBytes(duplicate.toBytes()),
      ),
      _invalidHuffman(),
    );

    final outOfRange = BitSink();
    _writeSimpleDefinition(
      outOfRange,
      alphabetSizeMax: 26,
      symbols: <int>[31, 3],
      histogramId: 2,
    );
    final rangePool = _pool(26);
    expect(
      () => readHuffmanCode(
        26,
        26,
        rangePool.table,
        rangePool.index,
        BitReader.fromBytes(outOfRange.toBytes()),
      ),
      _invalidHuffman(),
    );

    final largeWindow = BitSink();
    _writeSimpleDefinition(
      largeWindow,
      alphabetSizeMax: 1128,
      symbols: <int>[600, 1],
      histogramId: 2,
    );
    final largePool = _pool(544);
    expect(
      () => readHuffmanCode(
        1128,
        544,
        largePool.table,
        largePool.index,
        BitReader.fromBytes(largeWindow.toBytes()),
      ),
      _invalidHuffman(),
    );
  });

  test('complex code for 26 symbols round-trips', () {
    final lengths = _balancedLengths(26);
    final sink = BitSink();
    _writeComplexDefinition(sink, lengths);
    final order = List<int>.generate(26, (i) => i);
    _writeSymbols(sink, lengths, order);
    final pool = _pool(26);
    final reader = BitReader.fromBytes(sink.toBytes());
    final size = readHuffmanCode(26, 26, pool.table, pool.index, reader);
    expect(size, 256);
    for (final symbol in order) {
      expect(readSymbol(pool.table, pool.index, reader), symbol);
    }
    reader.checkHealth(true);
  });

  test('complex codes for 258 and 704 symbols round-trip', () {
    for (final symbolCount in <int>[258, 704]) {
      final lengths = _balancedLengths(symbolCount);
      final sink = BitSink();
      _writeComplexDefinition(sink, lengths);
      final order = List<int>.generate(symbolCount, (i) => i);
      _writeSymbols(sink, lengths, order);
      final pool = _pool(symbolCount);
      final reader = BitReader.fromBytes(sink.toBytes());
      final size = readHuffmanCode(
        symbolCount,
        symbolCount,
        pool.table,
        pool.index,
        reader,
      );
      expect(size, isNotNull, reason: 'alphabet $symbolCount');
      expect(
        size,
        lessThanOrEqualTo(huffmanTableSizeLimit(symbolCount)),
        reason: 'alphabet $symbolCount',
      );
      expect(size, greaterThan(256), reason: 'alphabet $symbolCount');
      for (final symbol in order) {
        expect(
          readSymbol(pool.table, pool.index, reader),
          symbol,
          reason: 'alphabet $symbolCount symbol $symbol',
        );
      }
      reader.checkHealth(true);
    }
  });

  test('random canonical codes round-trip', () {
    final random = Random(2024);
    for (var run = 0; run < 24; run++) {
      final symbolCount = 2 + random.nextInt(60);
      final lengths = _randomLengths(symbolCount, random);
      lengths.shuffle(random);
      final sink = BitSink();
      _writeComplexDefinition(sink, lengths);
      final decodeOrder = List<int>.generate(symbolCount, (i) => i)
        ..shuffle(random);
      _writeSymbols(sink, lengths, decodeOrder);
      final pool = _pool(symbolCount);
      final reader = BitReader.fromBytes(sink.toBytes());
      final size = readHuffmanCode(
        symbolCount,
        symbolCount,
        pool.table,
        pool.index,
        reader,
      );
      expect(size, isNotNull, reason: 'run $run');
      expect(
        size,
        lessThanOrEqualTo(huffmanTableSizeLimit(symbolCount)),
        reason: 'run $run',
      );
      for (final symbol in decodeOrder) {
        expect(
          readSymbol(pool.table, pool.index, reader),
          symbol,
          reason: 'run $run symbol $symbol',
        );
      }
      reader.checkHealth(true);
    }
  });

  test('maximum table sizes stay within the reference bounds', () {
    final random = Random(7);
    var largestSeen = 0;
    for (final symbolCount in <int>[26, 258, 704]) {
      final limit = huffmanTableSizeLimit(symbolCount);
      for (var run = 0; run < 16; run++) {
        final lengths = _randomLengths(symbolCount, random);
        final built = _buildDirect(lengths);
        expect(built.size, lessThanOrEqualTo(limit));
        if (built.size > largestSeen) {
          largestSeen = built.size;
        }
        // Root slots are either symbols of length <= 8 or secondary pointers.
        for (var slot = 0; slot < 256; slot++) {
          final entry = built.table[slot];
          final bits = entry >> 16;
          final symbol = entry & 0xFFFF;
          if (bits > huffmanRootBits) {
            expect(bits, inInclusiveRange(9, maxHuffmanCodeLength));
            expect(slot + symbol, lessThan(built.size));
          } else {
            expect(symbol, lessThan(symbolCount));
          }
        }
      }
      // The balanced histogram is a fixed regression point.
      final balanced = _buildDirect(_balancedLengths(symbolCount));
      expect(balanced.size, lessThanOrEqualTo(limit));
    }
    expect(largestSeen, greaterThan(256));
  });

  test('balanced table sizes match the reference port', () {
    final sizes = <int>[
      for (final n in <int>[26, 258, 704])
        _buildDirect(_balancedLengths(n)).size,
    ];
    expect(sizes, <int>[256, 260, 960]);
  });

  test('single-symbol table is replicated with zero-length codes', () {
    final lengths = List<int>.filled(26, 0);
    lengths[9] = 1;
    final built = _buildDirect(lengths);
    expect(built.size, 256);
    for (var slot = 0; slot < 256; slot++) {
      expect(built.table[slot], 9);
      expect(built.table[slot] >> 16, 0);
    }
  });

  test('readBlockLength decodes symbols plus extra bits', () {
    final lengths = _balancedLengths(26);
    final sink = BitSink();
    _writeComplexDefinition(sink, lengths);
    final codes = _canonicalCodes(lengths);
    final expected = <int>[3, 305 + 42, 16625 + 0xABCDE];
    final symbols = <int>[0, 17, 25];
    final extras = <int>[2, 42, 0xABCDE];
    for (var i = 0; i < symbols.length; i++) {
      final symbol = symbols[i];
      sink.writeBits(
        _reverseBits(codes[symbol], lengths[symbol]),
        lengths[symbol],
      );
      sink.writeBits(extras[i], blockLengthNBits[symbol]);
    }
    final pool = _pool(26);
    final reader = BitReader.fromBytes(sink.toBytes());
    expect(readHuffmanCode(26, 26, pool.table, pool.index, reader), 256);
    for (final value in expected) {
      expect(readBlockLength(pool.table, pool.index, reader), value);
    }
    reader.checkHealth(true);
  });

  test('malformed code-length histograms are rejected', () {
    // All code-length code lengths are zero: no code space is used.
    final empty = BitSink();
    empty.writeBits(0, 2);
    for (var i = 0; i < codeLengthCodes; i++) {
      _writeFixedLengthCode(empty, 0);
    }
    final emptyPool = _pool(26);
    expect(
      () => readHuffmanCode(
        26,
        26,
        emptyPool.table,
        emptyPool.index,
        BitReader.fromBytes(empty.toBytes()),
      ),
      _invalidHuffman(),
    );

    // Over-subscribed code-length histogram.
    final negative = BitSink();
    negative.writeBits(0, 2);
    for (var i = 0; i < 5; i++) {
      _writeFixedLengthCode(negative, 2);
    }
    final negativePool = _pool(26);
    expect(
      () => readHuffmanCode(
        26,
        26,
        negativePool.table,
        negativePool.index,
        BitReader.fromBytes(negative.toBytes()),
      ),
      _invalidHuffman(),
    );
  });

  test('malformed symbol code lengths are rejected', () {
    // Over-subscribed: the running code space goes negative (2, 1, 1 bits).
    final over = BitSink();
    _writeComplexDefinition(over, <int>[2, 1, 1, ...List<int>.filled(23, 5)]);
    final overPool = _pool(26);
    expect(
      () => readHuffmanCode(
        26,
        26,
        overPool.table,
        overPool.index,
        BitReader.fromBytes(over.toBytes()),
      ),
      _invalidHuffman(),
    );

    // Under-subscribed: 1 x length 4 and 25 x length 5.
    final under = BitSink();
    _writeComplexDefinition(under, <int>[4, ...List<int>.filled(25, 5)]);
    final underPool = _pool(26);
    expect(
      () => readHuffmanCode(
        26,
        26,
        underPool.table,
        underPool.index,
        BitReader.fromBytes(under.toBytes()),
      ),
      _invalidHuffman(),
    );
  });

  test('code-length repeat overrun is rejected', () {
    final sink = BitSink();
    sink.writeBits(0, 2);
    // Code-length alphabet: symbol 0 and symbol 17, both of length 1.
    for (final value in <int>[0, 0, 0, 0, 1, 0, 1]) {
      _writeFixedLengthCode(sink, value);
    }
    // First repeat: 10 zero lengths (3 extra bits = 7).
    sink.writeBits(1, 1);
    sink.writeBits(7, 3);
    // Second repeat: repeat = 8 * 8 + 3 = 67, which runs past 26 symbols.
    sink.writeBits(1, 1);
    sink.writeBits(0, 3);
    final pool = _pool(26);
    expect(
      () => readHuffmanCode(
        26,
        26,
        pool.table,
        pool.index,
        BitReader.fromBytes(sink.toBytes()),
      ),
      _invalidHuffman(),
    );
  });

  test('readHuffmanCode returns null when input runs out, retry succeeds', () {
    const symbolCount = 704;
    final lengths = _balancedLengths(symbolCount);
    final sink = BitSink();
    _writeComplexDefinition(sink, lengths);
    _writeSymbols(sink, lengths, List<int>.generate(symbolCount, (i) => i));
    final bytes = sink.toBytes();
    const split = 120;
    final input = ChunkedInput(bytesPerCall: 7);
    input.add(Uint8List.sublistView(bytes, 0, split));
    final reader = BitReader(input);
    final pool = _pool(symbolCount);
    final memento = reader.save();
    expect(
      readHuffmanCode(symbolCount, symbolCount, pool.table, pool.index, reader),
      isNull,
    );
    reader.restore(memento);
    expect(reader.activeMementoCount, 0);
    input.add(Uint8List.sublistView(bytes, split));
    input.close();
    final size = readHuffmanCode(
      symbolCount,
      symbolCount,
      pool.table,
      pool.index,
      reader,
    );
    expect(size, isNotNull);
    for (var symbol = 0; symbol < symbolCount; symbol++) {
      expect(readSymbol(pool.table, pool.index, reader), symbol);
    }
    reader.checkHealth(true);
  });
}
