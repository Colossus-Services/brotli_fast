/// Whether the fused whole-metablock fast loop is safe on this platform.
///
/// The fused loop is written around the 64-bit accumulator contract (it
/// deliberately skips per-field refills). dart2wasm supports 64-bit typed-data
/// accessors, so it keeps the fast loop; dart2js needs the resumable state
/// machine, which refills before every wide read.
library;

export 'fast_metablock_supported_vm.dart'
    if (dart.library.js_util) 'fast_metablock_supported_web.dart';
