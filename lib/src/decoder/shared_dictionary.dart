/// Serialized shared-dictionary support
/// (`draft-vandevenne-shared-brotli-format`, implemented by
/// `brotli --dictionary` shared dictionaries).
///
/// Port of `brotli-decompressor 6.0.1` `src/shared_dictionary.rs`, which is
/// itself a port of `c/common/shared_dictionary.c`. The container carries:
///
/// * magic `0x91 0x00`;
/// * an optional LZ77 prefix chunk, which becomes a compound dictionary chunk
///   (see `_applyCompoundDictionaryReference`);
/// * zero or more word lists (per-length `size_bits` + concatenated words);
/// * zero or more transform lists (prefix/suffix stringlets, triplets
///   `[prefix_id, type, suffix_id]`, optional SHIFT parameters, identity
///   cutoff);
/// * when at least one custom list exists, a dictionary table
///   (`words_index` / `transforms_index`) and an optional 64-entry
///   literal-context map.
///
/// Word/transform data is referenced by offset into the original blob, so
/// [SharedDictionary.blob] must stay alive (and unmodified) for the lifetime of
/// the decoder; the option API takes the caller's `Uint8List` by reference.
///
/// Triplets use the C implementation's field order `PREFIX_ID, TYPE,
/// SUFFIX_ID`, not the draft's `PREFIX_ID, SUFFIX_ID, TYPE`; this is what the
/// reference encoder actually emits.
///
/// Format problems raise [BrotliException] with
/// [BrotliErrorCode.invalidDictionaryWord].
library;

import 'dart:typed_data';

import '../common/dictionary.dart' as builtin_dictionary;
import '../common/dictionary_data.dart'
    show kDictionaryData, kDictionarySizeBitsByLength;
import '../common/errors.dart';
import '../common/transforms.dart' as rfc_transforms;

/// Oldest supported dictionary word length (same as RFC 7932).
const int sharedMinDictionaryWordLength = 4;

/// Longest custom dictionary word length.
const int sharedMaxDictionaryWordLength = 31;

/// Number of literal contexts addressed by the context map.
const int sharedNumDictionaryContexts = 64;

/// Maximum number of word lists, transform lists and dictionaries.
const int sharedMaxDictionaries = 64;

/// Maximum `size_bits` accepted for a custom word length.
const int _maxSizeBits = 15;

const int _transformOmitLast9 = 9;
const int _transformUppercaseFirst = 10;
const int _transformUppercaseAll = 11;
const int _transformOmitFirst1 = 12;
const int _transformOmitFirst9 = 20;
const int _transformShiftFirst = 21;
const int _transformShiftAll = 22;
const int _numTransformTypes = 23;

Never _bad(String message) {
  throw BrotliException(
    BrotliErrorCode.invalidDictionaryWord,
    'invalid serialized shared dictionary: $message',
  );
}

/// A parsed word list (custom words).
///
/// [sizeBits] and [offsets] are indexed by word length `0..31`; a zero
/// `size_bits` means the length is not encodable by this list.
final class SharedWordList implements SharedDictionaryWords {
  SharedWordList._(this.blob, this.dataOffset, this.sizeBits, this.offsets);

  /// Serialized dictionary bytes the views point into.
  final Uint8List blob;

  /// Offset of the concatenated word bytes inside [blob].
  final int dataOffset;

  /// Number of `size_bits` of each word length (`0..31`).
  final Uint8List sizeBits;

  /// Byte offset of the first word of each length inside the word data.
  final Uint32List offsets;

  @override
  bool get isBuiltin => false;

  @override
  int sizeBitsFor(int length) {
    if (length < 0 || length > sharedMaxDictionaryWordLength) {
      return 0;
    }
    return sizeBits[length];
  }

  @override
  Uint8List wordBytes(int length, int wordIndex) {
    final offset = dataOffset + offsets[length] + wordIndex * length;
    return Uint8List.sublistView(blob, offset, offset + length);
  }
}

