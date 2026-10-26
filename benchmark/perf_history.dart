/// Performance-history recorder.
///
/// Wraps `benchmark/bench.dart` to produce one stable, comparable measurement
/// of the current tree for `benchmark/HISTORY.md`:
///
/// 1. compiles `benchmark/bench.dart` to AOT (unless `--no-compile`),
/// 2. runs it `--discard` + `--runs` times as separate processes and drops
///    the discarded warm-up runs,
/// 3. reduces every operation to the **median MB/s across runs** plus the
///    min..max spread, and checks the compressed size is identical in every run,
/// 4. writes a JSON snapshot (`--save`) and prints a Markdown section ready to
///    paste into `benchmark/HISTORY.md`; with `--baseline` it adds a Δ column
///    against an earlier snapshot.
///
/// Numbers are machine-specific: only compare snapshots from the same host.
///
/// Usage:
///   dart run benchmark/perf_history.dart
///   dart run benchmark/perf_history.dart --label "after X" \
///     --baseline benchmark/history/baseline.json --save build/perf/new.json
library;

import 'dart:convert';
import 'dart:io';

const String snapshotSchema = 'brotli_fast/perf_history@1';

Future<void> main(List<String> args) async {
  final _Options options;
  try {
    options = _Options.parse(args);
  } on _UsageException catch (error) {
    stderr.writeln('perf_history: ${error.message}');
    stderr.writeln(_usage);
    exit(64);
  }
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }

  final Directory root = _findRepoRoot();
  final String dart = Platform.resolvedExecutable;
  final String exe = _join(root.path, 'build/bench.exe');

  if (!options.noCompile || !File(exe).existsSync()) {
    stderr.writeln('compiling benchmark/bench.dart (AOT)...');
    Directory(_join(root.path, 'build')).createSync(recursive: true);
    await _run(dart, <String>[
      'compile',
      'exe',
      'benchmark/bench.dart',
      '-o',
      'build/bench.exe',
    ], root);
  }

  final Directory tmp = Directory.systemTemp.createTempSync('perf_history');
  final Map<String, List<Map<String, dynamic>>> samples =
      <String, List<Map<String, dynamic>>>{};
  final int total = options.discard + options.runs;
  try {
    for (var i = 0; i < total; i++) {
      final bool warm = i < options.discard;
      stderr.writeln(
        warm
            ? 'warm-up run ${i + 1}/${options.discard} (discarded)'
            : 'run ${i - options.discard + 1}/${options.runs}',
      );
      final String jsonl = _join(tmp.path, 'run$i.jsonl');
      await _run(exe, <String>[
        '--qualities',
        options.qualities,
        '--rounds',
        '${options.rounds}',
        '--warmup',
        '${options.warmup}',
        '--jsonl',
        jsonl,
      ], root);
      if (warm) continue;
      for (final String line in File(jsonl).readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        final Map<String, dynamic> record =
            jsonDecode(line) as Map<String, dynamic>;
        final String key =
            '${record['corpus']}/${record['op']}/${record['quality']}';
        samples.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(record);
      }
    }
  } finally {
    tmp.deleteSync(recursive: true);
  }

  final List<Map<String, dynamic>> results = <Map<String, dynamic>>[];
  for (final List<Map<String, dynamic>> records in samples.values) {
    final List<double> speeds = <double>[
      for (final Map<String, dynamic> r in records)
        (r['mb_per_second'] as num).toDouble(),
    ]..sort();
    final Set<int> sizes = <int>{
      for (final Map<String, dynamic> r in records) r['output_bytes'] as int,
    };
    final Map<String, dynamic> first = records.first;
    if (sizes.length != 1) {
      stderr.writeln(
        'perf_history: ${first['corpus']} ${first['op']} q${first['quality']} '
        'produced different output sizes across runs: $sizes',
      );
      exit(1);
    }
    final double median = _median(speeds);
    results.add(<String, dynamic>{
      'corpus': first['corpus'],
      'op': first['op'],
      'quality': first['quality'],
      'mb_per_second': _round(median),
      'min_mb_per_second': _round(speeds.first),
      'max_mb_per_second': _round(speeds.last),
      'spread_pct': _round((speeds.last - speeds.first) / median * 100),
      'raw_bytes': first['raw_bytes'],
      'output_bytes': first['output_bytes'],
    });
  }

  final Map<String, dynamic> snapshot = <String, dynamic>{
    'schema': snapshotSchema,
    'label': options.label,
    'date': DateTime.now().toUtc().toIso8601String(),
    'commit': await _git(root, <String>['rev-parse', '--short', 'HEAD']),
    'dirty': (await _git(root, <String>[
      'status',
      '--porcelain',
      '--',
      'lib',
    ])).isNotEmpty,
    'host': <String, dynamic>{
      'os': Platform.operatingSystem,
      'cpu': await _cpuName(),
      'cores': Platform.numberOfProcessors,
      'dart': Platform.version.split(' ').first,
    },
    'settings': <String, dynamic>{
      'compile': 'aot',
      'runs': options.runs,
      'discarded_runs': options.discard,
      'rounds': options.rounds,
      'warmup': options.warmup,
      'statistic': 'median across runs of per-run median MB/s',
    },
    'results': results,
  };

  Map<String, dynamic>? baseline;
  if (options.baseline != null) {
    baseline = jsonDecode(
      File(options.baseline!).readAsStringSync(),
    ) as Map<String, dynamic>;
    final Map<String, dynamic> baseHost =
        baseline['host'] as Map<String, dynamic>;
    final Map<String, dynamic> host = snapshot['host'] as Map<String, dynamic>;
    if (baseHost['cpu'] != host['cpu'] || baseHost['os'] != host['os']) {
      stderr.writeln(
        'warning: baseline host (${baseHost['os']}, ${baseHost['cpu']}) differs '
        'from this host (${host['os']}, ${host['cpu']}); Δ is not meaningful.',
      );
    }
  }

  if (options.save != null) {
    final File out = File(options.save!);
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(snapshot)}\n',
    );
    stderr.writeln('snapshot: ${options.save}');
  }
  stdout.write(_markdown(snapshot, baseline));
}

