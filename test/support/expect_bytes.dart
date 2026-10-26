/// Byte-exact comparison for large buffers.
library;

import 'package:test/test.dart';

/// Expects [actual] to hold exactly the bytes of [expected], reporting the
/// first differing offset instead of dumping megabytes of bytes.
void expectSameBytes(List<int> actual, List<int> expected, {String? reason}) {
  final prefix = reason == null ? '' : '$reason: ';
  expect(actual.length, expected.length, reason: '${prefix}length');
  for (var i = 0; i < expected.length; i++) {
    if (actual[i] != expected[i]) {
      fail('${prefix}byte $i is ${actual[i]}, expected ${expected[i]}');
    }
  }
}
