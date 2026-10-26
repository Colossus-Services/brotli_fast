/// Deterministic encoder inputs and byte comparison shared by the encoder
/// tests.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

export 'expect_bytes.dart';

/// `test/testdata/alice29.txt` (English text, 152 KB).
final Uint8List alice = File('test/testdata/alice29.txt').readAsBytesSync();

/// `test/testdata/plrabn12.txt` (English text, 482 KB).
final Uint8List plrabn12 = File('test/testdata/plrabn12.txt').readAsBytesSync();

/// [size] bytes of [alice], repeated.
Uint8List aliceText(int size) => repeatToSize(alice, size);

/// [pattern] repeated to [size] bytes (zeros for an empty pattern).
Uint8List repeatToSize(List<int> pattern, int size) {
  final out = Uint8List(size);
  if (pattern.isEmpty) return out;
  for (var i = 0; i < size; i++) {
    out[i] = pattern[i % pattern.length];
  }
  return out;
}

/// [size] uniformly random bytes.
Uint8List randomBytes(int size, int seed) {
  final random = Random(seed);
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = random.nextInt(256);
  }
  return out;
}

/// [size] bytes of varied CJK UTF-8 text (2000 ideographs, sparse spaces).
Uint8List variedCjk(int size, int seed) {
  final random = Random(seed);
  final builder = StringBuffer();
  while (builder.length < size) {
    builder.writeCharCode(0x4E00 + random.nextInt(2000));
    if (random.nextInt(8) == 0) builder.write(' ');
  }
  final bytes = utf8.encode(builder.toString());
  return Uint8List.fromList(bytes.take(size).toList());
}

/// [size] bytes alternating [period]-byte runs of [alice] text and random
/// bytes.
Uint8List alternatingTextBinary(int size, int seed, {int period = 32768}) {
  final out = Uint8List(size);
  final random = Random(seed);
  var pos = 0;
  var inText = true;
  var left = period;
  while (pos < size) {
    if (left == 0) {
      inText = !inText;
      left = period;
    }
    out[pos] = inText ? alice[pos % alice.length] : random.nextInt(256);
    pos++;
    left--;
  }
  return out;
}

/// [size] bytes built from pseudo-random 80..479-byte slices of [dictionary].
Uint8List payloadFrom(Uint8List dictionary, int size, {int seed = 7}) {
  final out = Uint8List(size);
  final random = Random(seed);
  var pos = 0;
  while (pos < size) {
    final start = random.nextInt(max(1, dictionary.length - 600));
    final length = 80 + random.nextInt(400);
    for (var i = 0; i < length && pos < size; i++) {
      out[pos++] = dictionary[start + i];
    }
  }
  return out;
}