/// Word lookup source: either a custom [SharedWordList] or the built-in
/// RFC 7932 dictionary.
abstract interface class SharedDictionaryWords {
  /// Whether this is the built-in RFC static dictionary.
  bool get isBuiltin;

  /// `size_bits` for [length]; `0` means the length is not encodable.
  int sizeBitsFor(int length);

  /// Zero-copy view of the requested word.
  Uint8List wordBytes(int length, int wordIndex);
}

/// The built-in RFC 7932 dictionary as a [SharedDictionaryWords] source.
final class _BuiltinWords implements SharedDictionaryWords {
  const _BuiltinWords();

  @override
  bool get isBuiltin => true;

  @override
  int sizeBitsFor(int length) {
    if (length < sharedMinDictionaryWordLength || length > 24) {
      return 0;
    }
    return kDictionarySizeBitsByLength[length];
  }

  @override
  Uint8List wordBytes(int length, int wordIndex) {
    final offset = builtin_dictionary.dictionaryWordOffset(length, wordIndex);
    return Uint8List.sublistView(kDictionaryData, offset, offset + length);
  }
}

const SharedDictionaryWords _builtinWords = _BuiltinWords();

/// Built-in RFC transform list as a [SharedDictionaryTransforms] source.
final class _BuiltinTransforms implements SharedDictionaryTransforms {
  const _BuiltinTransforms();

  @override
  bool get isBuiltin => true;

  @override
  int get numTransforms => 121;

  @override
  int get cutoffIdentity => 0;

  @override
  int apply(
    Uint8List dst,
    int dstOffset,
    Uint8List word,
    int wordLength,
    int transformIndex,
  ) {
    return rfc_transforms.transformDictionaryWord(
      dst,
      dstOffset,
      word,
      0,
      wordLength,
      transformIndex,
    );
  }
}

const SharedDictionaryTransforms _builtinTransforms = _BuiltinTransforms();

/// A parsed custom transform list.
final class SharedTransformList implements SharedDictionaryTransforms {
  SharedTransformList._(
    this.blob,
    this.transformsOffset,
    this.paramsOffset,
    this.numTransforms,
    this.cutoffIdentity,
    this._stringlets,
  );

  /// Serialized dictionary bytes the views point into.
  final Uint8List blob;

  /// Offset of the `numTransforms * 3` triplet bytes.
  final int transformsOffset;

  /// Offset of the two-byte SHIFT parameters, or `-1` when absent.
  final int paramsOffset;

  @override
  final int numTransforms;

  /// Index of the first `["", IDENTITY, ""]` transform, or `-1`.
  @override
  final int cutoffIdentity;

  final List<Uint8List> _stringlets;

  @override
  bool get isBuiltin => false;

  /// Zero-copy view of stringlet [id].
  Uint8List stringlet(int id) => _stringlets[id];

  /// Transform type byte of transform [index].
  int transformType(int index) => blob[transformsOffset + index * 3 + 1];

  /// SHIFT parameter of transform [index] (`0` when the list has none).
  int param(int index) {
    if (paramsOffset < 0) {
      return 0;
    }
    final offset = paramsOffset + index * 2;
    return blob[offset] | (blob[offset + 1] << 8);
  }

