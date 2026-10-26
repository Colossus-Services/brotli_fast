/// Shared helpers for the decoder tests: a bit packer for hand-built streams,
/// a chunked [BitReaderInput], decode drivers and byte assertions.
library;

import 'dart:typed_data';

import 'package:brotli_fast/src/common/errors.dart';
import 'package:brotli_fast/src/common/format_tables.dart';
import 'package:brotli_fast/src/decoder/bit_reader.dart';
import 'package:brotli_fast/src/decoder/decoder.dart';
import 'package:brotli_fast/src/decoder/decoder_core.dart';
import 'package:brotli_fast/src/decoder/decoder_state.dart';
import 'package:brotli_fast/src/options.dart';
import 'package:test/test.dart';

/// LSB-first bit packer, the mirror image of [BitReader].
final class BitSink {
  final List<int> _bytes = <int>[];
  int _current = 0;
  int _count = 0;

  int get bitLength => _bytes.length * 8 + _count;

  void writeBits(int value, int count) {
    assert(count >= 0 && count <= 32);
    for (var i = 0; i < count; i++) {
      if (((value >> i) & 1) != 0) {
        _current |= 1 << _count;
      }
      _count++;
      if (_count == 8) {
        _bytes.add(_current);
        _current = 0;
        _count = 0;
      }
    }
  }

  void alignToByte() {
    if (_count > 0) {
      _bytes.add(_current);
      _current = 0;
      _count = 0;
    }
  }

  void writeRawByte(int value) {
    assert(_count == 0, 'raw bytes must be byte aligned');
    _bytes.add(value & 0xFF);
  }

  /// The packed bytes; a partial last byte is zero-padded.
  Uint8List toBytes() {
    final bytes = Uint8List(_bytes.length + (_count > 0 ? 1 : 0));
    bytes.setRange(0, _bytes.length, _bytes);
    if (_count > 0) {
      bytes[bytes.length - 1] = _current;
    }
    return bytes;
  }
}

/// A [BitReaderInput] that hands out at most [bytesPerCall] bytes per read and
/// can be extended with new chunks while the reader is mid-stream.
final class ChunkedInput implements BitReaderInput {
  ChunkedInput({this.bytesPerCall = 1 << 30});

  final int bytesPerCall;
  final List<Uint8List> _chunks = <Uint8List>[];
  int _index = 0;
  int _chunkOffset = 0;
  bool _closed = false;

  void add(Uint8List bytes) => _chunks.add(bytes);

  void close() => _closed = true;

  @override
  bool get isClosed => _closed;

  @override
  int readInto(Uint8List destination, int offset, int length) {
    if (length <= 0) {
      return 0;
    }
    while (_index < _chunks.length) {
      final chunk = _chunks[_index];
      final available = chunk.length - _chunkOffset;
      if (available <= 0) {
        _index++;
        _chunkOffset = 0;
        continue;
      }
      final limit = length < bytesPerCall ? length : bytesPerCall;
      final count = available < limit ? available : limit;
      destination.setRange(offset, offset + count, chunk, _chunkOffset);
      _chunkOffset += count;
      return count;
    }
    return 0;
  }
}

/// Byte-exact comparison that reports the first differing offset.
void expectBytes(List<int> actual, List<int> expected, String reason) {
  expect(actual.length, expected.length, reason: '$reason: length');
  for (var i = 0; i < expected.length; i++) {
    if (actual[i] != expected[i]) {
      fail(
        '$reason: first difference at byte $i '
        '(${actual[i]} != ${expected[i]})',
      );
    }
  }
}

/// Matches a thrown [BrotliException], optionally with a specific [code].
Matcher throwsBrotli([BrotliErrorCode? code]) => throwsA(
  code == null
      ? isA<BrotliException>()
      : isA<BrotliException>().having((error) => error.code, 'code', code),
);

