// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/foundation.dart';

import 'pdf_conversion.dart';

/// Optional, local converter. No PDF scripts or remote services are executed.
Future<PdfConversion> convertPdfToProject(
  String path, {
  @visibleForTesting Map<String, String>? environment,
}) async {
  final settings = environment ?? Platform.environment;
  final script = findPdfConverter(
    environment: settings,
    executable: Platform.resolvedExecutable,
    currentDirectory: Directory.current.path,
    development: !kReleaseMode,
  );
  if (script == null) {
    throw const FormatException(
      'Převodník PDF není nainstalovaný. Postup instalace je v docs/pdf-import.md.',
    );
  }
  final root = script.parent.parent;
  final localPython = File(
    '${root.path}/.venv-pdf/${Platform.isWindows ? 'Scripts/python.exe' : 'bin/python'}',
  );
  final python =
      settings['ECAD_PDF_PYTHON'] ??
      (localPython.existsSync()
          ? localPython.path
          : (Platform.isWindows ? 'python' : 'python3'));
  final temporary = await Directory.systemTemp.createTemp('open-ecad-pdf-');
  try {
    final output = File('${temporary.path}/import.oecad');
    final report = File('${temporary.path}/report.json');
    // UTF-8 mode keeps messages readable under legacy Windows code pages;
    // -I alone would ignore PYTHONUTF8.
    final process = await Process.start(python, [
      '-X',
      'utf8',
      '-I',
      script.path,
      path,
      output.path,
      '--report',
      report.path,
    ], runInShell: false);
    final stdoutDone = process.stdout.drain<void>();
    final stderrDone = converterErrorText(process.stderr);
    final exitCode = await process.exitCode.timeout(
      const Duration(minutes: 10),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        throw const FormatException('Převod PDF překročil časový limit.');
      },
    );
    await stdoutDone;
    final error = await stderrDone;
    if (exitCode != 0) {
      throw FormatException('Převod PDF selhal. $error');
    }
    if (!await output.exists() ||
        await output.length() > ProjectLimits.maxFileBytes) {
      throw const FormatException(
        'Převodník nevytvořil projekt v povolené velikosti.',
      );
    }
    final metadata =
        jsonDecode(await report.readAsString()) as Map<String, dynamic>;
    final warnings =
        (metadata['warnings'] as List<dynamic>).map((dynamic value) {
          final warning = value as Map<String, dynamic>;
          if (warning['code'] == 'fontSubstitution') {
            return 'Písmo ze zdrojového PDF je nahrazené písmem Noto Sans. Zkontrolujte vzhled textů.';
          }
          return '${warning['message']} (${warning['count']})';
        }).toList();
    final typeNote = sheetTypeImportNote(metadata['sheetTypes']);
    return PdfConversion(
      await output.readAsString(),
      warnings: [...warnings, if (typeNote != null) typeNote],
    );
  } on ProcessException {
    throw const FormatException(
      'Python pro převod PDF není dostupný. Postup instalace je v docs/pdf-import.md.',
    );
  } finally {
    await temporary.delete(recursive: true);
  }
}

/// A configured path is used as given. Otherwise only the application's own
/// directory is trusted, plus the exact working directory of a development
/// run; parents of an unrelated working directory are never searched.
@visibleForTesting
File? findPdfConverter({
  required Map<String, String> environment,
  required String executable,
  required String currentDirectory,
  required bool development,
}) {
  final configured = environment['ECAD_PDF_IMPORTER'];
  if (configured != null) {
    final file = File(configured);
    return file.existsSync() ? file : null;
  }
  for (final directory in [
    File(executable).parent.path,
    if (development) currentDirectory,
  ]) {
    final script = File('$directory/scripts/import_pdf.py');
    if (script.existsSync()) return script;
  }
  return null;
}

/// The converter prints its own error last, after any library warnings, so
/// the tail is kept. Undecodable bytes must not hide that message.
@visibleForTesting
Future<String> converterErrorText(Stream<List<int>> stderr) async {
  const limit = 2000;
  var text = '';
  var truncated = false;
  await for (final chunk in stderr.transform(
    const Utf8Decoder(allowMalformed: true),
  )) {
    text += chunk;
    if (text.length > limit) {
      text = text.substring(text.length - limit);
      truncated = true;
    }
  }
  text = text.trim();
  return truncated ? '…$text' : text;
}
