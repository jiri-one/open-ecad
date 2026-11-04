// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:ecad_core/ecad_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import 'pdf_import.dart';
import 'pdf_frame_import.dart';
import 'project_persistence.dart';

EcadProject _decodeImportedProject(String source) =>
    ProjectPersistence().decode(source);

typedef _ImportedPdf = ({EcadProject? project, List<String> warnings});

class ProjectImportService {
  List<String> warnings = const [];
  Future<void>? _conversion;

  ProjectImportService get source => this;

  ProjectImportService reviewNextImport(
    PdfImportReview review, {
    required bool Function() isCurrent,
    List<FrameTemplate> reusableTemplates = const [],
  }) => _ReviewedProjectImportService(source, () async {
    final converted = await source._importWithWarnings(isCurrent);
    if (converted.project == null || !isCurrent()) {
      return (project: null, warnings: converted.warnings);
    }
    final accepted = await review(
      PdfImportReviewRequest(
        project: converted.project!,
        warnings: converted.warnings,
        reusableTemplates: reusableTemplates,
        isCurrent: isCurrent,
      ),
    );
    return (
      project: isCurrent() ? accepted : null,
      warnings: converted.warnings,
    );
  });

  Future<_ImportedPdf> _importWithWarnings(bool Function() isCurrent) async {
    final previous = _conversion;
    final done = Completer<void>();
    _conversion = done.future;
    try {
      if (previous != null) await previous;
      if (!isCurrent()) return (project: null, warnings: const <String>[]);
      // Shared importers must not mix one conversion's warnings with another.
      final project = await importPdf();
      return (project: project, warnings: List<String>.unmodifiable(warnings));
    } finally {
      done.complete();
      if (identical(_conversion, done.future)) _conversion = null;
    }
  }

  Future<EcadProject?> importPdf() async {
    warnings = const [];
    if (kIsWeb) {
      final converted = await convertPdfToProject('');
      warnings = converted.warnings;
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

class _ReviewedProjectImportService extends ProjectImportService {
  _ReviewedProjectImportService(this.source, this._review);

  @override
  final ProjectImportService source;
  Future<_ImportedPdf> Function()? _review;

  @override
  Future<EcadProject?> importPdf() async {
    final review = _review;
    _review = null;
    final result =
        await (review?.call() ?? source._importWithWarnings(() => true));
    warnings = result.warnings;
    return result.project;
  }
}
