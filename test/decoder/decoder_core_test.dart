/// Frame layer of [BrotliDecoderCore]: stream header, metadata and
/// uncompressed metablocks, ring-buffer flush/wrap and header errors.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:brotli_fast/src/common/errors.dart';
import 'package:brotli_fast/src/decoder/bit_reader.dart';
import 'package:brotli_fast/src/decoder/decoder.dart';
import 'package:brotli_fast/src/decoder/decoder_core.dart';
import 'package:brotli_fast/src/decoder/decoder_state.dart';
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

import '../support/corpus.dart';
import 'decoder_helpers.dart';

Uint8List _u8(List<int> values) => Uint8List.fromList(values);

/// Writes an ISLAST + ISLASTEMPTY metablock (the canonical stream terminator).
void _writeLastEmptyMetaBlock(BitSink sink) {
  sink.writeBits(1, 1); // ISLAST
  sink.writeBits(1, 1); // ISLASTEMPTY
  sink.alignToByte();
}

/// Writes a metadata metablock header for [length] payload bytes.
///
/// A zero-length metadata block is encoded with `sizeBytes == 0`; otherwise the
/// length is transmitted as `length - 1` in the minimal number of bytes.
void _writeMetadataMetaBlock(BitSink sink, int length) {
  sink.writeBits(0, 1); // ISLAST == 0
  if (length == 0) {
    sink.writeBits(3, 2); // MNIBBLES == 7 (metadata)
    sink.writeBits(0, 1); // reserved
    sink.writeBits(0, 2); // sizeBytes == 0
    sink.alignToByte();
    return;
  }
  var value = length - 1;
  var sizeBytes = 1;
  if (value >= 1 << 16) {
    sizeBytes = 3;
  } else if (value >= 1 << 8) {
    sizeBytes = 2;
  }
  sink.writeBits(3, 2);
  sink.writeBits(0, 1);
  sink.writeBits(sizeBytes, 2);
  for (var i = 0; i < sizeBytes; i++) {
    sink.writeBits(value & 0xFF, 8);
    value >>= 8;
  }
  sink.alignToByte();
}

/// Writes an uncompressed metablock header for [length] payload bytes.
void _writeUncompressedHeader(BitSink sink, int length) {
  assert(length > 0 && length <= maxMetaBlockLength);
  var value = length - 1;
  var nibbles = 4;
  if (value >= 1 << 20) {
    nibbles = 6;
  } else if (value >= 1 << 16) {
    nibbles = 5;
  }
  sink.writeBits(0, 1); // ISLAST == 0
  sink.writeBits(nibbles - 4, 2);
  for (var i = 0; i < nibbles; i++) {
    sink.writeBits(value & 0xF, 4);
    value >>= 4;
  }
  sink.writeBits(1, 1); // ISUNCOMPRESSED
  sink.alignToByte();
}

/// Writes a complete uncompressed metablock (header + payload).
void _writeUncompressedMetaBlock(BitSink sink, Uint8List payload) {
  _writeUncompressedHeader(sink, payload.length);
  for (final byte in payload) {
    sink.writeRawByte(byte);
  }
}

/// Builds `window bits + uncompressed block + ISLASTEMPTY`.
Uint8List _buildRawStream(
  int windowBits,
  Uint8List payload, {
  bool largeWindow = false,
}) {
  final sink = BitSink();
  writeWindowBits(sink, windowBits, large: largeWindow);
  _writeUncompressedMetaBlock(sink, payload);
  _writeLastEmptyMetaBlock(sink);
  return sink.toBytes();
}

Uint8List _pattern(int length, {int seed = 7}) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31 + seed) & 0xFF;
  }
  return bytes;
}

