// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:ecad_core/ecad_core.dart';

const _usage = '''Open ECAD — portable project tools

Usage:
  dart run ecad_core:open_ecad sample [output.ecad.json|-]
  dart run ecad_core:open_ecad validate project.ecad.json [--json]
  dart run ecad_core:open_ecad apply project.ecad.json commands.json [output.ecad.json|-]
      [--expected-revision N]

Use - to read one input from stdin or write output to stdout.
Apply accepts a command array or {"commands": [...], "expectedRevision": N, "label": "..."}.
All commands are applied atomically with the same engine as the editor.
Validation checks document integrity, not electrical safety or compliance.
Exit codes: 0 success (warnings allowed), 1 validation errors, 2 invalid input.
''';

Future<void> main(List<String> arguments) async {
  try {
    exitCode = await _run(arguments);
  } on EcadException catch (error) {
    stderr.writeln('${error.code}: ${error.message}');
    exitCode = 2;
  } on FormatException catch (error) {
    stderr.writeln('invalid_json: ${error.message}');
    exitCode = 2;
  } on FileSystemException catch (error) {
    stderr.writeln(
      'file_error: ${error.message}${error.path == null ? '' : ' (${error.path})'}',
    );
    exitCode = 2;
  }
}

Future<int> _run(List<String> arguments) async {
  if (arguments.isEmpty ||
      const {'--help', '-h', 'help'}.contains(arguments.first)) {
    stdout.write(_usage);
    return 0;
  }
  final args = arguments.skip(1).toList();
  switch (arguments.first) {
    case 'sample':
      if (args.length > 1) return _usageError();
      await _writeJson(
        args.isEmpty ? '-' : args.single,
        DemoProject.create().toJson(),
      );
      return 0;
    case 'validate':
      final jsonOutput = args.remove('--json');
      if (args.length != 1) return _usageError();
      final project = EcadProject.fromJson(await _readJson(args.single));
      final diagnostics = validateProject(project);
      final errors =
          diagnostics
              .where((d) => d.severity == DiagnosticSeverity.error)
              .length;
      if (jsonOutput) {
        stdout.writeln(
          const JsonEncoder.withIndent('  ').convert({
            'valid': errors == 0,
            'revision': project.revision,
            'scope':
                'Document integrity and connectivity; not electrical safety or compliance.',
            'diagnostics': diagnostics.map((d) => d.toJson()).toList(),
          }),
        );
      } else {
        stdout.writeln(
          '${project.name}: ${project.pages.length} sheets, revision ${project.revision}',
        );
        for (final diagnostic in diagnostics) {
          stdout.writeln('${diagnostic.severity.name}: ${diagnostic.message}');
        }
        stdout.writeln(
          '$errors structural errors. Validation does not certify electrical safety or compliance.',
        );
      }
      return errors == 0 ? 0 : 1;
    case 'apply':
      int? expectedRevision;
      final expectedIndex = args.indexOf('--expected-revision');
      if (expectedIndex >= 0) {
        if (expectedIndex + 1 >= args.length) return _usageError();
        expectedRevision = int.tryParse(args[expectedIndex + 1]);
        if (expectedRevision == null ||
            expectedRevision < 0 ||
            expectedRevision > ProjectLimits.maxRevision) {
          throw const EcadException(
            'Expected revision must be a nonnegative integer.',
            code: 'invalid_command',
          );
        }
        args.removeRange(expectedIndex, expectedIndex + 2);
      }
      if (args.length < 2 ||
          args.length > 3 ||
          args.take(2).where((path) => path == '-').length > 1) {
        return _usageError();
      }
      final project = EcadProject.fromJson(await _readJson(args[0]));
      final payload = await _readJson(args[1]);
      String label = 'CLI transaction';
      Object? commandData = payload;
      if (payload is Map) {
        final envelope = jsonObject(
          payload,
          'transaction',
          allowed: const {'commands', 'expectedRevision', 'label'},
        );
        commandData = envelope['commands'];
        label = jsonString(envelope, 'label', fallback: label, max: 200);
        if (envelope.containsKey('expectedRevision')) {
          final declaredRevision = jsonInteger(envelope, 'expectedRevision');
          if (expectedRevision != null &&
              expectedRevision != declaredRevision) {
            throw const EcadException(
              'Revision argument conflicts with the transaction envelope.',
              code: 'stale_revision',
            );
          }
          expectedRevision = declaredRevision;
        }
      }
      final engine = ProjectEngine(project);
      engine.execute(
        decodeCommands(commandData),
        label: label,
        expectedRevision: expectedRevision,
      );
      await _writeJson(
        args.length == 3 ? args[2] : '-',
        engine.project.toJson(),
      );
      return 0;
    default:
      return _usageError();
  }
}

int _usageError() {
  stderr.write(_usage);
  return 2;
}

Future<Object?> _readJson(String path) async {
  List<int> bytes;
  if (path == '-') {
    bytes = <int>[];
    await for (final chunk in stdin) {
      if (bytes.length + chunk.length > ProjectLimits.maxFileBytes) {
        throw const EcadException(
          'Input exceeds the 128 MiB file limit.',
          code: 'limit_exceeded',
        );
      }
      bytes.addAll(chunk);
    }
  } else {
    final file = File(path);
    if (await file.length() > ProjectLimits.maxFileBytes) {
      throw const EcadException(
        'Input exceeds the 128 MiB file limit.',
        code: 'limit_exceeded',
      );
    }
    bytes = await file.readAsBytes();
    if (bytes.length > ProjectLimits.maxFileBytes) {
      throw const EcadException(
        'Input exceeds the 128 MiB file limit.',
        code: 'limit_exceeded',
      );
    }
  }
  return jsonDecode(utf8.decode(bytes));
}

Future<void> _writeJson(String path, Object? data) async {
  // Large drawings remain within the same input byte budget when saved.
  final encoded = utf8.encode('${jsonEncode(data)}\n');
  if (encoded.length > ProjectLimits.maxFileBytes) {
    throw const EcadException(
      'Output exceeds the 128 MiB file limit.',
      code: 'limit_exceeded',
    );
  }
  if (path == '-') {
    stdout.add(encoded);
    return;
  }
  // Write to a sibling file so an interrupted save cannot truncate a project.
  final destination = File(path).absolute;
  final temporary = File('${destination.path}.${newId('save')}.tmp');
  try {
    await temporary.writeAsBytes(encoded, flush: true);
    await temporary.rename(destination.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