/// Writes the RFC 7932 stream header for [bits] (10..24), or the large-window
/// encoding when [large] is set.
void writeWindowBits(BitSink sink, int bits, {bool large = false}) {
  if (large) {
    sink.writeBits(1, 1); // not the 16-bit shorthand
    sink.writeBits(0, 3); // n == 0
    sink.writeBits(1, 3); // large-window marker
    sink.writeBits(0, 1); // reserved extension bit
    sink.writeBits(bits, 6);
    return;
  }
  if (bits == 16) {
    sink.writeBits(0, 1);
    return;
  }
  if (bits == 17) {
    sink.writeBits(1, 1);
    sink.writeBits(0, 3);
    sink.writeBits(0, 3);
    return;
  }
  if (bits >= 18 && bits <= 24) {
    sink.writeBits(1, 1);
    sink.writeBits(bits - 17, 3);
    return;
  }
  if (bits >= 10 && bits <= 15) {
    sink.writeBits(1, 1);
    sink.writeBits(0, 3);
    sink.writeBits(bits - 8, 3);
    return;
  }
  throw ArgumentError.value(bits, 'bits', 'not an RFC window-bits value');
}

/// Decoded bytes plus the decoder state (it keeps the last metablock's header
/// fields and the dictionary-reference counters).
typedef CoreRun = ({Uint8List bytes, DecoderState state});

/// Decodes the complete in-memory stream [input] with [BrotliDecoderCore],
/// draining it through [chunkSize]-byte output slices.
CoreRun decodeCore(
  Uint8List input, {
  int chunkSize = 64 * 1024,
  bool allowLargeWindow = false,
  int? maxOutputSize,
  Uint8List? compoundDictionary,
  Uint8List? sharedDictionary,
}) {
  final core = BrotliDecoderCore(
    BitReader.fromBytes(input),
    allowLargeWindow: allowLargeWindow,
    maxOutputSize: maxOutputSize,
    compoundDictionary: compoundDictionary,
    sharedDictionary: sharedDictionary,
  );
  final builder = BytesBuilder(copy: false);
  final buffer = Uint8List(chunkSize);
  var stalled = 0;
  while (true) {
    final status = core.decode(buffer);
    final written = core.bytesWritten;
    expect(written, inInclusiveRange(0, buffer.length));
    if (written > 0) {
      builder.add(buffer.sublist(0, written));
    }
    if (status == BrotliStatus.done) {
      break;
    }
    if (status == BrotliStatus.needMoreInput) {
      fail('a closed in-memory stream must not request input');
    }
    if (written == 0) {
      stalled++;
      if (stalled > 1000) {
        fail('decoder stopped making progress');
      }
    } else {
      stalled = 0;
    }
  }
  return (bytes: builder.takeBytes(), state: core.state);
}

/// Decodes [compressed] with [BrotliDecoderCore] over a [ChunkedInput] that is
/// fed [inputChunk] bytes only when the decoder asks for input, draining
/// through [outputChunk]-byte slices.
CoreRun decodeCoreChunked(
  Uint8List compressed, {
  required int inputChunk,
  required int outputChunk,
  Uint8List? compoundDictionary,
  Uint8List? sharedDictionary,
}) {
  final input = ChunkedInput();
  final core = BrotliDecoderCore(
    BitReader(input),
    compoundDictionary: compoundDictionary,
    sharedDictionary: sharedDictionary,
  );
  final builder = BytesBuilder(copy: false);
  final buffer = Uint8List(outputChunk);
  var offset = 0;
  var calls = 0;
  while (true) {
    final status = core.decode(buffer);
    final written = core.bytesWritten;
    if (written > 0) {
      builder.add(buffer.sublist(0, written));
    }
    if (status == BrotliStatus.done) {
      break;
    }
    if (status == BrotliStatus.needMoreInput) {
      expect(input.isClosed, isFalse, reason: 'input demand after close');
      final end = offset + inputChunk < compressed.length
          ? offset + inputChunk
          : compressed.length;
      input.add(Uint8List.sublistView(compressed, offset, end));
      offset = end;
      if (offset == compressed.length) {
        input.close();
      }
    } else {
      expect(
        written,
        greaterThan(0),
        reason: 'needMoreOutput made no progress',
      );
    }
    calls++;
    if (calls > 1 << 22) {
      fail('decoder made no progress while feeding input');
    }
  }
  expect(core.reader.bytesConsumed, compressed.length);
  return (bytes: builder.takeBytes(), state: core.state);
}

