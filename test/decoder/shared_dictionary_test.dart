/// Serialized shared dictionaries: parser, custom word/transform lists,
/// context map, optional LZ77 prefix, and stream-level integration.
///
/// The container fixtures mirror the Rust `serialized_with_custom_lists()`
/// test in `brotli-decompressor 6.0.1` `src/shared_dictionary.rs`. The
/// stream-level tests hand-build compressed metablocks with the synthetic bit
/// packer (no reference stream exists: no common encoder emits custom word or
/// transform lists).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:brotli_fast/src/common/context_lookup.dart';
import 'package:brotli_fast/src/decoder/decoder.dart';
import 'package:brotli_fast/src/decoder/decoder_state.dart'
    show maxTransformedWordLength;
import 'package:brotli_fast/src/decoder/shared_dictionary.dart';
import 'package:test/test.dart';

import 'decoder_helpers.dart';

// ---------------------------------------------------------------------------
// Serialized dictionary builders.
// ---------------------------------------------------------------------------

Uint8List _wordListBytes(int length, int sizeBits, List<int> words) {
  final expected = sizeBits == 0 ? 0 : length << sizeBits;
  if (words.length != expected) {
    throw ArgumentError('expected $expected word bytes, got ${words.length}');
  }
  final sizeBitsArray = List<int>.filled(28, 0);
  sizeBitsArray[length - sharedMinDictionaryWordLength] = sizeBits;
  return Uint8List.fromList(<int>[...sizeBitsArray, ...words]);
}

Uint8List _transformListBytes({
  required List<List<int>> stringlets,
  required List<List<int>> triplets,
  List<int>? params,
}) {
  final table = <int>[];
  for (final stringlet in stringlets) {
    if (stringlet.length > 255) {
      throw ArgumentError('stringlet too long');
    }
    table.add(stringlet.length);
    table.addAll(stringlet);
  }
  final out = <int>[];
  out.add(table.length & 0xFF);
  out.add((table.length >> 8) & 0xFF);
  out.addAll(table);
  out.add(triplets.length);
  for (final triplet in triplets) {
    out.addAll(triplet);
  }
  if (params != null) {
    for (final param in params) {
      out.add(param & 0xFF);
      out.add((param >> 8) & 0xFF);
    }
  }
  return Uint8List.fromList(out);
}

/// Stringlets `["up", "ing", ""]` and the 7 transforms from the Rust test.
Uint8List _defaultTransformListBytes() {
  return _transformListBytes(
    stringlets: <List<int>>['up'.codeUnits, 'ing'.codeUnits, <int>[]],
    triplets: <List<int>>[
      <int>[2, 0, 2], // identity
      <int>[2, 11, 2], // uppercase all
      <int>[0, 0, 1], // prefix "up", suffix "ing"
      <int>[2, 21, 2], // shift first, param 3
      <int>[2, 22, 2], // shift all, param 3
      <int>[2, 2, 2], // omit last 2
      <int>[2, 13, 2], // omit first 2
    ],
    params: <int>[0, 0, 0, 3, 3, 0, 0],
  );
}

void _writeVarint32(List<int> out, int value) {
  var remaining = value;
  while (remaining >= 128) {
    out.add((remaining & 127) | 128);
    remaining >>= 7;
  }
  out.add(remaining);
}

Uint8List _serializedDictionary({
  Uint8List? prefix,
  List<Uint8List> wordLists = const <Uint8List>[],
  List<Uint8List> transformLists = const <Uint8List>[],
  int numDictionaries = 1,
  List<int>? wordsIndex,
  List<int>? transformsIndex,
  bool contextBased = false,
  List<int>? contextMap,
}) {
  final prefixBytes = prefix ?? Uint8List(0);
  final out = <int>[0x91, 0x00];
  _writeVarint32(out, prefixBytes.length);
  out.addAll(prefixBytes);
  out.add(wordLists.length);
  for (final list in wordLists) {
    out.addAll(list);
  }
  out.add(transformLists.length);
  for (final list in transformLists) {
    out.addAll(list);
  }
  if (wordLists.isNotEmpty || transformLists.isNotEmpty) {
    out.add(numDictionaries);
    for (var i = 0; i < numDictionaries; i++) {
      out.add(wordsIndex?[i] ?? 0);
      out.add(transformsIndex?[i] ?? 0);
    }
    out.add(contextBased ? 1 : 0);
    if (contextBased) {
      final map = contextMap ?? List<int>.filled(64, 0);
      if (map.length != 64) {
        throw ArgumentError('context map must have 64 entries');
      }
      out.addAll(map);
    }
  }
  return Uint8List.fromList(out);
}

