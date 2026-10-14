// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:ecad_core/ecad_core.dart';
import 'pdf_conversion.dart';

/// Optional, local converter. No PDF scripts or remote services are executed.
Future<PdfConversion> convertPdfToProject(String path) async {
  final script = _findConverter();
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
      Platform.environment['ECAD_PDF_PYTHON'] ??
      (localPython.existsSync()
          ? localPython.path
          : (Platform.isWindows ? 'python' : 'python3'));
  final temporary = await Directory.systemTemp.createTemp('open-ecad-pdf-');
  try {
    final output = File('${temporary.path}/import.oecad');
    final report = File('${temporary.path}/report.json');
    final process = await Process.start(python, [
      '-I',
      script.path,
      path,
      output.path,
      '--report',
      report.path,
    ], runInShell: false);
    final stdoutDone = process.stdout.drain<void>();
    final stderrDone = process.stderr.transform(utf8.decoder).join();
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
      final detail = error.trim();
      throw FormatException(
        'Převod PDF selhal. ${detail.length > 2000 ? detail.substring(0, 2000) : detail}',
      );
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
    return PdfConversion(await output.readAsString(), warnings: warnings);
  } on ProcessException {
    throw const FormatException(
      'Python pro převod PDF není dostupný. Postup instalace je v docs/pdf-import.md.',
    );
  } finally {
    await temporary.delete(recursive: true);
  }
}

File? _findConverter() {
  final configured = Platform.environment['ECAD_PDF_IMPORTER'];
  if (configured != null) {
    final file = File(configured);
    return file.existsSync() ? file : null;
  }
  for (final start in [
    Directory.current,
    File(Platform.resolvedExecutable).parent,
  ]) {
    var directory = start;
    for (var depth = 0; depth < 8; depth++) {
      final script = File('${directory.path}/scripts/import_pdf.py');
      if (script.existsSync()) return script;
      if (directory.parent.path == directory.path) break;
      directory = directory.parent;
    }
  }
  return null;
}
