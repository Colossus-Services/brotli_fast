/// The encoder produces the same bytes on every platform.
///
/// Runs on the VM and in the browser (dart2js and dart2wasm): the expected
/// hashes are the VM output, so a browser run checks web/VM parity.
library;

import 'package:brotli_fast/brotli_fast.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'support/parity_vectors.dart';

void main() {
  for (final vector in parityVectors) {
    test('$vector', () {
      final input = vector.input();
      final packed = brotliEncode(input, quality: vector.quality);
      expect(sha256.convert(packed).toString(), vector.sha256);
      expect(brotliDecode(packed), orderedEquals(input));
    });
  }
}
