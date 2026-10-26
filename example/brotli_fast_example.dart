import 'dart:convert';

import 'package:brotli_fast/brotli_fast.dart';

Future<void> main() async {
  final data = utf8.encode(
    List.generate(
      500,
      (i) => '{"id":$i,"name":"user$i","score":${i * 37 % 101}}',
    ).join('\n'),
  );

  // One-shot: quality 5 by default; 0..11 trades speed for ratio.
  final packed = brotliEncode(data);
  final smallest = brotliEncode(data, quality: 11);
  print(
    '${data.length} bytes -> ${packed.length} (q5), ${smallest.length} (q11)',
  );

  final restored = brotliDecode(packed);
  print('round trip ok: ${utf8.decode(restored) == utf8.decode(data)}');

  // Strings, through dart:convert.
  final text = utf8.fuse(brotli);
  print(text.decode(text.encode('héllo, wörld')));

  // Streams: compress and decompress chunk by chunk.
  final chunks = Stream<List<int>>.fromIterable([
    data.sublist(0, 1000),
    data.sublist(1000),
  ]);
  final compressed = await chunks
      .transform(brotli.encoder)
      .expand((c) => c)
      .toList();
  final decompressed = await Stream.value(compressed)
      .transform(brotli.decoder)
      .expand((c) => c)
      .toList();
  print('stream round trip: ${decompressed.length} bytes');

  // A dictionary shared by both sides shrinks small, similar payloads.
  final dictionary = BrotliDictionary(
    utf8.encode('{"user":"","status":"active"}'),
  );
  final record = utf8.encode('{"user":"ada","status":"active"}');
  final withDictionary = brotliEncode(
    record,
    quality: 9,
    dictionary: dictionary,
  );
  print(
    'record: ${record.length} -> ${withDictionary.length} bytes with dictionary',
  );
  print(utf8.decode(brotliDecode(withDictionary, dictionary: dictionary)));
}
