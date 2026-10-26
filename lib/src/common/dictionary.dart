/// RFC 7932 static dictionary access.
library;

import 'dart:typed_data';

import 'dictionary_data.dart';

/// Byte offsets of each word-length group in [kDictionaryData].
final Int32List dictionaryOffsets = _buildOffsets();

Int32List _buildOffsets() {
  final offsets = Int32List(32);
  var position = 0;
  for (var length = 4; length <= 24; length++) {
    offsets[length] = position;
    final count = 1 << kDictionarySizeBitsByLength[length];
    position += length * count;
  }
  // Sentinel for the end of the last group.
  offsets[25] = position;
  assert(
    position == kDictionaryData.length,
    'dictionary offsets mismatch: $position != ${kDictionaryData.length}',
  );
  return offsets;
}

/// Byte offset of word [index] of [length] in [kDictionaryData].
int dictionaryWordOffset(int length, int index) {
  assert(length >= 4 && length <= 24);
  return dictionaryOffsets[length] + index * length;
}
