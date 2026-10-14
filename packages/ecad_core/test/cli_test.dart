// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File projectFile;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ecad_core_cli_');
    projectFile = File('${directory.path}/project.ecad.json');
    await projectFile.writeAsString(jsonEncode(DemoProject.create().toJson()));
  });
  tearDown(() => directory.delete(recursive: true));

  Future<ProcessResult> run(List<String> args) => Process.run(
    Platform.resolvedExecutable,
    ['run', 'bin/open_ecad.dart', ...args],
    workingDirectory: Directory.current.path,
  );

  test(
    'sample and validate produce machine-readable portable projects',
    () async {
      final sample = await run(['sample']);
      expect(sample.exitCode, 0, reason: sample.stderr.toString());
      final project = EcadProject.fromJson(jsonDecode(sample.stdout as String));
      expect(project.pages, hasLength(2));
      final validation = await run(['validate', projectFile.path, '--json']);
      expect(validation.exitCode, 0, reason: validation.stderr.toString());
      final result =
          jsonDecode(validation.stdout as String) as Map<String, dynamic>;
      expect(result['valid'], isTrue);
      expect(
        result['diagnostics'],
        isNotEmpty,
      ); // External 0 V drawing boundary.
    },
  );

  test(
    'apply writes a single revision and rejects stale edits without changing output',
    () async {
      final commands = File('${directory.path}/commands.json');
      await commands.writeAsString(
        jsonEncode({
          'expectedRevision': 0,
          'commands': [const RenameProject('CLI edit').toJson()],
        }),
      );
      final output = File('${directory.path}/updated.ecad.json');
      final applied = await run([
        'apply',
        projectFile.path,
        commands.path,
        output.path,
      ]);
      expect(applied.exitCode, 0, reason: applied.stderr.toString());
      final saved = await output.readAsString();
      final project = EcadProject.fromJson(jsonDecode(saved));
      expect(project.name, 'CLI edit');
      expect(project.revision, 1);
      final stale = await run([
        'apply',
        output.path,
        commands.path,
        output.path,
      ]);
      expect(stale.exitCode, 2);
      expect(stale.stderr.toString(), contains('stale_revision'));
      expect(await output.readAsString(), saved);
      expect(
        directory.listSync().where((file) => file.path.endsWith('.tmp')),
        isEmpty,
      );
    },
  );

  test('malformed command batches never create an output file', () async {
    final commands = File('${directory.path}/commands.json');
    await commands.writeAsString(
      jsonEncode([
        const RenameProject('Not committed').toJson(),
        const DeleteWire('sheet_power', 'does_not_exist').toJson(),
      ]),
    );
    final output = File('${directory.path}/absent.ecad.json');
    final result = await run([
      'apply',
      projectFile.path,
      commands.path,
      output.path,
    ]);
    expect(result.exitCode, 2);
    expect(result.stderr.toString(), contains('missing_wire'));
    expect(await output.exists(), isFalse);
  });
}