  @override
  int apply(
    Uint8List dst,
    int dstOffset,
    Uint8List word,
    int wordLength,
    int transformIndex,
  ) {
    final base = transformsOffset + transformIndex * 3;
    final prefix = _stringlets[blob[base]];
    final type = blob[base + 1];
    final suffix = _stringlets[blob[base + 2]];

    var out = dstOffset;
    for (final byte in prefix) {
      dst[out++] = byte;
    }

    var srcOffset = 0;
    var len = wordLength;
    if (type <= _transformOmitLast9) {
      len -= type;
    } else if (type >= _transformOmitFirst1 && type <= _transformOmitFirst9) {
      final skip = type - (_transformOmitFirst1 - 1);
      if (skip > len) {
        len = 0;
      } else {
        srcOffset = skip;
        len -= skip;
      }
    }
    final copyLen = len > 0 ? len : 0;
    for (var i = 0; i < copyLen; i++) {
      dst[out++] = word[srcOffset + i];
    }
    if (copyLen > 0) {
      final start = out - copyLen;
      if (type == _transformUppercaseFirst) {
        _toUpperCase(dst, start);
      } else if (type == _transformUppercaseAll) {
        var offset = 0;
        var remaining = copyLen;
        while (remaining > 0) {
          final step = _toUpperCase(dst, start + offset);
          offset += step;
          remaining -= step;
        }
      } else if (type == _transformShiftFirst) {
        _shiftScalar(dst, start, copyLen, param(transformIndex));
      } else if (type == _transformShiftAll) {
        final parameter = param(transformIndex);
        var offset = 0;
        var remaining = copyLen;
        while (remaining > 0) {
          final step = _shiftScalar(dst, start + offset, remaining, parameter);
          offset += step;
          remaining -= step;
        }
      }
    }
    for (final byte in suffix) {
      dst[out++] = byte;
    }
    return out - dstOffset;
  }
}

/// Transform lookup source: either a custom [SharedTransformList] or the
/// built-in RFC 7932 transforms.
abstract interface class SharedDictionaryTransforms {
  /// Whether this is the built-in RFC transform list.
  bool get isBuiltin;

  /// Number of transforms in the list.
  int get numTransforms;

  /// Index of the identity transform, or `-1` when absent.
  int get cutoffIdentity;

  /// Applies transform [transformIndex] to [word], writing `<= 542` bytes at
  /// [dstOffset] and returning the number of bytes written.
  int apply(
    Uint8List dst,
    int dstOffset,
    Uint8List word,
    int wordLength,
    int transformIndex,
  );
}

/// One resolved dictionary reference.
final class SharedDictionaryLookup {
  const SharedDictionaryLookup(
    this.words,
    this.transforms,
    this.wordIndex,
    this.transformIndex,
  );

  final SharedDictionaryWords words;
  final SharedDictionaryTransforms transforms;
  final int wordIndex;
  final int transformIndex;
}

/// A parsed serialized shared dictionary.
final class SharedDictionary {
  SharedDictionary._({
    required this.blob,
    required this.prefixOffset,
    required this.prefixLength,
    required this.numWordLists,
    required this.numTransformLists,
    required this.numDictionaries,
    required this.contextBased,
    required this.contextMap,
    required this.wordsIndex,
    required this.transformsIndex,
    required this.wordLists,
    required this.transformLists,
  });

  /// Serialized dictionary bytes; word/transform views point into this buffer.
  final Uint8List blob;

  /// Offset of the embedded LZ77 prefix in [blob], or `-1` when absent.
  final int prefixOffset;

  /// Length of the embedded LZ77 prefix (0 when absent).
  final int prefixLength;

  /// Number of custom word lists (`0..64`).
  final int numWordLists;

  /// Number of custom transform lists (`0..64`).
  final int numTransformLists;

  /// Number of dictionaries (`1..64`).
  final int numDictionaries;

  /// Whether [contextMap] selects the dictionary per literal context.
  final bool contextBased;

  /// 64-entry context -> dictionary map (identity when [contextBased] is false).
  final Uint8List contextMap;

  /// Per dictionary: word list index, or [numWordLists] for the built-in list.
  final Uint8List wordsIndex;

  /// Per dictionary: transform list index, or [numTransformLists] for built-in.
  final Uint8List transformsIndex;

  final List<SharedWordList> wordLists;
  final List<SharedTransformList> transformLists;

  /// Whether custom word/transform lists replace the built-in dictionary.
  bool get isCustom => numWordLists != 0 || numTransformLists != 0;

  /// Whether the container carries an LZ77 prefix chunk.
  bool get hasPrefix => prefixLength != 0;