String _markdown(Map<String, dynamic> snap, Map<String, dynamic>? base) {
  final Map<String, dynamic> host = snap['host'] as Map<String, dynamic>;
  final Map<String, dynamic> settings =
      snap['settings'] as Map<String, dynamic>;
  final Map<String, Map<String, dynamic>> baseRows =
      <String, Map<String, dynamic>>{
        if (base != null)
          for (final dynamic r in base['results'] as List<dynamic>)
            _key(r as Map<String, dynamic>): r,
      };
  final String date = (snap['date'] as String).substring(0, 10);
  final String dirty = snap['dirty'] == true
      ? ' (uncommitted lib/ changes)'
      : '';
  final StringBuffer md = StringBuffer()
    ..writeln('### $date · `${snap['commit']}`$dirty · ${snap['label']}')
    ..writeln()
    ..writeln(
      'Host: ${host['os']}, ${host['cpu']}, ${host['cores']} cores, '
      'Dart ${host['dart']}. AOT, median of ${settings['runs']} '
      'runs × ${settings['rounds']} rounds '
      '(${settings['discarded_runs']} warm-up run discarded).',
    );
  if (base != null) {
    md.writeln('Δ against `${base['commit']}` (${base['label']}).');
  }
  md
    ..writeln()
    ..write('| corpus | op | q | MB/s | spread | compressed bytes |')
    ..writeln(base != null ? ' Δ MB/s | Δ bytes |' : '')
    ..write('|---|---|--:|--:|--:|--:|')
    ..writeln(base != null ? '--:|--:|' : '');
  for (final dynamic raw in snap['results'] as List<dynamic>) {
    final Map<String, dynamic> r = raw as Map<String, dynamic>;
    // Decode output is always the raw corpus; only encode size is informative.
    final bool encode = r['op'] == 'encode';
    md.write(
      '| ${r['corpus']} | ${r['op']} | ${r['quality']} '
      '| ${(r['mb_per_second'] as num).toStringAsFixed(1)} '
      '| ±${((r['spread_pct'] as num) / 2).toStringAsFixed(1)}% '
      '| ${encode ? r['output_bytes'] : '–'} |',
    );
    if (base != null) {
      final Map<String, dynamic>? b = baseRows[_key(r)];
      if (b == null) {
        md.write(' new | new |');
      } else {
        final double delta =
            ((r['mb_per_second'] as num) / (b['mb_per_second'] as num) - 1) *
            100;
        final int bytes =
            (r['output_bytes'] as int) - (b['output_bytes'] as int);
        md.write(
          ' ${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)}% '
          '| ${encode ? '${bytes > 0 ? '+' : ''}$bytes' : '–'} |',
        );
      }
    }
    md.writeln();
  }
  return md.toString();
}

