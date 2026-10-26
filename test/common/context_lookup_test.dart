import 'package:brotli_fast/src/common/context_lookup.dart';
import 'package:test/test.dart';

// RFC 7932 section 7.1 context modes; each owns 512 table bytes: the p1
// lookup at `mode * 512` and the p2 lookup 256 bytes later.
const int _lsb6 = 0;
const int _msb6 = 1;
const int _utf8 = 2;
const int _signed = 3;

/// Literal context id for the previous two bytes [p1] and [p2], as the decoder
/// computes it.
int _contextId(int mode, int p1, int p2) =>
    kContextLookupTable[(mode << 9) + p1] |
    kContextLookupTable[(mode << 9) + 256 + p2];

void main() {
  test('context table shape', () {
    expect(kContextLookupTable.length, 2048);
  });

  test('LSB6 context is the low six bits of the previous byte', () {
    for (var b = 0; b < 256; b++) {
      expect(_contextId(_lsb6, b, 0), b & 63);
      // p2 does not contribute.
      expect(_contextId(_lsb6, b, 0xFF), b & 63);
    }
  });

  test('MSB6 context is the high six bits of the previous byte', () {
    expect(_contextId(_msb6, 0x00, 0), 0);
    expect(_contextId(_msb6, 0xFF, 0), 63);
    expect(_contextId(_msb6, 0x41, 0), 16);
    for (var b = 0; b < 256; b++) {
      expect(_contextId(_msb6, b, 0x5A), b >> 2);
    }
  });

  test('UTF8 and signed modes stay in the 6-bit range', () {
    for (final mode in [_utf8, _signed]) {
      for (var p1 = 0; p1 < 256; p1++) {
        final id = _contextId(mode, p1, p1);
        expect(id, inInclusiveRange(0, 63));
      }
    }
  });
}