/// Streams [compressed] through a [StreamingDecoder], adding [inputChunk]
/// bytes only when the decoder needs input and decoding into
/// [outputChunk]-sized slices.
Uint8List streamDecode(
  Uint8List compressed, {
  required int inputChunk,
  int outputChunk = 1 << 20,
  int? maxOutputSize,
  bool allowLargeWindow = false,
  Uint8List? compoundDictionary,
  Uint8List? sharedDictionary,
}) {
  final decoder = StreamingDecoder(
    maxOutputSize: maxOutputSize,
    allowLargeWindow: allowLargeWindow,
    compoundDictionary: compoundDictionary,
    sharedDictionary: sharedDictionary,
  );
  final builder = BytesBuilder(copy: false);
  final buffer = Uint8List(outputChunk);
  var offset = 0;
  var closed = false;
  var wantInput = true;
  var calls = 0;
  while (true) {
    if (wantInput) {
      if (offset < compressed.length) {
        final end = offset + inputChunk < compressed.length
            ? offset + inputChunk
            : compressed.length;
        decoder.addInput(Uint8List.sublistView(compressed, offset, end));
        offset = end;
      } else if (!closed) {
        decoder.closeInput();
        closed = true;
      }
      wantInput = false;
    }
    calls++;
    expect(calls, lessThan(1 << 24), reason: 'decoder made no progress');
    final status = decoder.decode(buffer);
    final written = decoder.bytesWritten;
    expect(written, inInclusiveRange(0, buffer.length));
    if (written > 0) {
      builder.add(buffer.sublist(0, written));
    }
    if (status == BrotliStatus.done) {
      break;
    }
    if (status == BrotliStatus.needMoreInput) {
      expect(closed, isFalse, reason: 'input requested after closeInput');
      wantInput = true;
      continue;
    }
    expect(written, greaterThan(0), reason: 'needMoreOutput made no progress');
  }
  expect(decoder.consumedInput, compressed.length);
  return builder.takeBytes();
}

