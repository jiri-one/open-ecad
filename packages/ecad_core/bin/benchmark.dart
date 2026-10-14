// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:ecad_core/ecad_core.dart';

import '../tool/benchmark_fixture.dart';

const _usage = '''Open ECAD pure Dart core benchmark
  dart run bin/benchmark.dart --mode jit [--output results.json]
  dart compile exe bin/benchmark.dart -o /tmp/ecad-core-benchmark
  /tmp/ecad-core-benchmark --mode aot [--output results.json]

Options:
  --sizes 1000,10000  Device counts, multiples of 5 (default: 1000,10000).
  --warmup 10         Untimed warm-up iterations per operation.
  --samples 31        Timed samples per operation.
  --mode jit|aot      Explicit invocation mode recorded in the result.
  --output PATH      Write the result; otherwise print JSON to stdout.
  --fixture PATH     Write one generated fixture and exit; requires one size.
No input project is read or modified. Renderer/UI performance is not measured.
''';

int _resultSink = 0;

Future<void> main(List<String> arguments) async {
  try {
    await _run(arguments);
  } on ArgumentError catch (error) {
    stderr.writeln(error.message);
    exitCode = 2;
  } on FileSystemException catch (error) {
    stderr.writeln('File error: ${error.message}');
    exitCode = 2;
  }
}

Future<void> _run(List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.write(_usage);
    return;
  }
  final options = <String, String>{};
  const allowed = {
    '--sizes',
    '--warmup',
    '--samples',
    '--mode',
    '--output',
    '--fixture',
  };
  for (var i = 0; i < arguments.length; i += 2) {
    final key = arguments[i];
    if (!allowed.contains(key) ||
        i + 1 >= arguments.length ||
        options.containsKey(key)) {
      throw ArgumentError('Invalid benchmark options.\n$_usage');
    }
    options[key] = arguments[i + 1];
  }
  final counts =
      (options['--sizes'] ?? '1000,10000').split(',').map((value) {
        final count = int.tryParse(value);
        if (count == null) throw ArgumentError('Invalid device count: $value.');
        return count;
      }).toList();
  if (counts.isEmpty ||
      counts.length > 8 ||
      counts.toSet().length != counts.length) {
    throw ArgumentError('Choose 1–8 distinct fixture sizes.');
  }
  final warmup = _integerOption(options, '--warmup', 10, 0, 1000);
  final samples = _integerOption(options, '--samples', 31, 3, 1000);
  final mode = options['--mode'];
  if (mode != 'jit' && mode != 'aot') {
    throw ArgumentError(
      '--mode must identify the actual invocation as jit or aot.',
    );
  }
  const productRuntime = bool.fromEnvironment('dart.vm.product');
  if (mode == 'aot' && !productRuntime) {
    throw ArgumentError(
      'This invocation is not a compiled product executable; use --mode jit.',
    );
  }
  final fixturePath = options['--fixture'];
  if (fixturePath != null) {
    if (counts.length != 1 || options.containsKey('--output')) {
      throw ArgumentError(
        '--fixture requires one --sizes value and cannot be combined with --output.',
      );
    }
    final fixture = createBenchmarkProject(deviceCount: counts.single);
    requireValidProject(fixture);
    await File(
      fixturePath,
    ).writeAsString('${jsonEncode(fixture.toJson())}\n', flush: true);
    stderr.writeln(
      'Wrote ${counts.single} deterministic devices to $fixturePath.',
    );
    return;
  }
  final environment = await _environment();
  final started = DateTime.now().toUtc();
  final results = <Map<String, Object?>>[];
  for (final count in counts) {
    stderr.writeln(
      'Benchmarking $count devices ($mode, $warmup warm-up, $samples samples)...',
    );
    results.add(_benchmark(count, warmup: warmup, samples: samples));
  }
  final result = <String, Object?>{
    'benchmark': 'open-ecad-core',
    'benchmarkVersion': 1,
    'startedAtUtc': started.toIso8601String(),
    'finishedAtUtc': DateTime.now().toUtc().toIso8601String(),
    'runtimeMode': mode,
    'productRuntime': productRuntime,
    'environment': environment,
    'configuration': {
      'warmupIterationsPerOperation': warmup,
      'samplesPerOperation': samples,
      'iterationsPerSample': 1,
      'devicesPerSheet': 80,
      'feederDevices': 5,
      'feederWires': 4,
      'timingClock': 'Stopwatch.elapsedTicks',
      'stopwatchFrequencyHz': Stopwatch().frequency,
      'statistics':
          'Median; nearest-rank p95; no outlier removal or forced GC.',
      'operationOrder': ['serialize', 'parse', 'validate', 'batchMoveAndUndo'],
      'fixtureGenerationIncluded': false,
      'diskIoIncluded': false,
      'utf8ConversionIncluded': false,
      'rendererIncluded': false,
      'threadsUsedByHarness': 1,
      'cpuAffinityPinned': false,
      'isolatedHost': false,
    },
    'results': results,
    'resultSink': _resultSink,
    'limits': {
      'maxPages': ProjectLimits.maxPages,
      'maxDevices': ProjectLimits.maxDevices,
      'maxWires': ProjectLimits.maxWires,
      'maxWaypointsPerWire': ProjectLimits.maxWaypoints,
      'maxCommandsPerTransaction': ProjectLimits.maxCommands,
      'maxCoordinateMagnitude': ProjectLimits.maxCoordinate,
      'maxFileBytes': ProjectLimits.maxFileBytes,
    },
  };
  final encoded = '${const JsonEncoder.withIndent('  ').convert(result)}\n';
  final output = options['--output'];
  if (output == null) {
    stdout.write(encoded);
  } else {
    await File(output).writeAsString(encoded, flush: true);
    stderr.writeln('Results written to $output.');
  }
}

