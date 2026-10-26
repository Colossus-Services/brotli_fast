/// Unaligned reads and match-length comparison over the encoder input.
///
/// VM, AOT and dart2wasm get single unaligned `ByteData` loads and compare
/// 8 bytes per step; dart2js has no 64-bit `ByteData` accessors and keeps the
/// byte-assembled 32-bit version. Both return identical results.
library;

export 'byte_access_vm.dart' if (dart.library.js_util) 'byte_access_web.dart';
