/// Portable 32-bit helpers shared by the decoder and encoder.
///
/// Brotli's bit stream is defined in terms of 32-bit wrap-around arithmetic.
/// These helpers keep every intermediate value in `[0, 2^32)` so the same code
/// is correct on the VM, dart2js and dart2wasm. Do not replace `& 0xFFFFFFFF`
/// with `>>>`.
library;

const int k32Mask = 0xFFFFFFFF;
const int k16Mask = 0xFFFF;

/// Whether integers are JavaScript numbers (dart2js: exact only below 2^53,
/// 32-bit shifts). A compile-time constant, so VM, AOT and dart2wasm builds
/// keep only their native 64-bit paths.
const bool jsNumbers = bool.fromEnvironment('dart.library.js_util');

/// Returns the floor of log2 of [x]; [x] must be positive.
int log2Floor(int x) {
  assert(x > 0);
  var result = -1;
  var step = 16;
  var v = x;
  while (step > 0) {
    final next = v >> step;
    if (next != 0) {
      result += step;
      v = next;
    }
    step >>= 1;
  }
  return result + v;
}

/// Low 32 bits of `a * b` for 32-bit [a] and [b], identical on every platform.
///
/// 64-bit integers wrap, so their low 32 bits are exact; JavaScript numbers
/// would lose them above 2^53, so dart2js multiplies 16-bit halves.
@pragma('vm:prefer-inline')
int mul32(int a, int b) {
  if (!jsNumbers) return (a * b) & k32Mask;
  final aLo = a & k16Mask;
  final aHi = (a >> 16) & k16Mask;
  final bLo = b & k16Mask;
  final bHi = (b >> 16) & k16Mask;
  final lo = aLo * bLo;
  final mid = aLo * bHi + aHi * bLo;
  return (lo + ((mid & k16Mask) << 16)) & k32Mask;
}

/// Aligns a bit position up to the next byte boundary.
int alignToByte(int bitPosition) => (bitPosition + 7) & ~7;
