/// Encode/decode throughput on the deterministic 1 MiB corpus.
///
/// For each corpus (text, binary) and quality, times `brotliEncode` and
/// `brotliDecode` (of the stream just encoded): warm-up calls, then one
/// stopwatch per round, reporting the median round as MB/s
/// (`raw bytes / median seconds / 1e6`). Every stream is checked to round-trip
/// before it is timed.
///
/// Prefer an AOT build for stable numbers (`benchmark/perf_history.dart` does
/// that and repeats the run):
///
/// ```sh
/// dart run benchmark/bench.dart --qualities 5 --rounds 15
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';

import 'corpus.dart';

/// Keeps outputs observable so the compiler cannot drop the work.
int _sink = 0;

void main(List<String> args) {
  final options = _Options.parse(args);
  final corpora = <String, Uint8List>{
    'text': makeText(),
    'binary': makeBinary(),
  };
  final records = <Map<String, Object>>[];
  for (final MapEntry(key: corpus, value: input) in corpora.entries) {
    for (final quality in options.qualities) {
      final stream = brotliEncode(input, quality: quality);
      final restored = brotliDecode(stream);
      if (!_equal(restored, input)) {
        stderr.writeln('bench: $corpus q$quality does not round-trip');
        exit(1);
      }
      final encode = _median(
        () => brotliEncode(input, quality: quality),
        options,
      );
      final decode = _median(() => brotliDecode(stream), options);
      for (final (op, seconds) in [('encode', encode), ('decode', decode)]) {
        final mbPerSecond = input.length / seconds / 1e6;
        records.add(<String, Object>{
          'corpus': corpus,
          'op': op,
          'quality': quality,
          'mb_per_second': (mbPerSecond * 1000).round() / 1000,
          'raw_bytes': input.length,
          'output_bytes': op == 'encode' ? stream.length : input.length,
        });
        stdout.writeln(
          '${corpus.padRight(6)}  ${op.padRight(6)}  q${'$quality'.padRight(2)}'
          '  ${mbPerSecond.toStringAsFixed(1).padLeft(8)} MB/s'
          '  ${stream.length} bytes',
        );
      }
    }
  }
  if (options.jsonl != null) {
    File(options.jsonl!)
        .writeAsStringSync('${records.map(jsonEncode).join('\n')}\n');
  }
  stdout.writeln('sink=$_sink');
}

/// Median seconds of [options.rounds] timed calls after the warm-up.
double _median(Uint8List Function() body, _Options options) {
  for (var i = 0; i < options.warmup; i++) {
    _sink += body().length;
  }
  final samples = <double>[];
  for (var i = 0; i < options.rounds; i++) {
    final stopwatch = Stopwatch()..start();
    final out = body();
    stopwatch.stop();
    _sink += out.length;
    samples.add(stopwatch.elapsedTicks / stopwatch.frequency);
  }
  samples.sort();
  final mid = samples.length ~/ 2;
  return samples.length.isOdd
      ? samples[mid]
      : (samples[mid - 1] + samples[mid]) / 2;
}

bool _equal(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final class _Options {
  List<int> qualities = <int>[0, 1, 5, 9];
  int rounds = 15;
  int warmup = 3;
  String? jsonl;

  static _Options parse(List<String> args) {
    final options = _Options();
    for (var i = 0; i < args.length; i++) {
      String value() {
        if (i + 1 >= args.length) _usage('${args[i]} needs a value');
        return args[++i];
      }

      switch (args[i]) {
        case '--qualities':
          options.qualities = value().split(',').map(int.parse).toList();
        case '--rounds':
          options.rounds = int.parse(value());
        case '--warmup':
          options.warmup = int.parse(value());
        case '--jsonl':
          options.jsonl = value();
        default:
          _usage('unknown option ${args[i]}');
      }
    }
    if (options.rounds < 1) _usage('--rounds must be >= 1');
    return options;
  }
}

Never _usage(String message) {
  stderr.writeln('bench: $message');
  stderr.writeln(
    'usage: dart run benchmark/bench.dart '
    '[--qualities 0,1,5,9] [--rounds 15] [--warmup 3] [--jsonl PATH]',
  );
  exit(64);
}
