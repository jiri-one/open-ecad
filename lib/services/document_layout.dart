// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';

import 'report_layout.dart';

class DocumentPage {
  const DocumentPage({required this.sheet, required this.index, this.report});
  final Sheet sheet;
  final int index;
  final ReportPage? report;
  String get number => report?.number ?? fullPageDesignation(sheet);
  SizeMm get sizeMm => sheet.paperSizeMm;
}

class DocumentLayout {
  DocumentLayout(this.sourceRevision, List<DocumentPage> pages)
    : pages = List.unmodifiable(pages);
  final int sourceRevision;
  final List<DocumentPage> pages;
}

DocumentLayout layoutDocument(EcadProject project) {
  requireValidProject(project);
  final pages = <DocumentPage>[];
  for (final sheet in project.pages) {
    if (sheet.report != null) {
      for (final page in layoutReport(project, sheet).pages) {
        pages.add(
          DocumentPage(sheet: sheet, index: pages.length, report: page),
        );
      }
    } else {
      pages.add(DocumentPage(sheet: sheet, index: pages.length));
    }
  }
  return DocumentLayout(project.revision, pages);
}
