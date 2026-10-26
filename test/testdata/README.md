# Brotli conformance vectors

These files are copied from `google/brotli` `tests/testdata` (MIT license).
They are used only by the decoder tests; the package does not read this
directory at runtime.

- `*.compressed` + the same name without the suffix: 22 raw/compressed pairs.
- `*.compressed.NN`: coverage variants, **not** uniformly malformed.
  `empty.compressed.00-.14` cover window bits 10..24; `.15-.18` exercise
  metadata/empty frames; `x.compressed.00-.02` decode to `X`; `x.compressed.03`
  is a compressed meta-block. Tests assert the correct outcome per file and use
  synthetic streams for error paths.
- `manifest.json`: sizes and SHA-256 hashes of every pair; the `malformed`
  key is kept as a historical name for the `*.compressed.NN` variant list.

Source: https://github.com/google/brotli/tree/master/tests/testdata

Attribution: Copyright Google Inc., distributed under the MIT license. The
reference implementation's `LICENSE` is reproduced in this package's
`LICENSE`/`NOTICE` files.
