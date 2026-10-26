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

Derived from [brotli_neo](https://github.com/gmpassos/dart_brotli), as one
implementation instead of two:

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
- Quality 9 encodes 60% faster on text and 30% faster on binary, with
  byte-identical output.
