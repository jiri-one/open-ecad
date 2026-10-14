// SPDX-License-Identifier: GPL-3.0-or-later
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/pdf_import_native.dart';

String? _python() {
  final command = Platform.isWindows ? 'python' : 'python3';
  try {
    return Process.runSync(command, ['-c', 'pass']).exitCode == 0
        ? command
        : null;
  } on ProcessException {
    return null;
  }
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('open-ecad-pdf-test'));
  tearDown(() => root.deleteSync(recursive: true));

  String install(String directory) =>
      (File('${root.path}/$directory/scripts/import_pdf.py')
        ..createSync(recursive: true)).path;

  File? find({
    Map<String, String> environment = const {},
    String executable = 'app/open_ecad',
    String currentDirectory = 'work',
    bool development = true,
  }) => findPdfConverter(
    environment: environment,
    executable: '${root.path}/$executable',
    currentDirectory: '${root.path}/$currentDirectory',
    development: development,
  );

  test('the application directory is preferred to the working directory', () {
    final bundled = install('app');
    install('work');
    expect(find()?.path, bundled);
    expect(find(development: false)?.path, bundled);
  });

  test('only the exact working directory of a development run is used', () {
    final source = install('work');
    expect(find()?.path, source);
    expect(find(development: false), isNull);
    expect(find(currentDirectory: 'work/nested/deeper'), isNull);
    expect(
      find(
        executable: 'work/build/bundle/open_ecad',
        currentDirectory: 'elsewhere',
      ),
      isNull,
    );
  });

  test('a configured converter path is never replaced by discovery', () {
    install('app');
    final configured = install('custom');
    expect(
      find(environment: {'ECAD_PDF_IMPORTER': configured})?.path,
      configured,
    );
    expect(
      find(
        environment: {'ECAD_PDF_IMPORTER': '${root.path}/missing/import.py'},
      ),
      isNull,
    );
  });

  test(
    'converter errors survive legacy code pages and keep the tail',
    () async {
      final legacy = await converterErrorText(
        Stream.value([0x50, 0xF8, 0x65, 0x76, 0x6F, 0x64, 0x0A]),
      );
      expect(legacy, 'P\uFFFDevod');
      final noisy = await converterErrorText(
        Stream.fromIterable([
          for (var i = 0; i < 300; i++)
            'warning: synthetic note $i\n'.codeUnits,
          'import_pdf: error: final reason\n'.codeUnits,
        ]),
      );
      expect(noisy, startsWith('…'));
      expect(noisy, endsWith('import_pdf: error: final reason'));
      expect(noisy.length, lessThanOrEqualTo(2001));
    },
  );

  final python = _python();
  test(
    'the converter runs in UTF-8 mode and its message reaches the user',
    () async {
      final script =
          File('${root.path}/fake/scripts/import_pdf.py')
            ..createSync(recursive: true)
            ..writeAsStringSync(
              'import sys\n'
              "sys.stderr.write(f'utf8_mode={sys.flags.utf8_mode}\\n')\n"
              'sys.stderr.flush()\n'
              "sys.stderr.buffer.write(b'\\xf8 legacy byte\\n')\n"
              'sys.stderr.buffer.flush()\n'
              "sys.stderr.write('import_pdf: error: Převod selhal\\n')\n"
              'sys.exit(2)\n',
            );
      await expectLater(
        convertPdfToProject(
          '${root.path}/missing.pdf',
          environment: {
            'ECAD_PDF_IMPORTER': script.path,
            'ECAD_PDF_PYTHON': python!,
          },
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('utf8_mode=1'),
              contains('\uFFFD legacy byte'),
              endsWith('import_pdf: error: Převod selhal'),
            ),
          ),
        ),
      );
    },
    skip: python == null ? 'Python is not installed' : false,
  );
}