/// The Rust `serialized_with_custom_lists()` fixture.
Uint8List _customListFixture() {
  return _serializedDictionary(
    wordLists: <Uint8List>[_wordListBytes(4, 1, 'frobquxx'.codeUnits)],
    transformLists: <Uint8List>[_defaultTransformListBytes()],
    wordsIndex: <int>[0],
    transformsIndex: <int>[0],
  );
}

Uint8List _fixtureFile(String name) =>
    File('test/decoder/compound_vectors/$name').readAsBytesSync();

// ---------------------------------------------------------------------------
// Assertions and helpers.
// ---------------------------------------------------------------------------

Uint8List _applyTransform(
  SharedTransformList transforms,
  List<int> word,
  int transformIndex,
) {
  final out = Uint8List(maxTransformedWordLength);
  final length = transforms.apply(
    out,
    0,
    Uint8List.fromList(word),
    word.length,
    transformIndex,
  );
  return Uint8List.sublistView(out, 0, length);
}

/// One custom-dictionary reference (4-byte word list with 2 words) after
/// [insertLength] literals `'A'`.
Uint8List _customStream({
  required int insertLength,
  required int wordIndex,
  required int transformIndex,
  required int transformedLength,
  int compoundSize = 0,
}) => buildDictionaryReferenceStream(
  insertLength: insertLength,
  copyLength: 4,
  sizeBits: 1,
  wordIndex: wordIndex,
  transformIndex: transformIndex,
  transformedLength: transformedLength,
  compoundSize: compoundSize,
);

Uint8List _decodeShared(Uint8List stream, Uint8List shared) =>
    brotliDecode(stream, sharedDictionary: shared);

