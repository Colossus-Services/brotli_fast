import 'package:brotli_fast/src/common/dictionary.dart';
import 'package:brotli_fast/src/common/dictionary_data.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

/// RFC 7932 Appendix A: the static dictionary is 122,784 bytes.
const int _kDictionarySize = 122784;

void main() {
  test('dictionary payload size and hash', () {
    expect(kDictionaryData.length, _kDictionarySize);
    expect(
      sha256.convert(kDictionaryData).toString(),
      '20e42eb1b511c21806d4d227d07e5dd06877d8ce7b3a817f378f313653f35c70',
    );
  });

  test('size bits and offsets cover the payload', () {
    expect(kDictionarySizeBitsByLength.length, 32);
    expect(dictionaryOffsets[4], 0);
    expect(dictionaryOffsets[5], 4096);
    expect(dictionaryOffsets[6], 9216);
    expect(dictionaryOffsets[25], _kDictionarySize);
  });

  test('word offsets are in range', () {
    expect(dictionaryWordOffset(4, 0), 0);
    expect(dictionaryWordOffset(4, 1), 4);
    expect(dictionaryWordOffset(24, 0), dictionaryOffsets[24]);
    // The last 24-byte word ends exactly at the end of the payload.
    final last = (1 << kDictionarySizeBitsByLength[24]) - 1;
    expect(dictionaryWordOffset(24, last) + 24, _kDictionarySize);
  });
}