/// Builds a one-metablock stream that emits [insertLength] copies of
/// [literalByte] and then a single dictionary reference to word [wordIndex]
/// with transform [transformIndex].
///
/// The dictionary address is `transformIndex * (1 << sizeBits) + wordIndex`;
/// the transmitted distance is `address + maxDistance + 1 + compoundSize`, so
/// the decoder must reconstruct exactly this address from its own
/// `maxDistance` (and the attached compound dictionary size).
/// [transformedLength] is the length of the word after the transform, which
/// sets the metablock length.
Uint8List buildDictionaryReferenceStream({
  required int insertLength,
  required int copyLength,
  required int sizeBits,
  required int wordIndex,
  required int transformIndex,
  required int transformedLength,
  int compoundSize = 0,
  int windowBits = 10,
  int literalByte = 0x41,
}) {
  final address = transformIndex * (1 << sizeBits) + wordIndex;
  final maxBackward = (1 << windowBits) - 16;
  final maxDistance = insertLength < maxBackward ? insertLength : maxBackward;
  final distance = address + maxDistance + 1 + compoundSize;

  final command = _findCommand(insertLength, copyLength);
  final distanceLimit = distanceAlphabetSize(0, 0, maxDistanceBits);
  final distanceCode = _findDistanceCode(distance, distanceLimit);

  final sink = BitSink();
  writeWindowBits(sink, windowBits);

  // Metablock header (compressed, not last).
  sink.writeBits(0, 1); // ISLAST
  var value = insertLength + transformedLength - 1;
  var nibbles = 4;
  if (value >= 1 << 20) {
    nibbles = 6;
  } else if (value >= 1 << 16) {
    nibbles = 5;
  }
  sink.writeBits(nibbles - 4, 2);
  for (var i = 0; i < nibbles; i++) {
    sink.writeBits(value & 0xF, 4);
    value >>= 4;
  }
  sink.writeBits(0, 1); // ISUNCOMPRESSED

  // One block type per category (decodeVarLenUnsignedByte == 0).
  sink.writeBits(0, 1);
  sink.writeBits(0, 1);
  sink.writeBits(0, 1);
  sink.writeBits(0, 2); // NPOSTFIX
  sink.writeBits(0, 4); // NDIRECT
  sink.writeBits(0, 2); // context mode LSB6

  // Single-tree context maps: decodeVarLenUnsignedByte == 0.
  sink.writeBits(0, 1);
  sink.writeBits(0, 1);

  // Literal tree: one-symbol simple code.
  sink.writeBits(1, 2);
  sink.writeBits(0, 2);
  sink.writeBits(literalByte, 8);

  // Command tree: one-symbol simple code.
  final commandMaxBits = 1 + _log2Floor(numCommandCodes - 1);
  sink.writeBits(1, 2);
  sink.writeBits(0, 2);
  sink.writeBits(command.code, commandMaxBits);

  // Distance tree: one-symbol simple code.
  final distanceMaxBits = 1 + _log2Floor(distanceLimit - 1);
  sink.writeBits(1, 2);
  sink.writeBits(0, 2);
  sink.writeBits(distanceCode.code, distanceMaxBits);

  // Command extras, then (after the implicit inserted literals) the distance
  // extra bits.
  sink.writeBits(insertLength - command.insertOffset, command.insertBits);
  sink.writeBits(copyLength - command.copyOffset, command.copyBits);
  sink.writeBits(distance - distanceCode.offset, distanceCode.extraBits);

  // Final empty metablock.
  sink.writeBits(1, 1);
  sink.writeBits(1, 1);
  return sink.toBytes();
}

int _log2Floor(int x) {
  var result = 0;
  while ((x >> (result + 1)) != 0) {
    result++;
  }
  return result;
}

/// Finds an explicit-distance command whose insert/copy codes can encode
/// [insertLength] / [copyLength] exactly.
({int code, int insertBits, int insertOffset, int copyBits, int copyOffset})
_findCommand(int insertLength, int copyLength) {
  for (var code = 128; code < numCommandCodes; code++) {
    final packed = commandLookup[code * 4];
    final insertBits = packed & 0xFF;
    final copyBits = packed >> 8;
    final insertOffset = commandLookup[code * 4 + 1];
    final copyOffset = commandLookup[code * 4 + 2];
    if (commandLookup[code * 4 + 3] < 0) {
      continue; // implicit distance: cannot be a dictionary reference
    }
    if (insertLength >= insertOffset &&
        insertLength - insertOffset < (1 << insertBits) &&
        copyLength >= copyOffset &&
        copyLength - copyOffset < (1 << copyBits)) {
      return (
        code: code,
        insertBits: insertBits,
        insertOffset: insertOffset,
        copyBits: copyBits,
        copyOffset: copyOffset,
      );
    }
  }
  throw StateError(
    'no explicit-distance command for insert=$insertLength copy=$copyLength',
  );
}

/// RFC 7932 section 4 distance code for [distance] with NPOSTFIX = NDIRECT = 0:
/// code `16 + h` carries `1 + (h >> 1)` extra bits and covers distances
/// `offset .. offset + 2^extraBits - 1`.
({int code, int extraBits, int offset}) _findDistanceCode(
  int distance,
  int distanceLimit,
) {
  for (var code = numDistanceShortCodes; code < distanceLimit; code++) {
    final h = code - numDistanceShortCodes;
    final extraBits = 1 + (h >> 1);
    final offset = ((2 + (h & 1)) << extraBits) - 4 + 1;
    if (distance >= offset && distance - offset < (1 << extraBits)) {
      return (code: code, extraBits: extraBits, offset: offset);
    }
  }
  throw StateError('no distance code for distance $distance');
}
