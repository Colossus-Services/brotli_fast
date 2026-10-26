# Compound-dictionary fixtures

These binary fixtures were produced with the authoritative Rust oracle
(`brotli` crate 9.0.0, `brotli-oracle compress --dictionary`), not by the Dart
encoder:

| file | bytes | sha256 |
|---|---|---|
| `text.dict` | 4096 | `044D8602CC1DABFD07300E24EABC1BE4B47F71D149483580E685EB792E569E27` |
| `text.raw` | 2015 | `35EC2643B5E65BA981477D3BC9D300D90D621337605540458CB050FB1C053409` |
| `text.br` | 60 | `90AC034506E24D7D7CA455281665872992D1232C3305AFC3F39F666415AF9B5F` |
| `window.dict` | 6144 | `C7F1A88212AF8081EB1454F823430F49F271D94FDEC255C4156AAD6792B09356` |
| `window.raw` | 4503 | `EB3851C1ED28468942235457529A7AD949A728A1D6F5E0B626E80BEAA987EC65` |
| `window.br` | 22 | `D9D3D2FC18BB6ADABFC2EF2B406076F96D7FEE633BC044E11F9EC962C2B52387` |

Commands (with `BROTLI_ORACLE` pointing at the oracle executable):

```sh
brotli-oracle compress -i text.raw -o text.br --dictionary text.dict -q 5 -w 22
brotli-oracle compress -i window.raw -o window.br --dictionary window.dict -q 5 -w 10
brotli-oracle decompress -i text.br --dictionary text.dict -o text.out   # == text.raw
brotli-oracle decompress -i window.br --dictionary window.dict -o window.out  # == window.raw
```

`window` uses lgwin 10 (1 KiB ring window) with a 6 KiB dictionary, so the
compound copy spans ring flushes and the decoder must keep the dictionary
address across them. `text` is a normal-window stream with a 4 KiB dictionary.
