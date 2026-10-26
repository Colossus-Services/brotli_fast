/// Backend selection for the decoder bit reader.
///
/// VM/AOT and dart2wasm get the 64-bit accumulator implementation; dart2js
/// falls back to the 32-bit-safe port. Both expose the same `BitReader` API and
/// produce byte-identical output.
library;

export 'bit_reader_input.dart';
export 'bit_reader_64.dart' if (dart.library.js_util) 'bit_reader_32.dart';