Map<String, Object?> _benchmark(
  int count, {
  required int warmup,
  required int samples,
}) {
  final project = createBenchmarkProject(deviceCount: count);
  final diagnostics = validateProject(project);
  if (diagnostics.isNotEmpty) {
    throw StateError(
      'The fixture must have no structural errors or connectivity warnings.',
    );
  }
  final encoded = jsonEncode(project.toJson());
  final decoded = EcadProject.fromJson(jsonDecode(encoded));
  if (jsonEncode(decoded.toJson()) != encoded) {
    throw StateError(
      'The deterministic fixture failed its serialization preflight.',
    );
  }
  final engine = ProjectEngine(project);
  final moves =
      project.pages
          .map(
            (sheet) => MoveDevices(sheet.id, {
              for (final device in sheet.devices)
                device.id: device.position + const Vec2(10, 10),
            }),
          )
          .toList();
  engine.execute(
    moves,
    expectedRevision: engine.project.revision,
    label: 'Benchmark move',
  );
  if (!engine.undo() ||
      jsonEncode(
            engine.project.copyWith(revision: project.revision).toJson(),
          ) !=
          encoded) {
    throw StateError(
      'Fixture move/undo preflight did not restore the document.',
    );
  }
  final operations = <String, Object?>{};
  operations['serialize'] = _measure(
    () => jsonEncode(project.toJson()).length,
    warmup: warmup,
    samples: samples,
  );
  operations['parse'] = _measure(
    () {
      final parsed = EcadProject.fromJson(jsonDecode(encoded));
      return parsed.pages.length + parsed.pages.last.devices.length;
    },
    warmup: warmup,
    samples: samples,
  );
  operations['validate'] = _measure(
    () => validateProject(project).length,
    warmup: warmup,
    samples: samples,
  );
  operations['batchMoveAndUndo'] = _measure(
    () {
      engine.execute(
        moves,
        expectedRevision: engine.project.revision,
        label: 'Benchmark move',
      );
      if (!engine.undo())
        throw StateError('Expected one undoable transaction.');
      return engine.project.revision;
    },
    warmup: warmup,
    samples: samples,
  );
  return {
    'devices': count,
    'sheets': project.pages.length,
    'wires': project.pages.fold<int>(
      0,
      (sum, sheet) => sum + sheet.wires.length,
    ),
    'waypoints': project.pages.fold<int>(
      0,
      (sum, sheet) =>
          sum +
          sheet.wires.fold<int>(0, (n, wire) => n + wire.waypoints.length),
    ),
    'serializedUtf8Bytes': utf8.encode(encoded).length,
    'serializedUtf16CodeUnits': encoded.length,
    'fixtureFingerprint': _fingerprint(encoded),
    'structuralErrors': 0,
    'warnings': 0,
    'commandsPerMove': moves.length,
    'devicesMovedPerSample': count,
    'operations': operations,
  };
}

