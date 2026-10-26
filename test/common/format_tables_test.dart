import 'package:brotli_fast/src/common/format_tables.dart';
import 'package:test/test.dart';

void main() {
  test('command lookup has 704 rows', () {
    expect(commandLookup.length, numCommandCodes * 4);
    // First command: no insert extra bits, copy length 2, implicit distance.
    expect(commandLookup.sublist(0, 4), [0, 0, 2, -4]);
    // Last command row is within the valid distance-context range.
    expect(commandLookup[4 * 703 + 3], inInclusiveRange(-4, 3));
  });

  test('insert/copy offsets are monotonic', () {
    var insert = 0;
    var copy = 2;
    for (var i = 0; i < 23; i++) {
      expect(insertLengthNBits[i], inInclusiveRange(0, 24));
      expect(copyLengthNBits[i], inInclusiveRange(0, 24));
      insert += 1 << insertLengthNBits[i];
      copy += 1 << copyLengthNBits[i];
    }
    expect(insert, greaterThan(0));
    expect(copy, greaterThan(0));
  });

  test('distance alphabet helpers', () {
    expect(distanceAlphabetSize(0, 0, 24), 64);
    expect(distanceAlphabetSize(0, 15, 24), 79);
    expect(distanceAlphabetLimit((1 << 24) - 16, 0, 0), 59);
    expect(distanceAlphabetLimit(maxAllowedDistance, 0, 0), 74);
    expect(distanceAlphabetSize(3, 120, 62), 1128);
    expect(distanceAlphabetLimit(1, 0, 0), -1);
  });

  test('huffman table limits match the reference', () {
    expect(huffmanTableSizeLimit(0), 256);
    expect(huffmanTableSizeLimit(26), 402);
    expect(huffmanTableSizeLimit(258), 662);
    expect(huffmanTableSizeLimit(544), 920);
    expect(huffmanTableSizeLimit(704), 1080);
  });
}