  /// Zero-copy view of the embedded LZ77 prefix.
  Uint8List get prefix =>
      Uint8List.sublistView(blob, prefixOffset, prefixOffset + prefixLength);

  /// Word source for dictionary [dictId] (custom or built-in).
  SharedDictionaryWords wordsOf(int dictId) {
    final index = wordsIndex[dictId];
    if (index >= numWordLists) {
      return _builtinWords;
    }
    return wordLists[index];
  }

  /// Transform source for dictionary [dictId] (custom or built-in).
  SharedDictionaryTransforms transformsOf(int dictId) {
    final index = transformsIndex[dictId];
    if (index >= numTransformLists) {
      return _builtinTransforms;
    }
    return transformLists[index];
  }

  /// Resolves [address] in the flat dictionary address space to the word and
  /// transform that own it, for a word of [length] bytes.
  ///
  /// The address space is partitioned per dictionary: each owns
  /// `((1 << shift) & ~1) * numTransforms` addresses, searched with [dictId]
  /// first and then the remaining dictionaries in index order. Mirrors the
  /// Rust/C lookup (including the multi-dictionary rescan).
  SharedDictionaryLookup lookup(int dictId, int length, int address) {
    if (address < 0) {
      throw BrotliException(
        BrotliErrorCode.invalidDistance,
        'negative shared-dictionary address $address',
      );
    }
    var remaining = address;
    for (var k = 0; k < numDictionaries; k++) {
      // dictId first, then the other dictionaries in index order.
      final candidate = k == 0 ? dictId : (k <= dictId ? k - 1 : k);
      final words = wordsOf(candidate);
      final shift = words.sizeBitsFor(length);
      final transforms = transformsOf(candidate);
      final count = _even(1 << shift) * transforms.numTransforms;
      if (remaining < count) {
        final mask = (1 << shift) - 1;
        return SharedDictionaryLookup(
          words,
          transforms,
          remaining & mask,
          remaining >> shift,
        );
      }
      remaining -= count;
    }
    if (wordsOf(dictId).sizeBitsFor(length) == 0) {
      throw BrotliException(
        BrotliErrorCode.invalidDictionaryWord,
        'shared dictionary has no words of length $length',
      );
    }
    throw BrotliException(
      BrotliErrorCode.invalidTransform,
      'shared-dictionary address $address is out of range for '
      'length $length',
    );
  }