Map<String, Object?> _measure(
  int Function() operation, {
  required int warmup,
  required int samples,
}) {
  for (var i = 0; i < warmup; i++) {
    _resultSink ^= operation();
  }
  final timings = <double>[];
  for (var i = 0; i < samples; i++) {
    final stopwatch = Stopwatch()..start();
    final value = operation();
    stopwatch.stop();
    _resultSink ^= value;
    timings.add(stopwatch.elapsedTicks * 1000 / stopwatch.frequency);
  }
  final ordered = [...timings]..sort();
  final middle = ordered.length ~/ 2;
  final median =
      ordered.length.isOdd
          ? ordered[middle]
          : (ordered[middle - 1] + ordered[middle]) / 2;
  return {
    'unit': 'milliseconds',
    'median': median,
    'p95': ordered[(ordered.length * 0.95).ceil() - 1],
    'min': ordered.first,
    'max': ordered.last,
    'mean': ordered.reduce((a, b) => a + b) / ordered.length,
    'samples': timings,
  };
}

/// FNV-1a/32 identifies fixture changes; this is not a cryptographic digest.
String _fingerprint(String source) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(source)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return 'fnv1a32:${hash.toRadixString(16).padLeft(8, '0')}';
}

int _integerOption(
  Map<String, String> options,
  String key,
  int fallback,
  int min,
  int max,
) {
  final value =
      options.containsKey(key) ? int.tryParse(options[key]!) : fallback;
  if (value == null || value < min || value > max) {
    throw ArgumentError('$key must be an integer between $min and $max.');
  }
  return value;
}

Future<Map<String, Object?>> _environment() async {
  Future<String?> read(String path) async {
    final file = File(path);
    return await file.exists() ? file.readAsString() : null;
  }

  final procCpu = await read('/proc/cpuinfo');
  final procMemory = await read('/proc/meminfo');
  final osRelease = await read('/etc/os-release');
  final memoryKb = RegExp(
    r'^MemTotal:\s+(\d+)\s+kB',
    multiLine: true,
  ).firstMatch(procMemory ?? '')?.group(1);
  return {
    'dartVersion': Platform.version,
    'operatingSystem': Platform.operatingSystem,
    'operatingSystemVersion': Platform.operatingSystemVersion,
    'distribution': RegExp(
      r'^PRETTY_NAME="?([^"\n]+)',
      multiLine: true,
    ).firstMatch(osRelease ?? '')?.group(1),
    'cpuModel': RegExp(
      r'^model name\s*:\s*(.+)$',
      multiLine: true,
    ).firstMatch(procCpu ?? '')?.group(1),
    'logicalProcessors': Platform.numberOfProcessors,
    'physicalMemoryBytes': memoryKb == null ? null : int.parse(memoryKb) * 1024,
    'executableName':
        Platform.resolvedExecutable.split(Platform.pathSeparator).last,
    'executableArguments': Platform.executableArguments,
    'runtimeTarget': RegExp(
      r'on "([^"]+)"$',
    ).firstMatch(Platform.version)?.group(1),
  };
}
