/// Inputs for the cross-platform output parity test (`test/parity_test.dart`).
///
/// Every encoder path whose integer arithmetic differs between the VM (64-bit
/// ints) and dart2js (JavaScript numbers) is covered: the fast tier (lazy and
/// both binary variants), the greedy text path and the high-ratio paths.
library;

import 'dart:typed_data';

import '../../benchmark/corpus.dart';

/// Input shapes.
enum ParityKind { text, binary, zeros }

final class ParityVector {
  const ParityVector(this.kind, this.size, this.quality, this.sha256);

  final ParityKind kind;
  final int size;
  final int quality;

  /// SHA-256 of the VM's `brotliEncode(input(), quality: quality)`.
  final String sha256;

  Uint8List input() => switch (kind) {
    ParityKind.text => makeText(size),
    ParityKind.binary => makeBinary(size),
    ParityKind.zeros => Uint8List(size),
  };

  @override
  String toString() => '${kind.name} $size q$quality';
}

const List<ParityVector> parityVectors = <ParityVector>[
  // Greedy text path.
  ParityVector(
    ParityKind.text,
    100000,
    0,
    '5066e130a8a222fc2bd76cd37559444cc7a9690033c748a2ceaf9360805fdaf0',
  ),
  ParityVector(
    ParityKind.text,
    100000,
    1,
    '7af13551045bfffdefec05a68a153fa170240f31c6de509232cd6cd3e4c969d0',
  ),
  // Fast tier: binary greedy (q0/q1), binary q5, lazy q2..5.
  ParityVector(
    ParityKind.binary,
    100000,
    1,
    'e540b9b3d90897b61f71921064b611eedc3ce402e91144e588830dac032eaa0a',
  ),
  ParityVector(
    ParityKind.binary,
    100000,
    5,
    'b052fc72233b5f3f8cc369a6e692a5dcd59a0ac28324f3f9b4bed6e404e8b0b8',
  ),
  ParityVector(
    ParityKind.binary,
    100000,
    3,
    'b681be73576936736e899aada9d1487ed53ffdc986f10ef8c6184a031dbd52a0',
  ),
  ParityVector(
    ParityKind.text,
    100000,
    5,
    '94779e4e578b3ae2568a94266c1aaffabe10c8421aa7a047621a0e5b18715ad5',
  ),
  ParityVector(
    ParityKind.zeros,
    4096,
    5,
    '1ebe8476027fc38097756772dfff67547f8cd9850ee94270219cfc2a662e21e8',
  ),
  // High-ratio paths.
  ParityVector(
    ParityKind.text,
    100000,
    7,
    '62805b786da9d0e48e56575dc87e2f5bd4b42057f7f96a240bb48ace8ef3137d',
  ),
  ParityVector(
    ParityKind.binary,
    100000,
    9,
    'f5a4dfcca923d14fe75340b95cef7653a2f13b1820872ca3689c9e9fb9cea9ee',
  ),
  ParityVector(
    ParityKind.text,
    30000,
    11,
    'f2c25f06c5be86f0913bb3c974e07c7e4090d2e12ac350e71c704ba3b2199a9f',
  ),
];