  /// Parses a serialized shared dictionary.
  ///
  /// Throws [BrotliException] ([BrotliErrorCode.invalidDictionaryWord]) for
  /// malformed input. Trailing bytes after the container are ignored, matching
  /// the reference parser.
  static SharedDictionary parse(Uint8List bytes) {
    if (bytes.length < 2 || bytes[0] != 0x91 || bytes[1] != 0x00) {
      _bad('bad magic (expected 0x91 0x00)');
    }
    final reader = _Reader(bytes, 2);
    final chunkSize = reader.readVarint32();
    var prefixOffset = -1;
    var prefixLength = 0;
    if (chunkSize != 0) {
      if (chunkSize > 1073741823) {
        _bad('LZ77 prefix chunk is too large ($chunkSize bytes)');
      }
      if (reader.pos + chunkSize > bytes.length) {
        _bad('LZ77 prefix chunk overruns the dictionary data');
      }
      prefixOffset = reader.pos;
      prefixLength = chunkSize;
      reader.pos += chunkSize;
    }

    final numWordLists = reader.readU8();
    if (numWordLists > sharedMaxDictionaries) {
      _bad('word list count $numWordLists exceeds $sharedMaxDictionaries');
    }
    final wordLists = <SharedWordList>[];
    for (var i = 0; i < numWordLists; i++) {
      wordLists.add(_parseWordList(bytes, reader));
    }

    final numTransformLists = reader.readU8();
    if (numTransformLists > sharedMaxDictionaries) {
      _bad(
        'transform list count $numTransformLists exceeds '
        '$sharedMaxDictionaries',
      );
    }
    final transformLists = <SharedTransformList>[];
    for (var i = 0; i < numTransformLists; i++) {
      transformLists.add(_parseTransformList(bytes, reader));
    }

    final wordsIndex = Uint8List(sharedNumDictionaryContexts);
    final transformsIndex = Uint8List(sharedNumDictionaryContexts);
    final contextMap = Uint8List(sharedNumDictionaryContexts);
    var numDictionaries = 1;
    var contextBased = false;
    if (numWordLists != 0 || numTransformLists != 0) {
      numDictionaries = reader.readU8();
      if (numDictionaries == 0 || numDictionaries > sharedMaxDictionaries) {
        _bad('dictionary count $numDictionaries is outside 1..64');
      }
      for (var i = 0; i < numDictionaries; i++) {
        final words = reader.readU8();
        if (words > numWordLists) {
          _bad('dictionary $i words index $words > $numWordLists');
        }
        final transforms = reader.readU8();
        if (transforms > numTransformLists) {
          _bad(
            'dictionary $i transforms index $transforms > '
            '$numTransformLists',
          );
        }
        wordsIndex[i] = words;
        transformsIndex[i] = transforms;
      }
      contextBased = reader.readBool();
      if (contextBased) {
        for (var i = 0; i < sharedNumDictionaryContexts; i++) {
          final value = reader.readU8();
          if (value >= numDictionaries) {
            _bad('context map entry $i selects dictionary $value');
          }
          contextMap[i] = value;
        }
      }
    }

    return SharedDictionary._(
      blob: bytes,
      prefixOffset: prefixOffset,
      prefixLength: prefixLength,
      numWordLists: numWordLists,
      numTransformLists: numTransformLists,
      numDictionaries: numDictionaries,
      contextBased: contextBased,
      contextMap: contextMap,
      wordsIndex: wordsIndex,
      transformsIndex: transformsIndex,
      wordLists: wordLists,
      transformLists: transformLists,
    );
  }
}

/// Returns `x` with its least-significant bit cleared (`x & ~1`, without `~`).
int _even(int x) => x & 0xFFFFFFFE;

SharedWordList _parseWordList(Uint8List bytes, _Reader reader) {
  const numEncodedLengths =
      sharedMaxDictionaryWordLength - sharedMinDictionaryWordLength + 1;
  if (reader.pos + numEncodedLengths > bytes.length) {
    _bad('word list is truncated');
  }
  final sizeBits = Uint8List(sharedMaxDictionaryWordLength + 1);
  for (var i = 0; i < numEncodedLengths; i++) {
    final bits = bytes[reader.pos + i];
    if (bits > _maxSizeBits) {
      _bad(
        'size_bits $bits for length ${sharedMinDictionaryWordLength + i} '
        'exceeds $_maxSizeBits',
      );
    }
    sizeBits[sharedMinDictionaryWordLength + i] = bits;
  }
  reader.pos += numEncodedLengths;

  final dataOffset = reader.pos;
  final offsets = Uint32List(sharedMaxDictionaryWordLength + 1);
  var total = 0;
  for (var length = 0; length <= sharedMaxDictionaryWordLength; length++) {
    offsets[length] = total;
    final bits = sizeBits[length];
    if (bits != 0) {
      total += length << bits;
    }
  }
  if (dataOffset + total > bytes.length) {
    _bad('word list data overruns the dictionary data');
  }
  reader.pos += total;
  return SharedWordList._(bytes, dataOffset, sizeBits, offsets);
}