void main() {
  group('parse: Rust serialized_with_custom_lists fixture', () {
    late SharedDictionary shared;

    setUpAll(() {
      shared = SharedDictionary.parse(_customListFixture());
    });

    test('container metadata', () {
      expect(shared.isCustom, isTrue);
      expect(shared.numWordLists, 1);
      expect(shared.numTransformLists, 1);
      expect(shared.numDictionaries, 1);
      expect(shared.contextBased, isFalse);
      expect(shared.hasPrefix, isFalse);
    });

    test('word list carries frob/quxx', () {
      final words = shared.wordsOf(0);
      expect(words.isBuiltin, isFalse);
      expect(words.sizeBitsFor(4), 1);
      expect(words.sizeBitsFor(8), 0);
      expect(words.wordBytes(4, 0), orderedEquals('frob'.codeUnits));
      expect(words.wordBytes(4, 1), orderedEquals('quxx'.codeUnits));
    });

    test('transform list metadata', () {
      final transforms = shared.transformsOf(0);
      expect(transforms.isBuiltin, isFalse);
      expect(transforms.numTransforms, 7);
      expect(transforms.cutoffIdentity, 0);
      final list = shared.transformLists[0];
      expect(list.stringlet(0), orderedEquals('up'.codeUnits));
      expect(list.stringlet(1), orderedEquals('ing'.codeUnits));
      expect(list.stringlet(2), isEmpty);
      expect(list.param(3), 3);
      expect(list.param(4), 3);
    });

    test('transforms apply (identity/uppercase/prefix/shift/omit)', () {
      void check(List<int> word, int transform, String expected) {
        expectBytes(
          _applyTransform(shared.transformLists[0], word, transform),
          expected.codeUnits,
          'transform $transform on ${String.fromCharCodes(word)}',
        );
      }

      check('frob'.codeUnits, 0, 'frob');
      check('frob'.codeUnits, 1, 'FROB');
      check('frob'.codeUnits, 2, 'upfrobing');
      check('frob'.codeUnits, 3, 'irob');
      check('frob'.codeUnits, 4, 'iure');
      check('frob'.codeUnits, 5, 'fr');
      check('frob'.codeUnits, 6, 'ob');
    });

    test('shift-all preserves UTF-8 scalar boundaries', () {
      // U+00E9 (C3 A9) shifted by +3 is U+00EC (C3 AC).
      final out = _applyTransform(shared.transformLists[0], <int>[
        0xC3,
        0xA9,
        0x61,
        0x62,
      ], 4);
      expectBytes(out, <int>[0xC3, 0xAC, 0x64, 0x65], 'multibyte shift');
    });

    test('lookup maps addresses to words and transforms', () {
      final first = shared.lookup(0, 4, 0);
      expect(first.wordIndex, 0);
      expect(first.transformIndex, 0);
      expect(
        first.words.wordBytes(4, first.wordIndex),
        orderedEquals('frob'.codeUnits),
      );

      final second = shared.lookup(0, 4, 1);
      expect(second.wordIndex, 1);
      expect(second.transformIndex, 0);

      final third = shared.lookup(0, 4, 2);
      expect(third.wordIndex, 0);
      expect(third.transformIndex, 1);

      final last = shared.lookup(0, 4, 13);
      expect(last.wordIndex, 1);
      expect(last.transformIndex, 6);

      expect(() => shared.lookup(0, 4, 14), throwsBrotli());
      expect(() => shared.lookup(0, 5, 0), throwsBrotli());
    });
  });

  group('parse: prefix and empty containers', () {
    test('prefix-only container exposes the LZ77 prefix', () {
      final blob = Uint8List.fromList(<int>[
        0x91,
        0x00,
        4,
        ...'wxyz'.codeUnits,
        0, // NUM_WORD_LISTS
        0, // NUM_TRANSFORM_LISTS
      ]);
      final shared = SharedDictionary.parse(blob);
      expect(shared.hasPrefix, isTrue);
      expect(shared.isCustom, isFalse);
      expect(shared.prefix, orderedEquals('wxyz'.codeUnits));
      expect(shared.numDictionaries, 1);
    });

    test('empty container is a no-op (built-in dictionary)', () {
      final shared = SharedDictionary.parse(
        Uint8List.fromList(<int>[0x91, 0x00, 0, 0, 0]),
      );
      expect(shared.hasPrefix, isFalse);
      expect(shared.isCustom, isFalse);
      expect(shared.wordsOf(0).isBuiltin, isTrue);
      expect(shared.transformsOf(0).isBuiltin, isTrue);
    });

    test('multi-byte varint prefix length', () {
      final prefix = Uint8List(200);
      for (var i = 0; i < prefix.length; i++) {
        prefix[i] = i & 0xFF;
      }
      final shared = SharedDictionary.parse(
        _serializedDictionary(prefix: prefix),
      );
      expect(shared.prefixLength, 200);
      expect(shared.prefix, orderedEquals(prefix));
    });
  });

  group('parse: malformed input', () {
    void invalid(Uint8List blob) {
      expect(() => SharedDictionary.parse(blob), throwsBrotli());
    }

    test('bad magic', () {
      invalid(Uint8List.fromList(<int>[0x90, 0x00, 0, 0, 0]));
    });

    test('truncated header', () {
      invalid(Uint8List.fromList(<int>[0x91]));
    });

    test('prefix larger than the data', () {
      invalid(Uint8List.fromList(<int>[0x91, 0x00, 0x10, 0x00, 0x00]));
    });

    test('size_bits over the limit', () {
      final blob = _customListFixture();
      // byte 2 = prefix varint (0), byte 3 = NUM_WORD_LISTS, 4.. = size_bits.
      blob[4] = 16;
      invalid(blob);
    });

    test('transform type out of range', () {
      final blob = _customListFixture();
      final pos = blob.indexOf(22); // SHIFT_ALL byte
      expect(pos, greaterThan(0));
      blob[pos] = 23;
      invalid(blob);
    });

    test('non-zero parameter on a non-SHIFT transform', () {
      final blob = _customListFixture();
      blob[blob.length - 17] = 1;
      invalid(blob);
    });

    test('dictionary words index out of range', () {
      final blob = _customListFixture();
      blob[blob.length - 3] = 2;
      invalid(blob);
    });

    test('word list count over 64', () {
      final blob = _customListFixture();
      blob[3] = 65; // NUM_WORD_LISTS byte
      invalid(blob);
    });

    test('dictionary count zero', () {
      final blob = _customListFixture();
      blob[blob.length - 4] = 0; // NUM_DICTIONARIES byte
      invalid(blob);
    });

    test('bad boolean byte', () {
      final blob = _customListFixture();
      blob[blob.length - 1] = 2; // CONTEXT_ENABLED
      invalid(blob);
    });

    test('context map entry out of range', () {
      final blob = _serializedDictionary(
        wordLists: <Uint8List>[_wordListBytes(4, 1, 'frobquxx'.codeUnits)],
        transformLists: <Uint8List>[_defaultTransformListBytes()],
        contextBased: true,
        contextMap: List<int>.filled(64, 1),
      );
      invalid(blob);
    });

    test('transform triplet prefix id out of range', () {
      final transformList = _transformListBytes(
        stringlets: <List<int>>['up'.codeUnits, <int>[]],
        triplets: <List<int>>[
          <int>[0, 0, 1],
        ],
      );
      final blob = _serializedDictionary(
        wordLists: <Uint8List>[_wordListBytes(4, 1, 'frobquxx'.codeUnits)],
        transformLists: <Uint8List>[transformList],
        transformsIndex: <int>[0],
      );
      // First triplet prefix byte: 2 (u16 len) + 3 ("up") + 1 (empty
      // stringlet length byte) + 1 (num transforms) into the transform list.
      const perListHeader = 2 + 3 + 1;
      blob[2 + 1 + 28 + 8 + 1 + perListHeader] = 5; // prefix id 5 >= 2
      invalid(blob);
    });
  });

  group('stream-level: custom words and transforms', () {
    late SharedDictionary shared;
    const insertLength = 8;

    setUpAll(() {
      shared = SharedDictionary.parse(_customListFixture());
    });

    test('all 7 transforms decode byte-exactly', () {
      final transforms = shared.transformLists[0];
      final words = shared.wordLists[0];
      const expectedWords = <String>[
        'frob',
        'FROB',
        'upfrobing',
        'irob',
        'iure',
        'fr',
        'ob',
      ];
      for (var transform = 0; transform < 7; transform++) {
        final transformed = _applyTransform(
          transforms,
          words.wordBytes(4, 0),
          transform,
        );
        expectBytes(
          expectedWords[transform].codeUnits,
          transformed,
          'transform $transform apply',
        );
        final stream = _customStream(
          insertLength: insertLength,
          wordIndex: 0,
          transformIndex: transform,
          transformedLength: transformed.length,
        );
        final expected = <int>[
          ...List<int>.filled(insertLength, 0x41),
          ...transformed,
        ];
        expectBytes(
          _decodeShared(stream, _customListFixture()),
          expected,
          'transform $transform',
        );
        final streamed = decodeCoreChunked(
          stream,
          inputChunk: 3,
          outputChunk: 1,
          sharedDictionary: _customListFixture(),
        );
        expectBytes(streamed.bytes, expected, 'transform $transform stream');
        expect(streamed.state.dictionaryReferenceCount, 1);
      }
    });

    test('second word and prefix/suffix transform', () {
      final transformed = _applyTransform(
        shared.transformLists[0],
        shared.wordLists[0].wordBytes(4, 1),
        2,
      );
      final stream = _customStream(
        insertLength: 12,
        wordIndex: 1,
        transformIndex: 2,
        transformedLength: transformed.length,
      );
      expectBytes(_decodeShared(stream, _customListFixture()), <int>[
        ...List<int>.filled(12, 0x41),
        ...transformed,
      ], 'quxx prefix/suffix');
    });

    test('custom stream fails without the shared dictionary', () {
      // Address 2 is valid for the built-in list too, but the declared
      // metablock length no longer matches the built-in word.
      final stream = _customStream(
        insertLength: insertLength,
        wordIndex: 0,
        transformIndex: 2,
        transformedLength: 'upfrobing'.length,
      );
      expect(() => brotliDecode(stream), throwsBrotli());
    });

    test('255-byte transform affixes use the enlarged ring slack', () {
      final longPrefix = List<int>.filled(255, 0x70); // 'p'
      final transformList = _transformListBytes(
        stringlets: <List<int>>[longPrefix, <int>[]],
        triplets: <List<int>>[
          <int>[0, 0, 1],
        ],
      );
      final blob = _serializedDictionary(
        wordLists: <Uint8List>[_wordListBytes(4, 1, 'frobquxx'.codeUnits)],
        transformLists: <Uint8List>[transformList],
        transformsIndex: <int>[0],
      );
      final sharedLong = SharedDictionary.parse(blob);
      final transformed = _applyTransform(
        sharedLong.transformLists[0],
        sharedLong.wordLists[0].wordBytes(4, 0),
        0,
      );
      expect(transformed.length, 259);
      const longInsert = 1010; // near the 1 KiB ring end
      final stream = _customStream(
        insertLength: longInsert,
        wordIndex: 0,
        transformIndex: 0,
        transformedLength: transformed.length,
      );
      final expected = <int>[
        ...List<int>.filled(longInsert, 0x41),
        ...transformed,
      ];
      expectBytes(_decodeShared(stream, blob), expected, 'long affix one-shot');
      expectBytes(
        streamDecode(
          stream,
          inputChunk: 1,
          outputChunk: 7,
          sharedDictionary: blob,
        ),
        expected,
        'long affix streaming',
      );
    });

    test('invalid shared dictionary bytes throw at decoder creation', () {
      final bad = Uint8List.fromList(<int>[0x91, 0x00, 0x7F]);
      expect(
        () => _decodeShared(Uint8List.fromList(<int>[0x06]), bad),
        throwsBrotli(),
      );
      expect(() => StreamingDecoder(sharedDictionary: bad), throwsBrotli());
    });
  });

  group('stream-level: context map and multi-dictionary lookup', () {
    test('context-based map selects the custom dictionary', () {
      final wordLists = <Uint8List>[
        _wordListBytes(4, 1, 'frobquxx'.codeUnits),
        _wordListBytes(4, 1, 'wxyzabcd'.codeUnits),
      ];
      final transformLists = <Uint8List>[_defaultTransformListBytes()];
      final context =
          kContextLookupTable[0x41] | kContextLookupTable[0x41 + 256];
      final map = List<int>.filled(64, 0);
      map[context] = 1;
      final blob = _serializedDictionary(
        wordLists: wordLists,
        transformLists: transformLists,
        numDictionaries: 2,
        wordsIndex: <int>[1, 0], // dict0 -> list1, dict1 -> list0
        transformsIndex: <int>[0, 0],
        contextBased: true,
        contextMap: map,
      );
      final transformed = _applyTransform(
        SharedDictionary.parse(blob).transformLists[0],
        Uint8List.fromList('frob'.codeUnits),
        0,
      );
      final stream = _customStream(
        insertLength: 8,
        wordIndex: 0,
        transformIndex: 0,
        transformedLength: transformed.length,
      );
      expectBytes(_decodeShared(stream, blob), <int>[
        ...List<int>.filled(8, 0x41),
        ...transformed,
      ], 'context selects dictionary 1 (list0 = frob)');

      // Flip the map: the same context now selects dictionary 0 (list1).
      map.fillRange(0, 64, 1);
      map[context] = 0;
      final blob2 = _serializedDictionary(
        wordLists: wordLists,
        transformLists: transformLists,
        numDictionaries: 2,
        wordsIndex: <int>[1, 0],
        transformsIndex: <int>[0, 0],
        contextBased: true,
        contextMap: map,
      );
      expectBytes(_decodeShared(stream, blob2), <int>[
        ...List<int>.filled(8, 0x41),
        ...'wxyz'.codeUnits,
      ], 'context selects dictionary 0 (list1 = wxyz)');
    });

    test(
      'lookup scans the other dictionaries when the first cannot encode',
      () {
        final wordLists = <Uint8List>[
          _wordListBytes(4, 0, <int>[]),
          _wordListBytes(4, 1, 'frobquxx'.codeUnits),
        ];
        final blob = _serializedDictionary(
          wordLists: wordLists,
          transformLists: <Uint8List>[_defaultTransformListBytes()],
          numDictionaries: 2,
          wordsIndex: <int>[0, 1],
          transformsIndex: <int>[0, 0],
        );
        final parsed = SharedDictionary.parse(blob);
        final lookup = parsed.lookup(0, 4, 0);
        expect(lookup.words.isBuiltin, isFalse);
        expect(lookup.wordIndex, 0);
        expect(lookup.transformIndex, 0);
        final stream = _customStream(
          insertLength: 8,
          wordIndex: 0,
          transformIndex: 0,
          transformedLength: 4,
        );
        expectBytes(_decodeShared(stream, blob), <int>[
          ...List<int>.filled(8, 0x41),
          ...'frob'.codeUnits,
        ], 'multi-dictionary fallback');
      },
    );
  });

  group('stream-level: embedded LZ77 prefix', () {
    test('prefix-only serialized dictionary decodes a compound stream', () {
      final dictionary = _fixtureFile('text.dict');
      final raw = _fixtureFile('text.raw');
      final compressed = _fixtureFile('text.br');
      final serialized = _serializedDictionary(prefix: dictionary);
      final parsed = SharedDictionary.parse(serialized);
      expect(parsed.hasPrefix, isTrue);
      expect(parsed.isCustom, isFalse);
      expect(parsed.prefix, orderedEquals(dictionary));

      expectBytes(
        _decodeShared(compressed, serialized),
        raw,
        'prefix one-shot',
      );
      expectBytes(
        streamDecode(
          compressed,
          inputChunk: 3,
          outputChunk: 7,
          sharedDictionary: serialized,
        ),
        raw,
        'prefix streaming',
      );
    });

    test('prefix + custom lists: compound and static paths coexist', () {
      final dictionary = _fixtureFile('text.dict');
      final blob = _serializedDictionary(
        prefix: dictionary,
        wordLists: <Uint8List>[_wordListBytes(4, 1, 'frobquxx'.codeUnits)],
        transformLists: <Uint8List>[_defaultTransformListBytes()],
        transformsIndex: <int>[0],
      );
      final parsed = SharedDictionary.parse(blob);
      expect(parsed.hasPrefix, isTrue);
      expect(parsed.isCustom, isTrue);

      final transformed = _applyTransform(
        parsed.transformLists[0],
        parsed.wordLists[0].wordBytes(4, 0),
        0,
      );
      final stream = _customStream(
        insertLength: 8,
        wordIndex: 0,
        transformIndex: 0,
        transformedLength: transformed.length,
        compoundSize: dictionary.length,
      );
      // The compound prefix is present but unused by this stream; the custom
      // word address must still subtract the prefix size.
      expectBytes(_decodeShared(stream, blob), <int>[
        ...List<int>.filled(8, 0x41),
        ...transformed,
      ], 'prefix + custom');
    });

    test('prefix follows an explicit compound dictionary', () {
      // The embedded prefix is appended after the caller's dictionary, so a
      // stream addressing only the prefix must account for both sizes.
      final dictionary = _fixtureFile('text.dict');
      final extra = Uint8List.fromList(List<int>.filled(100, 0x7A));
      final blob = _serializedDictionary(prefix: dictionary);
      final raw = _fixtureFile('text.raw');
      final compressed = _fixtureFile('text.br');
      // text.br addresses a 4096-byte history; with the prefix appended after
      // a 100-byte compound dictionary, the most recent 4096 bytes are still
      // the prefix, so the stream decodes unchanged.
      expectBytes(
        brotliDecode(
          compressed,
          dictionary: BrotliDictionary(extra),
          sharedDictionary: blob,
        ),
        raw,
        'compound + prefix',
      );
    });
  });

  group('option plumbing', () {
    test('empty shared dictionary leaves normal streams unchanged', () {
      final quickfox = File('test/testdata/quickfox.compressed')
          .readAsBytesSync();
      expectBytes(
        _decodeShared(quickfox, Uint8List.fromList(<int>[0x91, 0x00, 0, 0, 0])),
        brotliDecode(quickfox),
        'empty shared dictionary',
      );
    });

    test('BrotliDecoder converter carries sharedDictionary', () {
      final shared = SharedDictionary.parse(_customListFixture());
      final transformed = _applyTransform(
        shared.transformLists[0],
        shared.wordLists[0].wordBytes(4, 0),
        1,
      );
      final stream = _customStream(
        insertLength: 8,
        wordIndex: 0,
        transformIndex: 1,
        transformedLength: transformed.length,
      );
      final expected = <int>[...List<int>.filled(8, 0x41), ...transformed];
      final decoder = BrotliDecoder(sharedDictionary: _customListFixture());
      expectBytes(decoder.convert(stream), expected, 'converter one-shot');

      final output = BytesBuilder(copy: false);
      final conversion = decoder.startChunkedConversion(
        ByteConversionSink.withCallback(output.add),
      );
      for (var i = 0; i < stream.length; i += 3) {
        final end = i + 3 < stream.length ? i + 3 : stream.length;
        conversion.add(Uint8List.sublistView(stream, i, end));
      }
      conversion.close();
      expectBytes(output.takeBytes(), expected, 'converter chunked');
    });
  });
}
