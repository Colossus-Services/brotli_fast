/// Web: use the generic resumable metablock path.
///
/// The fused loop assumes the 64-bit accumulator can service a command symbol
/// plus both extra-bit fields without an intermediate refill. The 32-bit Web
/// reader cannot (its accumulator is 32 bits), so Web routes through the
/// refill-before-every-read state machine instead.
library;

const bool fastMetablockSupported = false;
