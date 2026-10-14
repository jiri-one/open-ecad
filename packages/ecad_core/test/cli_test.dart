// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

final _terminalControls = RegExp(r'[\x00-\x09\x0b-\x1f\x7f-\x9f]');
const _linkSkip =
    'Creating symbolic links on Windows requires developer mode or elevation.';

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

  test('plain text escapes terminal controls taken from input files', () async {
    final demo = DemoProject.create();
    const port = 'x\u001b[2J\u009b31m\nerror: forged';
    final hostile = demo.copyWith(
      name: 'Řídicí panel\u001b]0;title\u0007\u001b[31m\r',
      pages: [
        demo.pages.first.copyWith(
          wires: [
            ...demo.pages.first.wires,
            Wire(
              id: 'odd_wire',
              from: const TerminalRef(deviceId: 'dev_supply', portId: 'out'),
              to: const TerminalRef(deviceId: 'dev_motor', portId: port),
            ),
          ],
        ),
        demo.pages.last,
      ],
    );
    final hostileFile = File('${directory.path}/hostile.ecad.json');
    await hostileFile.writeAsString(jsonEncode(hostile.toJson()));

    final plain = await run(['validate', hostileFile.path]);
    expect(plain.exitCode, 1);
    final lines = (plain.stdout as String).split('\n');
    expect(lines, everyElement(isNot(contains(_terminalControls))));
    expect(
      lines.first,
      r'Řídicí panel\x1b]0;title\x07\x1b[31m\x0d: 2 sheets, revision 0',
    );
    expect(
      lines,
      contains(
        r'error: Wire odd_wire references unknown port "x\x1b[2J\x9b31m\x0aerror: forged" on -M1.',
      ),
    );
    expect(lines.where((line) => line.startsWith('error: forged')), isEmpty);

    // Machine-readable output keeps the exact text in valid JSON.
    final json = await run(['validate', hostileFile.path, '--json']);
    expect(json.stdout as String, isNot(contains(RegExp(r'[\x7f-\x9f]'))));
    final report = jsonDecode(json.stdout as String) as Map<String, dynamic>;
    expect([
      for (final diagnostic in report['diagnostics'] as List)
        (diagnostic as Map)['message'],
    ], contains('Wire odd_wire references unknown port "$port" on -M1.'));

    final commands = File('${directory.path}/commands.json');
    await commands.writeAsString(
      jsonEncode([
        const RenameProject('Nový\u009b název').toJson(),
        const RenameSheet('sheet\u001b]0;x\u0007', 'Nový').toJson(),
      ]),
    );
    for (final (input, message) in [
      (
        hostileFile,
        r'invalid_port: Wire odd_wire references unknown port "x\x1b[2J\x9b31m\x0aerror: forged" on -M1.',
      ),
      (projectFile, r'missing_sheet: Sheet sheet\x1b]0;x\x07 does not exist.'),
    ]) {
      final rejected = await run(['apply', input.path, commands.path, '-']);
      expect(rejected.exitCode, 2);
      expect(rejected.stderr, '$message\n');
    }
    await commands.writeAsString(
      jsonEncode([const RenameProject('Nový\u009b název').toJson()]),
    );
    final applied = await run(['apply', projectFile.path, commands.path, '-']);
    expect(applied.exitCode, 0, reason: applied.stderr.toString());
    expect(applied.stdout as String, isNot(contains(RegExp(r'[\x7f-\x9f]'))));
    expect(
      EcadProject.fromJson(jsonDecode(applied.stdout as String)).name,
      'Nový\u009b název',
    );
  });

  test(
    'stdin input is read completely and stays within the size limit',
    () async {
      Future<(int, String, String)> pipe(
        List<String> args,
        Stream<List<int>> input,
      ) async {
        final process = await Process.start(Platform.resolvedExecutable, [
          'run',
          'bin/open_ecad.dart',
          ...args,
        ], workingDirectory: Directory.current.path);
        final output = process.stdout.transform(utf8.decoder).join();
        final errors = process.stderr.transform(utf8.decoder).join();
        process.stdin.done.ignore();
        try {
          await process.stdin.addStream(input);
          await process.stdin.close();
        } on Object {
          // Oversized input is rejected before it has all been written.
        }
        return (await process.exitCode, await output, await errors);
      }

      final project = await projectFile.readAsBytes();
      final validated = await pipe(['validate', '-'], Stream.value(project));
      expect(validated.$1, 0, reason: validated.$3);
      expect(
        validated.$2,
        startsWith('${DemoProject.create().name}: 2 sheets'),
      );

      final commands = File('${directory.path}/commands.json');
      await commands.writeAsString(
        jsonEncode([const RenameProject('Ze vstupu').toJson()]),
      );
      final output = File('${directory.path}/from_stdin.ecad.json');
      // Chunked input exercises the buffering across reads.
      final applied = await pipe(
        ['apply', '-', commands.path, output.path],
        Stream.fromIterable([
          for (var i = 0; i < project.length; i += 1000)
            project.sublist(i, i + 1000 < project.length ? i + 1000 : null),
        ]),
      );
      expect(applied.$1, 0, reason: applied.$3);
      final saved = EcadProject.fromJson(
        jsonDecode(await output.readAsString()),
      );
      expect((saved.name, saved.revision), ('Ze vstupu', 1));

      final megabyte = Uint8List(1 << 20)..fillRange(0, 1 << 20, 0x20);
      final oversized = await pipe(
        ['validate', '-'],
        Stream.fromIterable(
          List.filled(
            ProjectLimits.maxFileBytes ~/ megabyte.length + 1,
            megabyte,
          ),
        ),
      );
      expect(oversized.$1, 2);
      expect(oversized.$3, contains('limit_exceeded'));
    },
  );

  test('saving through symbolic links replaces the final target', () async {
    final store = await Directory('${directory.path}/store').create();
    final target = await projectFile.copy('${store.path}/project.ecad.json');
    final current = Link('${directory.path}/current.ecad.json')
      ..createSync('store/project.ecad.json');
    final alias = Link('${directory.path}/alias.ecad.json')
      ..createSync('current.ecad.json');
    final commands = File('${directory.path}/commands.json');
    await commands.writeAsString(
      jsonEncode([const RenameProject('Přes odkaz').toJson()]),
    );
    final result = await run(['apply', alias.path, commands.path, alias.path]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(alias.targetSync(), 'current.ecad.json');
    expect(current.targetSync(), 'store/project.ecad.json');
    final saved = EcadProject.fromJson(jsonDecode(await target.readAsString()));
    expect((saved.name, saved.revision), ('Přes odkaz', 1));
    expect(
      directory.listSync(recursive: true).map((entity) => entity.path),
      everyElement(isNot(endsWith('.tmp'))),
    );
  }, skip: Platform.isWindows ? _linkSkip : false);

  test('a symbolic link without a target file is left unchanged', () async {
    final dangling = Link('${directory.path}/dangling.ecad.json')
      ..createSync('missing/project.ecad.json');
    final commands = File('${directory.path}/commands.json');
    await commands.writeAsString(
      jsonEncode([const RenameProject('Nikam').toJson()]),
    );
    final result = await run([
      'apply',
      projectFile.path,
      commands.path,
      dangling.path,
    ]);
    expect(result.exitCode, 2);
    expect(result.stderr, contains('file_error'));
    expect(
      FileSystemEntity.typeSync(dangling.path, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(dangling.targetSync(), 'missing/project.ecad.json');
    expect(Directory('${directory.path}/missing').existsSync(), isFalse);
    expect(
      directory.listSync(recursive: true).map((entity) => entity.path),
      everyElement(isNot(endsWith('.tmp'))),
    );
  }, skip: Platform.isWindows ? _linkSkip : false);

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
