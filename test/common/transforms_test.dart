import 'dart:typed_data';

import 'package:brotli_fast/src/common/transforms.dart';
import 'package:test/test.dart';

void main() {
  test('RFC transform tables unpack to the expected shape', () {
    final t = Transforms.rfc;
    expect(t.numTransforms, 121);
    expect(t.triplets.length, 363);
    expect(t.prefixSuffixStorage.length, 167);
    expect(t.prefixSuffixHeads.length, 51);
    expect(t.params.length, 121);
  });

  test('transform 39 trims the whole word', () {
    final input = Uint8List.fromList([119, 111, 114, 100]); // "word"
    final out = Uint8List(maxTransformedWordLength);
    final n = transformDictionaryWord(out, 0, input, 0, input.length, 39);
    expect(n, 0);
  });

  test('transform 44 capitalizes UTF-8 correctly', () {
    final input = Uint8List.fromList([113, 195, 166, 224, 164, 170]); // "qæप"
    final out = Uint8List(maxTransformedWordLength);
    final n = transformDictionaryWord(out, 0, input, 0, input.length, 44);
    expect(out.sublist(0, n), [81, 195, 134, 224, 164, 175]); // "QÆय"
  });

  test('all 121 transforms fit the documented output buffer', () {
    final input = Uint8List.fromList(<int>[
      111,
      49,
      50,
      51,
      52,
      53,
      54,
      55,
      56,
      57,
      97,
      98,
      99,
      100,
      101,
      102,
    ]);
    final out = Uint8List(2259);
    var offset = 0;
    for (var i = 0; i < 121; i++) {
      offset += transformDictionaryWord(out, offset, input, 0, input.length, i);
      out[offset++] = 0xFF;
    }
    expect(offset, 2259);
  });
}
