/// Conditional wide ring-copy backend.
///
/// The VM/AOT/dart2wasm implementation uses 64-bit `ByteData` loads/stores
/// (fast; `dart2js` rejects those accessors at compile time). dart2js falls
/// back to 32-bit accesses.
///
/// Both implementations have identical semantics and are byte-identical; the
/// caller only uses them for forward overlapping copies where
/// `dst - src >= 8`, so word-at-a-time forward copies cannot read bytes that
/// have not been written yet.
library;

export 'wide_copy_vm.dart' if (dart.library.js_util) 'wide_copy_web.dart';