void main() {
  final corpus = Corpus.load();

  CorpusEntry entry(String name) =>
      corpus.entries.firstWhere((e) => e.name == name);

  MalformedVector variant(String name) =>
      corpus.malformed.firstWhere((m) => m.name == name);

  group('corpus frame-only vectors', () {
    test('empty.compressed decodes to empty', () {
      final run = decodeCore(corpus.compressedBytes(entry('empty')));
      expect(run.bytes, isEmpty);
      expect(run.state.windowBits, 16);
      expect(run.state.largeWindow, isFalse);
      expect(run.state.ringBufferSize, 0);
    });

    test('x.compressed decodes to its single byte', () {
      final run = decodeCore(corpus.compressedBytes(entry('x')));
      expect(run.bytes, orderedEquals(corpus.rawBytes(entry('x'))));
      expect(run.bytes, orderedEquals(_u8(<int>[0x58])));
      expect(run.state.windowBits, 22);
    });

    test('all-uncompressed corpus pairs decode byte-exact', () {
      // These vectors contain only metadata / uncompressed metablocks, so the
      // frame layer alone must reproduce them exactly.
      const names = <String>[
        'empty',
        'x',
        'xyzzy',
        'quickfox',
        'random_org_10k.bin',
        'compressed_file',
      ];
      for (final name in names) {
        final e = entry(name);
        final run = decodeCore(corpus.compressedBytes(e));
        expect(run.bytes.length, e.rawBytes, reason: name);
        expect(run.bytes, orderedEquals(corpus.rawBytes(e)), reason: name);
      }
    });

    test('one-shot decode() matches the core loop', () {
      final raw = corpus.rawBytes(entry('random_org_10k.bin'));
      final out = decode(corpus.compressedBytes(entry('random_org_10k.bin')));
      expect(out, orderedEquals(raw));
      expect(decode(corpus.compressedBytes(entry('empty'))), isEmpty);
      expect(
        decode(corpus.malformedBytes(variant('empty.compressed.18'))),
        isEmpty,
      );
      expect(
        () => decode(
          corpus.compressedBytes(entry('random_org_10k.bin')),
          maxOutputSize: 100,
        ),
        throwsBrotli(BrotliErrorCode.outputLimitExceeded),
      );
    });
  });

  group('variant corpus (coverage streams, not errors)', () {
    test('empty.compressed.00-.14 cover window bits 10..24', () {
      // These files are a window-bits coverage corpus: .00 is byte-identical
      // to empty.compressed (16 bits), .01-.14 encode the remaining sizes.
      const expectedWindowBits = <int>[
        16, 17, 10, 11, 12, 13, 14, 15, 18, 19, 20, 21, 22, 23, 24, //
      ];
      for (var i = 0; i < expectedWindowBits.length; i++) {
        final name = 'empty.compressed.${i.toString().padLeft(2, '0')}';
        final run = decodeCore(corpus.malformedBytes(variant(name)));
        expect(run.bytes, isEmpty, reason: name);
        expect(run.state.windowBits, expectedWindowBits[i], reason: name);
        expect(run.state.largeWindow, isFalse, reason: name);
        expect(run.state.ringBufferSize, 0, reason: name);
      }
    });

    test('empty.compressed.15-.18 are empty metadata/plain streams', () {
      const expectedWindowBits = <String, int>{
        'empty.compressed.15': 16,
        'empty.compressed.16': 17,
        'empty.compressed.17': 17,
        'empty.compressed.18': 17,
      };
      for (final testCase in expectedWindowBits.entries) {
        final run = decodeCore(corpus.malformedBytes(variant(testCase.key)));
        expect(run.bytes, isEmpty, reason: testCase.key);
        expect(run.state.windowBits, testCase.value, reason: testCase.key);
        expect(run.state.ringBufferSize, 0, reason: testCase.key);
      }
    });

    test('x.compressed.00-.03 decode to X', () {
      for (final name in <String>[
        'x.compressed.00',
        'x.compressed.01',
        'x.compressed.02',
        'x.compressed.03', // compressed metablock
      ]) {
        final run = decodeCore(corpus.malformedBytes(variant(name)));
        expect(run.bytes, orderedEquals(_u8(<int>[0x58])), reason: name);
      }
    });

    test('every variant decodes without error (no crash/hang)', () {
      for (final vector in corpus.malformed) {
        try {
          final run = decodeCore(corpus.malformedBytes(vector));
          // All variants are empty or single-byte streams.
          expect(run.bytes.length, anyOf(0, 1), reason: vector.name);
        } on BrotliException catch (error) {
          fail('${vector.name} raised ${error.code.name}: ${error.message}');
        }
      }
    });
  });

  group('synthetic frame streams', () {
    test('window bits 10/16/17/22/24 round-trip uncompressed data', () {
      final payload = _pattern(300);
      for (final windowBits in <int>[10, 16, 17, 22, 24]) {
        final run = decodeCore(_buildRawStream(windowBits, payload));
        expect(run.state.windowBits, windowBits, reason: 'wbits=$windowBits');
        expect(run.bytes, orderedEquals(payload), reason: 'wbits=$windowBits');
        expect(
          run.state.ringBufferSize,
          lessThanOrEqualTo(1 << windowBits),
          reason: 'wbits=$windowBits',
        );
      }
    });

    test('large-window encoding is accepted only when enabled', () {
      final payload = _u8(<int>[0xDE, 0xAD, 0xBE, 0xEF]);
      final stream = _buildRawStream(10, payload, largeWindow: true);
      final run = decodeCore(stream, allowLargeWindow: true);
      expect(run.state.windowBits, 10);
      expect(run.state.largeWindow, isTrue);
      expect(run.bytes, orderedEquals(payload));
      expect(
        () => decodeCore(stream),
        throwsBrotli(BrotliErrorCode.invalidWindowBits),
      );
    });

    test('metadata payloads are skipped and interleave with raw blocks', () {
      final sink = BitSink();
      writeWindowBits(sink, 16);
      _writeMetadataMetaBlock(sink, 9);
      for (var i = 0; i < 9; i++) {
        sink.writeRawByte(0xA0 + i);
      }
      _writeUncompressedMetaBlock(sink, _u8(<int>[1, 2, 3]));
      _writeMetadataMetaBlock(sink, 0);
      _writeMetadataMetaBlock(sink, 300);
      for (var i = 0; i < 300; i++) {
        sink.writeRawByte(i & 0xFF);
      }
      _writeUncompressedMetaBlock(sink, _u8(<int>[4, 5]));
      _writeLastEmptyMetaBlock(sink);

      final run = decodeCore(sink.toBytes());
      expect(run.bytes, orderedEquals(_u8(<int>[1, 2, 3, 4, 5])));
      // Metadata never contributes to the expected output size.
      expect(run.state.expectedTotalSize, 5);
    });

    test('metadata larger than the input window is skipped', () {
      final sink = BitSink();
      writeWindowBits(sink, 22);
      _writeMetadataMetaBlock(sink, 70000);
      for (var i = 0; i < 70000; i++) {
        sink.writeRawByte((i * 13 + 1) & 0xFF);
      }
      _writeUncompressedMetaBlock(sink, _u8(<int>[0x42]));
      _writeLastEmptyMetaBlock(sink);

      final stream = sink.toBytes();
      final run = decodeCore(stream, chunkSize: 4096);
      expect(run.bytes, orderedEquals(_u8(<int>[0x42])));
      expect(run.state.expectedTotalSize, 1);
      // Also when the metadata payload arrives in small pieces.
      expect(
        decodeCoreChunked(stream, inputChunk: 999, outputChunk: 7).bytes,
        orderedEquals(_u8(<int>[0x42])),
      );
    });

    test('ring buffer wraps for > 64 KiB of uncompressed output', () {
      final payload = _pattern(200000);
      final stream = _buildRawStream(16, payload);
      final run = decodeCore(stream, chunkSize: 1000);
      expect(run.state.ringBufferSize, 65536);
      expect(run.bytes.length, payload.length);
      expect(run.bytes, orderedEquals(payload));
    });

    test('uncompressed block ending exactly at the ring end flushes', () {
      // 2 * 65536: the last copy fills the window exactly, so the flush and the
      // metablock end coincide (a documented tricky path in the reference).
      final payload = _pattern(131072);
      final run = decodeCore(_buildRawStream(16, payload), chunkSize: 7000);
      expect(run.state.ringBufferSize, 65536);
      expect(run.bytes, orderedEquals(payload));
    });

    test('ring buffer grows only as much as expectedTotalSize needs', () {
      final run = decodeCore(_buildRawStream(24, _pattern(5)));
      expect(run.bytes, orderedEquals(_pattern(5)));
      expect(run.state.ringBufferSize, lessThan(1 << 24));
      expect(run.state.ringBufferSize, greaterThanOrEqualTo(5));
      // The allocation may be a pooled, larger buffer, but it always carries
      // the transformed-word slack after the window.
      expect(
        run.state.ringBuffer.length,
        greaterThanOrEqualTo(
          run.state.ringBufferSize + maxTransformedWordLength,
        ),
      );
    });

    test('tiny output buffers flush without losing bytes', () {
      final payload = _u8(<int>[10, 20, 30, 40, 50]);
      for (final chunkSize in <int>[1, 2, 3, 7]) {
        final run = decodeCore(
          _buildRawStream(16, payload),
          chunkSize: chunkSize,
        );
        expect(run.bytes, orderedEquals(payload), reason: 'chunk=$chunkSize');
      }
    });

    test('decode honours the output start offset', () {
      final core = BrotliDecoderCore(
        BitReader.fromBytes(_buildRawStream(16, _u8(<int>[1, 2, 3]))),
      );
      final buffer = Uint8List(10)..fillRange(0, 10, 0xEE);
      final status = core.decode(buffer, 3, 7);
      expect(status, BrotliStatus.done);
      expect(core.bytesWritten, 3);
      expect(buffer.sublist(3, 6), orderedEquals(_u8(<int>[1, 2, 3])));
      expect(buffer[0], 0xEE);
      expect(buffer[2], 0xEE);
      expect(buffer[6], 0xEE);
      expect(buffer[9], 0xEE);
    });

    test('decode validates the output slice', () {
      final core = BrotliDecoderCore(BitReader.fromBytes(Uint8List(0)));
      expect(() => core.decode(Uint8List(8), 5, 2), throwsRangeError);
      expect(() => core.decode(Uint8List(8), -1), throwsRangeError);
      expect(() => core.decode(Uint8List(8), 0, 9), throwsRangeError);
    });

    test('done is idempotent', () {
      final core = BrotliDecoderCore(
        BitReader.fromBytes(_buildRawStream(16, _u8(<int>[1, 2, 3]))),
      );
      final buffer = Uint8List(16);
      expect(core.decode(buffer), BrotliStatus.done);
      expect(core.bytesWritten, 3);
      expect(core.decode(buffer), BrotliStatus.done);
      expect(core.bytesWritten, 0);
      expect(core.decode(buffer), BrotliStatus.done);
      expect(core.bytesWritten, 0);
    });

    test('maxOutputSize guards decompression bombs', () {
      final payload = Uint8List(200000);
      final stream = _buildRawStream(16, payload);
      expect(
        () => decodeCore(stream, maxOutputSize: 199999, chunkSize: 1000),
        throwsBrotli(BrotliErrorCode.outputLimitExceeded),
      );
      final run = decodeCore(stream, maxOutputSize: 200000, chunkSize: 1000);
      expect(run.bytes.length, 200000);
    });
  });

  group('malformed synthetic streams', () {
    test('empty input is reported as truncated', () {
      expect(
        () => decodeCore(Uint8List(0)),
        throwsBrotli(BrotliErrorCode.truncatedInput),
      );
    });

    test('reserved window-bits value is rejected', () {
      final sink = BitSink();
      sink.writeBits(1, 1);
      sink.writeBits(0, 3);
      sink.writeBits(1, 3); // large-window marker: reserved for RFC streams
      sink.alignToByte();
      expect(
        () => decodeCore(sink.toBytes()),
        throwsBrotli(BrotliErrorCode.invalidWindowBits),
      );
    });

    test('large-window reserved bit is rejected', () {
      final sink = BitSink();
      sink.writeBits(1, 1);
      sink.writeBits(0, 3);
      sink.writeBits(1, 3);
      sink.writeBits(1, 1); // reserved extension bit must be zero
      sink.alignToByte();
      expect(
        () => decodeCore(sink.toBytes(), allowLargeWindow: true),
        throwsBrotli(BrotliErrorCode.invalidWindowBits),
      );
    });

    test('large-window bits outside 10..30 are rejected', () {
      for (final bits in <int>[9, 31]) {
        final sink = BitSink();
        sink.writeBits(1, 1);
        sink.writeBits(0, 3);
        sink.writeBits(1, 3);
        sink.writeBits(0, 1);
        sink.writeBits(bits, 6);
        sink.alignToByte();
        expect(
          () => decodeCore(sink.toBytes(), allowLargeWindow: true),
          throwsBrotli(BrotliErrorCode.invalidWindowBits),
          reason: 'bits=$bits',
        );
      }
    });

    test('metadata reserved bit is rejected', () {
      final sink = BitSink();
      writeWindowBits(sink, 16);
      sink.writeBits(0, 1); // ISLAST
      sink.writeBits(3, 2); // MNIBBLES == 7
      sink.writeBits(1, 1); // reserved bit set
      sink.alignToByte();
      expect(
        () => decodeCore(sink.toBytes()),
        throwsBrotli(BrotliErrorCode.invalidMetaBlockLength),
      );
    });

    test('metadata exuberant last length byte is rejected', () {
      final sink = BitSink();
      writeWindowBits(sink, 16);
      sink.writeBits(0, 1);
      sink.writeBits(3, 2);
      sink.writeBits(0, 1);
      sink.writeBits(2, 2); // sizeBytes == 2
      sink.writeBits(0, 8); // both bytes zero: last byte is exuberant
      sink.writeBits(0, 8);
      sink.alignToByte();
      expect(
        () => decodeCore(sink.toBytes()),
        throwsBrotli(BrotliErrorCode.invalidMetaBlockLength),
      );
    });

    test('metablock exuberant last length nibble is rejected', () {
      final sink = BitSink();
      writeWindowBits(sink, 16);
      sink.writeBits(0, 1); // ISLAST
      sink.writeBits(1, 2); // MNIBBLES == 5
      sink.writeBits(0, 4); // nibble 0
      sink.writeBits(0, 4); // nibble 1
      sink.writeBits(0, 4); // nibble 2
      sink.writeBits(0, 4); // nibble 3
      sink.writeBits(0, 4); // last nibble zero => exuberant
      sink.writeBits(1, 1); // ISUNCOMPRESSED
      sink.alignToByte();
      expect(
        () => decodeCore(sink.toBytes()),
        throwsBrotli(BrotliErrorCode.invalidMetaBlockLength),
      );
    });

    test('non-zero padding before an uncompressed payload is rejected', () {
      final sink = BitSink();
      writeWindowBits(sink, 16);
      sink.writeBits(0, 1); // ISLAST
      sink.writeBits(0, 2); // MNIBBLES == 4
      sink.writeBits(0, 16); // length - 1 == 0
      sink.writeBits(1, 1); // ISUNCOMPRESSED
      // 21 bits written so far: three padding bits follow.
      sink.writeBits(1, 1); // padding bit must be zero
      sink.writeBits(0, 2);
      sink.writeRawByte(0xAA);
      expect(
        () => decodeCore(sink.toBytes()),
        throwsBrotli(BrotliErrorCode.corruptPadding),
      );
    });

    test('non-zero padding after the last metablock is rejected', () {
      final sink = BitSink();
      writeWindowBits(sink, 16);
      sink.writeBits(1, 1); // ISLAST
      sink.writeBits(1, 1); // ISLASTEMPTY
      sink.writeBits(1, 5); // padding bits must be zero
      expect(
        () => decodeCore(sink.toBytes()),
        throwsBrotli(BrotliErrorCode.corruptPadding),
      );
    });

    test('truncated metadata payload is rejected', () {
      final sink = BitSink();
      writeWindowBits(sink, 16);
      _writeMetadataMetaBlock(sink, 10);
      sink.writeRawByte(1);
      sink.writeRawByte(2);
      sink.writeRawByte(3);
      expect(
        () => decodeCore(sink.toBytes()),
        throwsBrotli(BrotliErrorCode.truncatedInput),
      );
    });

    test('truncated uncompressed payload is rejected', () {
      final sink = BitSink();
      writeWindowBits(sink, 16);
      _writeUncompressedHeader(sink, 10);
      sink.writeRawByte(1);
      sink.writeRawByte(2);
      sink.writeRawByte(3);
      expect(
        () => decodeCore(sink.toBytes()),
        throwsBrotli(BrotliErrorCode.truncatedInput),
      );
    });

    test('a stream without a last metablock is rejected', () {
      final sink = BitSink();
      writeWindowBits(sink, 16);
      _writeUncompressedMetaBlock(sink, _u8(<int>[1, 2, 3]));
      expect(
        () => decodeCore(sink.toBytes()),
        throwsBrotli(BrotliErrorCode.truncatedInput),
      );
    });

    test('trailing garbage after a complete stream is rejected', () {
      final sink = BitSink();
      writeWindowBits(sink, 16);
      _writeLastEmptyMetaBlock(sink);
      sink.writeRawByte(0x00);
      expect(
        () => decodeCore(sink.toBytes()),
        throwsBrotli(BrotliErrorCode.unusedBytesAfterEnd),
      );
    });
  });
}
