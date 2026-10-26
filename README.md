# brotli_fast

[![pub package](https://img.shields.io/pub/v/brotli_fast.svg?logo=dart&logoColor=00b9fc)](https://pub.dev/packages/brotli_fast)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![Dart CI](https://github.com/Colossus-Services/brotli_fast/actions/workflows/dart.yml/badge.svg?branch=main)](https://github.com/Colossus-Services/brotli_fast/actions/workflows/dart.yml)
[![codecov](https://codecov.io/gh/Colossus-Services/brotli_fast/branch/main/graph/badge.svg)](https://codecov.io/gh/Colossus-Services/brotli_fast)
[![GitHub Tag](https://img.shields.io/github/v/tag/Colossus-Services/brotli_fast?logo=git&logoColor=white)](https://github.com/Colossus-Services/brotli_fast/releases)
[![Last Commits](https://img.shields.io/github/last-commit/Colossus-Services/brotli_fast?logo=git&logoColor=white)](https://github.com/Colossus-Services/brotli_fast/commits/main)
[![Code size](https://img.shields.io/github/languages/code-size/Colossus-Services/brotli_fast?logo=github&logoColor=white)](https://github.com/Colossus-Services/brotli_fast)
[![License](https://img.shields.io/github/license/Colossus-Services/brotli_fast?logo=open-source-initiative&logoColor=green)](https://github.com/Colossus-Services/brotli_fast/blob/main/LICENSE)

A **fast, pure Dart [Brotli](https://datatracker.ietf.org/doc/html/rfc7932)
encoder and decoder** with **no native dependencies** and **no package
dependencies**. It runs everywhere Dart runs (VM, AOT, Flutter, and the web
through dart2js and dart2wasm) and produces the same bytes on every platform.

```dart
import 'package:brotli_fast/brotli_fast.dart';

final packed = brotliEncode(bytes);              // quality 5
final smallest = brotliEncode(bytes, quality: 11);
final restored = brotliDecode(packed);
```

## Features

- **All of Brotli:** qualities 0–11 and window sizes 10–24 bits on the
  encoder, and the full RFC 7932 format on the decoder, including the static
  dictionary and every transform.
- **Fast:** a dedicated fast tier for qualities 0–5 and a tuned high-ratio
  encoder for 6–11; a decoder with a fused hot loop and a 64-bit bit reader
  on the VM. See [Performance](#performance).
- **One-shot, `dart:convert` and streams:** `brotliEncode`/`brotliDecode`, the
  `brotli` codec, and stream transformers that emit output as input arrives.
- **Dictionaries:** raw (compound) dictionaries for both directions, which
  help small, similar payloads, and serialized shared dictionaries on decode.
- **Large-window format:** windows up to 1 GiB (non-standard, opt-in on
  decode).
- **Safe decoding:** malformed or truncated input throws a typed
  `BrotliException`, and a size limit guards against decompression bombs.
- **Checked against the reference:** CI decodes our streams with Google's
  `brotli` CLI, and theirs with ours, at every quality.

## Usage

### One-shot

```dart
import 'package:brotli_fast/brotli_fast.dart';

final packed = brotliEncode(data, quality: 9);
final restored = brotliDecode(packed);
```

`quality` trades speed for size: **0–5** favor speed (**5**, the default, is a
good balance), **6–11** favor ratio and get progressively slower.
`windowBits` (default 22, a 4 MiB window) can be lowered to save memory on
the decoding side.

### Strings

```dart
import 'dart:convert';

final text = utf8.fuse(brotli);
final packed = text.encode('héllo, wörld');
final restored = text.decode(packed);
```

### Streams

`brotli.encoder` and `brotli.decoder` are stream transformers:

```dart
import 'dart:io';

await File('data.json')
    .openRead()
    .transform(brotli.encoder)
    .pipe(File('data.json.br').openWrite());

await File('data.json.br')
    .openRead()
    .transform(brotli.decoder)
    .pipe(File('data.json').openWrite());
```

Use `BrotliCodec(quality: 9)` or `BrotliEncoder(quality: 9)` for other
settings. The streaming encoder emits a compressed block for every 128 KiB of
input. It keeps the input it has seen in memory, so it bounds latency, not
memory.

### Dictionaries

When many small payloads share structure (JSON with a common schema, HTML
templates), a dictionary known to both sides shrinks them considerably:

```dart
final dictionary = BrotliDictionary(utf8.encode(sampleRecords));

final packed = brotliEncode(record, quality: 9, dictionary: dictionary);
final restored = brotliDecode(packed, dictionary: dictionary);
```

Reuse one `BrotliDictionary` instance: its match index is built on the first
encode. The decoder must be given the same bytes. Brotli streams carry no
dictionary checksum, so a different dictionary decodes to different data.

### Decoding untrusted input

```dart
try {
  final restored = brotliDecode(input, maxOutputSize: 10 << 20); // 10 MiB
} on BrotliException catch (e) {
  print('rejected: ${e.code.name}'); // e.g. truncatedInput, outputLimitExceeded
}
```

`brotliDecode` limits output to 1 GiB by default. `BrotliException` is a
`FormatException`.

## Performance

PERFORMANCE_TABLE

Throughput in MB/s on the deterministic 1 MiB text and binary corpus of
[`benchmark/`](benchmark/), measured AOT on an Apple M5 (median of 5 runs).
Numbers are machine-specific; run `dart run benchmark/perf_history.dart` to
measure on your own hardware. [`benchmark/HISTORY.md`](benchmark/HISTORY.md)
tracks them over time.

## Compatibility

- **Streams:** standard RFC 7932, readable by any Brotli decoder (browsers,
  the `brotli` CLI, HTTP servers and proxies). Large-window streams (`windowBits` above 24) need a
  decoder that opts in.
- **Platforms:** Dart SDK 3.13+; VM, AOT, Flutter, dart2js and dart2wasm.
  Web builds produce byte-identical output to the VM.

## API Documentation

See the [API documentation](https://pub.dev/documentation/brotli_fast/latest/).

## Source

The official source code is
[hosted @ GitHub](https://github.com/Colossus-Services/brotli_fast).

## Features and bugs

Please file feature requests and bugs at the
[issue tracker](https://github.com/Colossus-Services/brotli_fast/issues).

## License

[MIT](LICENSE). Includes the RFC 7932 static dictionary and tables from
[google/brotli](https://github.com/google/brotli) (MIT); see [NOTICE](NOTICE).