String _key(Map<String, dynamic> r) =>
    '${r['corpus']}/${r['op']}/${r['quality']}';

double _median(List<double> sorted) {
  final int mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

double _round(double value) => (value * 10).roundToDouble() / 10;

Future<void> _run(String exe, List<String> args, Directory root) async {
  final ProcessResult result = await Process.run(
    exe,
    args,
    workingDirectory: root.path,
  );
  if (result.exitCode != 0) {
    stderr
      ..writeln('perf_history: `$exe ${args.join(' ')}` failed')
      ..write(result.stdout)
      ..write(result.stderr);
    exit(2);
  }
}

Future<String> _git(Directory root, List<String> args) async {
  try {
    final ProcessResult result = await Process.run(
      'git',
      args,
      workingDirectory: root.path,
    );
    return result.exitCode == 0 ? (result.stdout as String).trim() : '?';
  } on ProcessException {
    return '?';
  }
}

Future<String> _cpuName() async {
  try {
    if (Platform.isMacOS) {
      final ProcessResult r = await Process.run('sysctl', <String>[
        '-n',
        'machdep.cpu.brand_string',
      ]);
      if (r.exitCode == 0) return (r.stdout as String).trim();
    } else if (Platform.isLinux) {
      for (final String line in File('/proc/cpuinfo').readAsLinesSync()) {
        if (line.startsWith('model name')) {
          return line.split(':').last.trim();
        }
      }
    } else if (Platform.isWindows) {
      final String? id = Platform.environment['PROCESSOR_IDENTIFIER'];
      if (id != null) return id;
    }
  } on Object {
    // Fall through to the generic label.
  }
  return '?';
}

Directory _findRepoRoot() {
  Directory dir = Directory.current.absolute;
  for (var depth = 0; depth < 8; depth++) {
    if (File(_join(dir.path, 'pubspec.yaml')).existsSync() &&
        File(_join(dir.path, 'lib/brotli_fast.dart')).existsSync()) {
      return dir;
    }
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  stderr.writeln('perf_history: run from inside the brotli_fast repository');
  exit(2);
}

String _join(String base, String relative) =>
    '$base${Platform.pathSeparator}'
    '${relative.replaceAll('/', Platform.pathSeparator)}';

class _UsageException implements Exception {
  _UsageException(this.message);
  final String message;
}

class _Options {
  bool help = false;
  bool noCompile = false;
  int runs = 5;
  int discard = 1;
  int rounds = 25;
  int warmup = 3;
  String qualities = '0,1,5,9';
  String label = 'snapshot';
  String? save;
  String? baseline;

  static _Options parse(List<String> args) {
    final _Options o = _Options();
    String value(int i) {
      if (i + 1 >= args.length) {
        throw _UsageException('${args[i]} needs a value');
      }
      return args[i + 1];
    }

    int positive(int i, {int min = 1}) {
      final int? n = int.tryParse(value(i));
      if (n == null || n < min) {
        throw _UsageException('${args[i]} must be an integer >= $min');
      }
      return n;
    }

    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '-h' || '--help':
          o.help = true;
        case '--no-compile':
          o.noCompile = true;
        case '--runs':
          o.runs = positive(i++);
        case '--discard':
          o.discard = positive(i++, min: 0);
        case '--rounds':
          o.rounds = positive(i++);
        case '--warmup':
          o.warmup = positive(i++, min: 0);
        case '--qualities':
          o.qualities = value(i++);
        case '--label':
          o.label = value(i++);
        case '--save':
          o.save = value(i++);
        case '--baseline':
          o.baseline = value(i++);
        default:
          throw _UsageException('unknown option ${args[i]}');
      }
    }
    return o;
  }
}

const String _usage = '''
perf_history — record a stable AOT measurement for benchmark/HISTORY.md

Usage:
  dart run benchmark/perf_history.dart [options]

Options:
  --label TEXT       short description of this snapshot (default: snapshot)
  --save PATH        write the JSON snapshot to PATH
  --baseline PATH    earlier snapshot; adds Δ MB/s and Δ bytes columns
  --runs N           measured harness runs (default: 5)
  --discard N        warm-up harness runs to drop first (default: 1)
  --rounds N         timed rounds per operation per run (default: 25)
  --warmup N         warm-up calls per operation per run (default: 3)
  --qualities LIST   comma list (default: 0,1,5,9)
  --no-compile       reuse build/bench.exe if it exists
''';
