# Performance history

A running log of `brotli_fast` throughput, one entry per measured change, each
with its Δ against an earlier snapshot. See [README.md](README.md) for how an
entry is recorded.

Reading the numbers:

- **Same host only.** Absolute MB/s is machine-specific; Δ columns are only
  meaningful between snapshots taken on the same CPU (the tool warns
  otherwise).
- **Noise floor ≈ ±2.5%.** Re-running an unchanged tree moves rows by up to
  about 2.5%; text decode is the noisiest row (a 1 MiB decode is ~0.3 ms per
  sample). Treat smaller changes as noise.
- **Compressed bytes must not move silently.** A speed-up that changes the
  output has to say so in its entry.

---

## 2026-10-26 · `e440adb` · brotli_fast 1.0.0

Host: macOS, Apple M5, 10 cores, Dart 3.13.5. AOT, median of 5 runs × 25
rounds (1 warm-up run discarded).
Snapshot: [`history/baseline.json`](history/baseline.json).

Δ against the brotli_neo v0.2.0 baseline (`de22037`) measured on the same
host, i.e. what this package gained over the code it was derived from.
Compressed sizes are identical: the encoder output is byte-identical.

| corpus | op | q | MB/s | spread | compressed bytes | Δ MB/s | Δ bytes |
|---|---|--:|--:|--:|--:|--:|--:|
| text | encode | 0 | 938.4 | ±2.7% | 12489 | +19.0% | 0 |
| text | decode | 0 | 2835.9 | ±2.6% | – | -5.8% | – |
| text | encode | 1 | 812.4 | ±1.3% | 12128 | +24.9% | 0 |
| text | decode | 1 | 3240.5 | ±3.0% | – | -4.3% | – |
| text | encode | 5 | 510.2 | ±1.3% | 12546 | +1.6% | 0 |
| text | decode | 5 | 3232.6 | ±4.0% | – | -2.3% | – |
| text | encode | 9 | 72.2 | ±3.3% | 10774 | +67.5% | 0 |
| text | decode | 9 | 2810.6 | ±0.5% | – | -1.8% | – |
| binary | encode | 0 | 417.4 | ±0.8% | 167026 | +13.4% | 0 |
| binary | decode | 0 | 1130.8 | ±1.3% | – | +16.5% | – |
| binary | encode | 1 | 423.8 | ±2.7% | 167026 | +14.7% | 0 |
| binary | decode | 1 | 1133.4 | ±3.5% | – | +7.4% | – |
| binary | encode | 5 | 302.2 | ±1.9% | 159953 | +4.7% | 0 |
| binary | decode | 5 | 1301.6 | ±1.4% | – | -1.4% | – |
| binary | encode | 9 | 26.4 | ±0.9% | 159455 | +32.7% | 0 |
| binary | decode | 9 | 1306.6 | ±1.9% | – | -3.8% | – |

Where the encoder gains come from (all byte-identical):

- q6–q11 match finder: a one-byte candidate prefilter, inlined hash helpers,
  and the 32 MiB q9 hash table reused between calls instead of reallocated;
- block-split clustering: an unboxed log2 cache and sparse histogram pair
  costs;
- `mul32` as one native multiply on the VM (it was four 16-bit multiplies
  everywhere), which also speeds up q0/q1;
- the binary q0/q1 tier no longer allocates an unused 4-bytes-per-input
  chain array.

Decode: binary q0/q1 streams decode faster; the other rows are within noise
to −6%. The decoder now checks ring wrap-around on every copy and keeps the
reachable distance sticky in its fast path. That is the cost of fixing silent
misdecoding at small windows (see CHANGELOG), and the text rows show it most.

Next candidates: text decode (win back the wrap checks, e.g. by choosing the
fast path per meta-block only when the ring cannot wrap); q9 text match
finding (~55% of q9 time); binary q9 clustering; and the compound-dictionary
parse, which compresses 3–4× worse than the reference CLI's `-D`.
