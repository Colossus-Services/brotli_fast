/// Deterministic corpus for the benchmark and the tests. No `dart:io`, and the
/// same bytes on every platform, so it also runs on the web.
library;

import 'dart:typed_data';

const int benchmarkPayloadBytes = 1 << 20;

const List<String> _words = <String>[
  'brotli',
  'compression',
  'pure',
  'dart',
  'zero',
  'copy',
  'window',
  'dictionary',
  'context',
  'literal',
  'command',
  'distance',
  'stream',
  'encoder',
  'decoder',
  'benchmark',
  'browser',
  'server',
  'binary',
  'text',
];

/// Deterministic, moderately compressible UTF-8 text (1 MiB by default).
Uint8List makeText([int size = benchmarkPayloadBytes]) {
  final out = Uint8List(size);
  final builder = StringBuffer();
  var line = 0;
  while (builder.length < size) {
    for (var i = 0; i < 12; i++) {
      builder
        ..write(_words[(line * 7 + i * 3) % _words.length])
        ..write(' ');
    }
    builder
      ..write('line ')
      ..write(line)
      ..write('.\n');
    line++;
  }
  final bytes = builder.toString().codeUnits;
  for (var i = 0; i < size; i++) {
    out[i] = bytes[i] & 0xFF;
  }
  return out;
}

/// Deterministic structured binary data (1 MiB by default).
///
/// Mostly low-entropy records with periodic pseudo-random payloads, so both
/// LZ matching and entropy coding are exercised.
Uint8List makeBinary([int size = benchmarkPayloadBytes]) {
  final out = Uint8List(size);
  var seed = 0x1234ABCD;
  var offset = 0;
  var block = 0;
  while (offset < size) {
    final end = (offset + 256 < size) ? offset + 256 : size;
    // 8-byte record header: block index and a fixed magic.
    out[offset] = block & 0xFF;
    out[offset + 1] = (block >> 8) & 0xFF;
    for (var i = 2; i < 8 && offset + i < end; i++) {
      out[offset + i] = 0xA5;
    }
    final noisy = block % 7 == 0;
    for (var i = 8; offset + i < end; i++) {
      if (noisy) {
        seed = (_mulLow32(seed, 1103515245) + 12345) & 0x7FFFFFFF;
        out[offset + i] = (seed >> 16) & 0xFF;
      } else {
        out[offset + i] = (i * 13 + block * 7) & 0x7F;
      }
    }
    offset = end;
    block++;
  }
  return out;
}

/// Low 32 bits of `a * b` from 16-bit halves: the full product exceeds 2^53,
/// which JavaScript numbers cannot hold exactly, so the generator would
/// otherwise produce different bytes on the web than on the VM.
int _mulLow32(int a, int b) {
  final lo = (a & 0xFFFF) * (b & 0xFFFF);
  final mid = (a & 0xFFFF) * (b >> 16) + (a >> 16) * (b & 0xFFFF);
  return (lo + ((mid & 0xFFFF) * 65536)) & 0xFFFFFFFF;
}
