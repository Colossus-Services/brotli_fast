# Benchmarks

Throughput of `brotliEncode` and `brotliDecode` on a deterministic 1 MiB
corpus: moderately compressible text and structured binary data
([`corpus.dart`](corpus.dart), identical on every platform).

```
benchmark/corpus.dart          deterministic 1 MiB text and binary inputs
benchmark/bench.dart           one measurement run: median MB/s per operation
benchmark/perf_history.dart    AOT build, repeated runs, snapshot + Markdown
benchmark/HISTORY.md           performance log, one entry per measured change
benchmark/history/*.json       machine-readable snapshots behind HISTORY.md
```

## Quick run

```sh
dart run benchmark/bench.dart --qualities 0,1,5,9
```

This runs under the JIT and prints one line per operation. For numbers worth
comparing, use the recorder below.

## Recording a history entry

```sh
dart run benchmark/perf_history.dart \
  --label "what changed" \
  --baseline benchmark/history/<previous>.json \
  --save benchmark/history/<yyyy-mm-dd>-<topic>.json
```

It compiles `bench.dart` to AOT, runs it 1 + 5 times (the first run is a
discarded warm-up), and reports the median MB/s across runs, the min..max
spread and the compressed size, which must be identical in every run. With
`--baseline` it adds Δ columns. Paste the printed section into
[`HISTORY.md`](HISTORY.md).

Numbers are machine-specific: compare snapshots from the same host only, and
keep the machine otherwise idle.
