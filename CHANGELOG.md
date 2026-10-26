## 1.0.0

First release: a fast, pure Dart Brotli (RFC 7932) encoder and decoder, with
no dependencies.

- **API:** `brotliEncode` / `brotliDecode`, the `dart:convert` codec `brotli`
  (`BrotliCodec`, `BrotliEncoder`, `BrotliDecoder`) with chunked stream
  conversion, `BrotliDictionary` for shared dictionaries, and
  `BrotliException` with typed `BrotliErrorCode`s.
- **Encoder:** qualities 0–11 and window sizes 10–24 bits, plus the
  large-window format (25–30). Qualities 0–5 use a fast tier; 6–11 add
  context modeling, block splitting, distance-parameter search and, at 10–11,
  cost-guided parsing.
- **Decoder:** one-shot and streaming, with a decompression-bomb limit,
  compound and serialized shared dictionaries, and large-window streams on
  opt-in.
- **Platforms:** VM, AOT, Flutter and the web (dart2js and dart2wasm). The
  encoder produces byte-identical output on all of them.
- **Interoperability:** CI cross-checks against the reference `brotli` CLI
  in both directions.
- **License:** Apache 2.0. The bundled google/brotli dictionary, tables and
  test corpus keep their MIT notice in `NOTICE`.

Inspired by [brotli_neo](https://github.com/unk-404/dart_brotli), as a full
rewrite. Compared with it:

- Fixes four decoder bugs that rejected or silently misdecoded valid streams
  on the VM and WASM:
  - long literal runs and long copies (10–24 extra bits) were read without
    refilling the bit window;
  - a meta-block that exactly filled the ring buffer wrapped its position
    before the ring could grow;
  - with small windows (10–17 bits), the one-shot fast path mistook distances
    past the wrapped ring position for dictionary references, and read copy
    sources that wrapped the ring end from past the window;
  - concurrent decoders (two streams through `brotli.decoder`, or a stream
    and a one-shot decode) shared one pooled ring buffer and corrupted each
    other.
- Streamed decoding now rejects trailing data after the end of the stream,
  like one-shot decoding, however the input is chunked (it was ignored when
  it arrived in a later chunk).
- Fixes an encoder crash (`RangeError`) at qualities 2–5 on random-looking
  input.
- The fast tier's hash is now exact under dart2js, so web output matches the
  VM.
- Faster encoding with byte-identical output. Against brotli_neo 0.2.0 on
  the same machine (AOT): text q5 1.7× (858 vs 502 MB/s), text q9 2.2×
  (93 vs 43 MB/s), binary q0–q5 +24–41%. See `benchmark/HISTORY.md`.
- Web-motivated code has per-platform implementations, so the VM, AOT and
  dart2wasm no longer pay for dart2js limits: unaligned reads and 8-byte
  match-length comparison use `ByteData` there, while dart2js keeps its
  32-bit-safe paths.
