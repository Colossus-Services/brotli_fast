/// Cross-checks against the reference `brotli` command-line tool (google/brotli).
///
/// The binary is `$BROTLI_CLI` or `brotli` on the `PATH`. Tests that need it
/// are skipped when it is missing, unless `BROTLI_CLI_REQUIRED=1` (set in CI),
/// which turns a missing binary into a failure.
library;

import 'dart:io';
import 'dart:typed_data';

final String _executable = Platform.environment['BROTLI_CLI'] ?? 'brotli';

final bool _required = Platform.environment['BROTLI_CLI_REQUIRED'] == '1';

final bool _available = () {
  try {
    return Process.runSync(_executable, <String>['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}();

/// Skip reason for tests that need the CLI, or `null` when it is available.
///
/// Throws [StateError] when the CLI is required but missing.
String? brotliCliSkipReason() {
  if (_available) return null;
  if (_required) {
    throw StateError('BROTLI_CLI_REQUIRED=1 but `$_executable` is missing');
  }
  return '`$_executable` not found (set BROTLI_CLI or install brotli)';
}

/// Compresses [input] with the reference encoder.
Future<Uint8List> cliCompress(
  Uint8List input, {
  int quality = 5,
  int windowBits = 22,
  Uint8List? dictionary,
}) {
  return _withDictionary(dictionary, (dictionaryArgs) {
    return _run(<String>[
      '-c',
      '-q',
      '$quality',
      if (windowBits > 24)
        '--large_window=$windowBits'
      else ...<String>['-w', '$windowBits'],
      ...dictionaryArgs,
    ], input);
  });
}

/// Decompresses [compressed] with the reference decoder.
///
/// [largeWindow] accepts the non-RFC large-window format.
Future<Uint8List> cliDecompress(
  Uint8List compressed, {
  Uint8List? dictionary,
  bool largeWindow = false,
}) {
  return _withDictionary(dictionary, (dictionaryArgs) {
    return _run(<String>[
      '-d',
      '-c',
      if (largeWindow) '--large_window=30',
      ...dictionaryArgs,
    ], compressed);
  });
}

Future<Uint8List> _withDictionary(
  Uint8List? dictionary,
  Future<Uint8List> Function(List<String> args) body,
) async {
  if (dictionary == null) return body(const <String>[]);
  final dir = await Directory.systemTemp.createTemp('brotli_fast_dict');
  try {
    final file = File('${dir.path}${Platform.pathSeparator}dictionary.bin');
    await file.writeAsBytes(dictionary);
    return await body(<String>['-D', file.path]);
  } finally {
    await dir.delete(recursive: true);
  }
}

Future<Uint8List> _run(List<String> args, Uint8List stdinBytes) async {
  final process = await Process.start(_executable, args);
  final stdoutBytes = process.stdout.fold<BytesBuilder>(
    BytesBuilder(copy: false),
    (builder, chunk) => builder..add(chunk),
  );
  final stderrBytes = process.stderr.fold<BytesBuilder>(
    BytesBuilder(copy: false),
    (builder, chunk) => builder..add(chunk),
  );
  process.stdin.add(stdinBytes);
  await process.stdin.close();
  final exitCode = await process.exitCode;
  final out = (await stdoutBytes).takeBytes();
  if (exitCode != 0) {
    final err = String.fromCharCodes((await stderrBytes).takeBytes());
    throw ProcessException(_executable, args, err.trim(), exitCode);
  }
  return out;
}
