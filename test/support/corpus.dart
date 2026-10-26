import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

final class CorpusEntry {
  CorpusEntry({
    required this.name,
    required this.compressed,
    required this.raw,
    required this.rawBytes,
    required this.compressedBytes,
    required this.rawSha256,
    required this.compressedSha256,
  });

  final String name;
  final String compressed;
  final String raw;
  final int rawBytes;
  final int compressedBytes;
  final String rawSha256;
  final String compressedSha256;
}

final class MalformedVector {
  MalformedVector({
    required this.name,
    required this.bytes,
    required this.sha256,
  });

  final String name;
  final int bytes;
  final String sha256;
}

final class Corpus {
  Corpus({
    required this.directory,
    required this.entries,
    required this.malformed,
  });

  final Directory directory;
  final List<CorpusEntry> entries;
  final List<MalformedVector> malformed;

  static Corpus load([String root = 'test/testdata']) {
    final dir = Directory(root);
    final manifest = jsonDecode(
      File('${dir.path}/manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final entries = (manifest['entries'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(
          (e) => CorpusEntry(
            name: e['name'] as String,
            compressed: e['compressed'] as String,
            raw: e['raw'] as String,
            rawBytes: e['rawBytes'] as int,
            compressedBytes: e['compressedBytes'] as int,
            rawSha256: e['rawSha256'] as String,
            compressedSha256: e['compressedSha256'] as String,
          ),
        )
        .toList(growable: false);
    final malformed = (manifest['malformed'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(
          (e) => MalformedVector(
            name: e['name'] as String,
            bytes: e['bytes'] as int,
            sha256: e['sha256'] as String,
          ),
        )
        .toList(growable: false);
    return Corpus(directory: dir, entries: entries, malformed: malformed);
  }

  Uint8List compressedBytes(CorpusEntry entry) =>
      File('${directory.path}/${entry.compressed}').readAsBytesSync();

  Uint8List rawBytes(CorpusEntry entry) =>
      File('${directory.path}/${entry.raw}').readAsBytesSync();

  Uint8List malformedBytes(MalformedVector vector) =>
      File('${directory.path}/${vector.name}').readAsBytesSync();
}
