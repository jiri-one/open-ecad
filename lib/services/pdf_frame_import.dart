// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';

typedef PdfImportReview = Future<EcadProject?> Function(PdfImportReviewRequest);

class PdfImportReviewRequest {
  PdfImportReviewRequest({
    required this.project,
    required this.isCurrent,
    List<String> warnings = const [],
    List<FrameTemplate> reusableTemplates = const [],
  }) : warnings = List.unmodifiable(warnings),
       reusableTemplates = List.unmodifiable(reusableTemplates);

  final EcadProject project;
  final List<String> warnings;
  final List<FrameTemplate> reusableTemplates;
  final bool Function() isCurrent;
}

class PdfImportTemplate {
  const PdfImportTemplate(this.definition, this.label);
  final FrameTemplate definition;
  final String label;
}

class PdfImportPageChoice {
  bool replace = false;
  String? templateId;
  Set<String> _removed = {};
  final List<Set<String>> _history = [];

  Set<String> get removedIds => Set.unmodifiable(_removed);
  bool get canUndo => _history.isNotEmpty;

  void _select(Set<String> ids) {
    _history.add(_removed);
    _removed = ids;
  }

  void undoSelection() {
    if (_history.isNotEmpty) _removed = _history.removeLast();
  }

  void clearSelection() {
    if (_removed.isNotEmpty) _select({});
  }
}

class PdfFrameImportDraft {
  PdfFrameImportDraft(
    this.source, {
    List<FrameTemplate> reusableTemplates = const [],
  }) {
    templates.addAll([
      for (final definition in source.frameTemplates)
        PdfImportTemplate(definition, 'Import · ${definition.name}'),
      for (final definition in reusableTemplates)
        PdfImportTemplate(
          definition.copyWith(id: newId('frame')),
          'Aktuální projekt · ${definition.name}',
        ),
    ]);
    if (source.defaultFrame.mode == FrameMode.template) {
      _defaultFrame = source.defaultFrame;
    } else {
      final definition = FrameTemplates.builtin.copyWith(id: newId('frame'));
      templates.add(PdfImportTemplate(definition, definition.name));
      _defaultFrame = FrameChoice.template(definition.id);
    }
    for (final sheet in source.pages) {
      _choices[sheet.id] =
          PdfImportPageChoice()..templateId = _defaultFrame.templateId;
    }
  }

  final EcadProject source;
  final List<PdfImportTemplate> templates = [];
  final Map<String, PdfImportPageChoice> _choices = {};
  late final FrameChoice _defaultFrame;

  PdfImportPageChoice choice(String sheetId) => _choices[sheetId]!;

  void toggleRemoved(String sheetId, String graphicId) {
    final sheet = source.sheetById(sheetId)!;
    if (sheet.graphicById(graphicId) == null) {
      throw const FormatException(
        'Vybraný objekt na původní straně neexistuje.',
      );
    }
    final page = choice(sheetId);
    final ids = {...page._removed};
    if (!ids.remove(graphicId)) ids.add(graphicId);
    page._select(ids);
  }

  void resetPage(String sheetId) {
    _choices[sheetId] =
        PdfImportPageChoice()..templateId = _defaultFrame.templateId;
  }

  Sheet previewPage(String sheetId) {
    final original = source.sheetById(sheetId)!;
    final page = choice(sheetId);
    if (!page.replace) {
      return original.frame.mode == FrameMode.none
          ? original
          : original.copyWith(frame: const FrameChoice.none());
    }
    if (original.sourcePage == null) {
      throw const FormatException(
        'Přizpůsobit lze pouze nově převedenou stranu PDF.',
      );
    }
    final template =
        templates.where((t) => t.definition.id == page.templateId).firstOrNull;
    if (template == null) {
      throw const FormatException('Vyberte šablonu rámečku.');
    }
    final target = original.copyWith(
      frame: FrameChoice.template(template.definition.id),
    );
    final geometry = layoutFrameGeometry(
      target.paperSizeMm,
      ResolvedFrame(template.definition),
    );
    return target.copyWith(
      graphics: fitGraphicsToFrame(
        original,
        target,
        geometry,
        retainedGraphicIds: {
          for (final graphic in original.graphics)
            if (!page._removed.contains(graphic.id)) graphic.id,
        },
      ),
    );
  }

  EcadProject previewProject() {
    final used = {
      _defaultFrame.templateId,
      for (final page in _choices.values)
        if (page.replace) page.templateId,
    };
    final existing = source.frameTemplates.map((t) => t.id).toSet();
    final result = source.copyWith(
      pages: [for (final page in source.pages) previewPage(page.id)],
      defaultFrame: _defaultFrame,
      frameTemplates: [
        ...source.frameTemplates,
        for (final template in templates)
          if (used.contains(template.definition.id) &&
              !existing.contains(template.definition.id))
            template.definition,
      ],
    );
    requireValidProject(result);
    return result;
  }
}