SharedTransformList _parseTransformList(Uint8List bytes, _Reader reader) {
  final dataLength = reader.readU16();
  if (dataLength < 1) {
    _bad('transform prefix/suffix table is empty');
  }
  if (reader.pos + dataLength >= bytes.length) {
    _bad('transform prefix/suffix table overruns the dictionary data');
  }
  final tableStart = reader.pos;
  final stringlets = <Uint8List>[];
  var offset = 0;
  while (true) {
    final length = bytes[tableStart + offset];
    final start = tableStart + offset + 1;
    if (start + length > bytes.length) {
      _bad('transform stringlet overruns the dictionary data');
    }
    stringlets.add(Uint8List.sublistView(bytes, start, start + length));
    offset += 1;
    if (length == 0) {
      if (offset == dataLength) {
        break;
      }
      _bad('transform stringlet table has trailing bytes');
    }
    if (stringlets.length > 255) {
      _bad('more than 255 transform stringlets');
    }
    offset += length;
    if (offset >= dataLength) {
      _bad('transform stringlet overruns the stringlet table');
    }
  }
  reader.pos += dataLength;

  final numTransforms = reader.readU8();
  final transformsOffset = reader.pos;
  if (reader.pos + numTransforms * 3 > bytes.length) {
    _bad('transform triplets overrun the dictionary data');
  }
  reader.pos += numTransforms * 3;

  var hasParams = false;
  for (var i = 0; i < numTransforms; i++) {
    final base = transformsOffset + i * 3;
    final prefix = bytes[base];
    final type = bytes[base + 1];
    final suffix = bytes[base + 2];
    if (prefix >= stringlets.length) {
      _bad('transform $i prefix id $prefix is out of range');
    }
    if (suffix >= stringlets.length) {
      _bad('transform $i suffix id $suffix is out of range');
    }
    if (type >= _numTransformTypes) {
      _bad('transform $i type $type is out of range');
    }
    if (type == _transformShiftFirst || type == _transformShiftAll) {
      hasParams = true;
    }
  }

  final paramsOffset = reader.pos;
  if (hasParams) {
    if (reader.pos + numTransforms * 2 > bytes.length) {
      _bad('transform parameters overrun the dictionary data');
    }
    reader.pos += numTransforms * 2;
    for (var i = 0; i < numTransforms; i++) {
      final base = transformsOffset + i * 3;
      final type = bytes[base + 1];
      if (type != _transformShiftFirst && type != _transformShiftAll) {
        if (bytes[paramsOffset + i * 2] != 0 ||
            bytes[paramsOffset + i * 2 + 1] != 0) {
          _bad('non-SHIFT transform $i has a non-zero parameter');
        }
      }
    }
  }

  var cutoff = -1;
  for (var i = 0; i < numTransforms; i++) {
    final base = transformsOffset + i * 3;
    if (bytes[base + 1] != 0) {
      continue;
    }
    final prefix = stringlets[bytes[base]];
    final suffix = stringlets[bytes[base + 2]];
    if (prefix.isEmpty && suffix.isEmpty) {
      cutoff = i;
      break;
    }
  }

  return SharedTransformList._(
    bytes,
    transformsOffset,
    hasParams ? paramsOffset : -1,
    numTransforms,
    cutoff,
    stringlets,
  );
}

/// Byte reader with the exact bounds behaviour of the Rust/C parser.
final class _Reader {
  _Reader(this._data, this.pos);

  final Uint8List _data;
  int pos;

  int readU8() {
    if (pos >= _data.length) {
      _bad('unexpected end of data');
    }
    return _data[pos++];
  }

  bool readBool() {
    final value = readU8();
    if (value > 1) {
      _bad('boolean byte $value is not 0 or 1');
    }
    return value == 1;
  }

  int readU16() {
    if (pos + 2 > _data.length) {
      _bad('unexpected end of data');
    }
    final value = _data[pos] | (_data[pos + 1] << 8);
    pos += 2;
    return value;
  }

  int readVarint32() {
    var result = 0;
    var num = 0;
    while (true) {
      final byte = readU8();
      if (num == 4 && byte > 15) {
        _bad('varint32 is too large');
      }
      result |= (byte & 127) << (num * 7);
      if (byte < 128) {
        return result;
      }
      num++;
    }
  }
}

