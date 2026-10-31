// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import 'pdf_import.dart';
import 'project_persistence.dart';

EcadProject _decodeImportedProject(String source) =>
    ProjectPersistence().decode(source);

class ProjectImportService {
  List<String> warnings = const [];

  Future<EcadProject?> importPdf() async {
    warnings = const [];
    if (kIsWeb) {
      final converted = await convertPdfToProject('');
      return compute(_decodeImportedProject, converted.projectJson);
    }
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'PDF',
          extensions: ['pdf'],
          mimeTypes: ['application/pdf'],
        ),
      ],
    );
    if (file == null) return null;
    if (await file.length() > ProjectLimits.maxFileBytes) {
      throw const FormatException('PDF je větší než povolených 128 MiB.');
    }
    final converted = await convertPdfToProject(file.path);
    warnings = converted.warnings;
    return compute(_decodeImportedProject, converted.projectJson);
  }
}