/// UTF-8-aware uppercase of the first scalar at [offset]; returns its length in
/// bytes (port of `ToUpperCase` in `c/common/transform.c`).
int _toUpperCase(Uint8List dst, int offset) {
  final c0 = dst[offset] & 0xFF;
  if (c0 < 0xC0) {
    if (c0 >= 97 && c0 <= 122) {
      dst[offset] = dst[offset] ^ 32;
    }
    return 1;
  }
  if (c0 < 0xE0) {
    dst[offset + 1] = dst[offset + 1] ^ 32;
    return 2;
  }
  dst[offset + 2] = dst[offset + 2] ^ 5;
  return 3;
}

/// UTF-8-aware scalar shift (port of `Shift` in `c/common/transform.c`).
///
/// Returns the number of bytes of the shifted scalar (1..4).
int _shiftScalar(Uint8List dst, int offset, int length, int parameter) {
  // Limited sign extension: scalar < (1 << 24).
  var scalar = (parameter & 0x7FFF) + (0x1000000 - (parameter & 0x8000));
  final c0 = dst[offset] & 0xFF;
  if (c0 < 0x80) {
    scalar += c0;
    dst[offset] = scalar & 0x7F;
    return 1;
  }
  if (c0 < 0xC0) {
    // Continuation byte: leave it alone.
    return 1;
  }
  if (c0 < 0xE0) {
    if (length < 2) {
      return 1;
    }
    final c1 = dst[offset + 1];
    scalar += (c1 & 0x3F) | ((c0 & 0x1F) << 6);
    dst[offset] = 0xC0 | ((scalar >> 6) & 0x1F);
    dst[offset + 1] = (c1 & 0xC0) | (scalar & 0x3F);
    return 2;
  }
  if (c0 < 0xF0) {
    if (length < 3) {
      return length;
    }
    final c1 = dst[offset + 1];
    final c2 = dst[offset + 2];
    scalar += (c2 & 0x3F) | ((c1 & 0x3F) << 6) | ((c0 & 0x0F) << 12);
    dst[offset] = 0xE0 | ((scalar >> 12) & 0x0F);
    dst[offset + 1] = (c1 & 0xC0) | ((scalar >> 6) & 0x3F);
    dst[offset + 2] = (c2 & 0xC0) | (scalar & 0x3F);
    return 3;
  }
  if (c0 < 0xF8) {
    if (length < 4) {
      return length;
    }
    final c1 = dst[offset + 1];
    final c2 = dst[offset + 2];
    final c3 = dst[offset + 3];
    scalar +=
        (c3 & 0x3F) |
        ((c2 & 0x3F) << 6) |
        ((c1 & 0x3F) << 12) |
        ((c0 & 0x07) << 18);
    dst[offset] = 0xF0 | ((scalar >> 18) & 0x07);
    dst[offset + 1] = (c1 & 0xC0) | ((scalar >> 12) & 0x3F);
    dst[offset + 2] = (c2 & 0xC0) | ((scalar >> 6) & 0x3F);
    dst[offset + 3] = (c3 & 0xC0) | (scalar & 0x3F);
    return 4;
  }
  return 1;
}

/// Merges an explicit compound dictionary with the shared dictionary's
/// embedded LZ77 prefix.
///
/// Attach order mirrors the reference API: recently attached chunks are
/// closest in backward-distance space, so the serialized prefix (attached
/// last) goes after the caller's raw compound dictionary. Views point into the
/// source buffers when only one of the two is present.
Uint8List combineCompoundDictionary(
  Uint8List? compoundDictionary,
  SharedDictionary? sharedDictionary,
) {
  final base = compoundDictionary ?? Uint8List(0);
  final hasPrefix = sharedDictionary != null && sharedDictionary.hasPrefix;
  if (!hasPrefix) {
    return base;
  }
  final prefix = sharedDictionary.prefix;
  if (base.isEmpty) {
    return prefix;
  }
  final combined = Uint8List(base.length + prefix.length);
  combined.setRange(0, base.length, base);
  combined.setRange(base.length, combined.length, prefix);
  return combined;
}
