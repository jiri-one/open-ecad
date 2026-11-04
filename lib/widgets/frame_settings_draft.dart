// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';

import '../app/controller.dart';

class FrameEditGuard {
  FrameEditGuard(this.app, {this.sheetId})
    : generation = app.documentGeneration,
      sessionId = app.documentSessionId,
      project = app.project;

  final EditorController app;
  final int generation;
  final String sessionId;
  final String? sheetId;
  final EcadProject project;

  bool get current =>
      app.isDocumentCurrent(generation) &&
      app.documentSessionId == sessionId &&
      app.project.id == project.id &&
      app.project.revision == project.revision &&
      identical(app.project, project) &&
      (sheetId == null || app.project.sheetById(sheetId!) != null);

  static const staleMessage =
      'Projekt nebo list se mezitím změnil. Zavřete dialog a otevřete nastavení znovu.';
}

class FrameSettingsDraft {
  FrameSettingsDraft(this.original, {this.sheetId})
    : templates = [...original.frameTemplates],
      choice =
          sheetId == null
              ? original.defaultFrame
              : original.sheetById(sheetId)!.frame,
      fields = Map.of(
        sheetId == null
            ? original.documentFields
            : original.sheetById(sheetId)!.documentFields,
      );

  final EcadProject original;
  final String? sheetId;
  final List<FrameTemplate> templates;
  FrameChoice choice;
  final Map<String, String> fields;

  EcadProject get project => original.copyWith(
    frameTemplates: templates,
    defaultFrame: sheetId == null ? choice : original.defaultFrame,
    documentFields: sheetId == null ? fields : original.documentFields,
    pages: [
      for (final sheet in original.pages)
        if (sheet.id == sheetId)
          sheet.copyWith(frame: choice, documentFields: fields)
        else
          sheet,
    ],
  );

  FrameTemplate? get selectedTemplate {
    final selection =
        choice.mode == FrameMode.inherit ? original.defaultFrame : choice;
    return templates.where((t) => t.id == selection.templateId).firstOrNull;
  }

  int uses(String id) {
    final candidate = project;
    return candidate.pages
        .where(
          (s) =>
              (s.frame.mode == FrameMode.inherit
                      ? candidate.defaultFrame
                      : s.frame)
                  .templateId ==
              id,
        )
        .length;
  }

  void replace(FrameTemplate template) {
    templates[templates.indexWhere((t) => t.id == template.id)] = template;
  }

  FrameTemplate copyForSelection(FrameTemplate source) {
    final inherited = choice.mode == FrameMode.inherit;
    final defaults = original.defaultFrame;
    final copy = source.copyWith(
      id: newId('frame'),
      name: '${frameTemplateName(source)} – kopie',
    );
    templates.add(copy);
    choice = FrameChoice.template(
      copy.id,
      border: choice.border ?? (inherited ? defaults.border : null) ?? true,
      titleBlock:
          choice.titleBlock ?? (inherited ? defaults.titleBlock : null) ?? true,
      zones: choice.zones ?? (inherited ? defaults.zones : null) ?? true,
    );
    return copy;
  }

  void delete(String id) {
    final candidate = project;
    if (candidate.defaultFrame.templateId == id ||
        candidate.pages.any((s) => s.frame.templateId == id)) {
      throw const FormatException(
        'Šablona je používána. Nejprve změňte výchozí rámeček projektu a všechny listy s touto šablonou.',
      );
    }
    templates.removeWhere((t) => t.id == id);
  }

  List<EcadCommand> commands() {
    bool differs(Object a, Object b) => jsonEncode(a) != jsonEncode(b);
    return [
      for (final template in templates)
        if (original.frameTemplateById(template.id) == null)
          AddFrameTemplate(template)
        else if (differs(
          original.frameTemplateById(template.id)!.toJson(),
          template.toJson(),
        ))
          UpdateFrameTemplate(template),
      for (final template in original.frameTemplates)
        if (!templates.any((t) => t.id == template.id))
          DeleteFrameTemplate(template.id),
      if (sheetId == null) ...[
        if (differs(choice.toJson(), original.defaultFrame.toJson()))
          SetProjectFrame(choice),
        if (differs(fields, original.documentFields))
          SetProjectDocumentFields(fields),
      ] else ...[
        if (differs(
          choice.toJson(),
          original.sheetById(sheetId!)!.frame.toJson(),
        ))
          SetSheetFrame(sheetId!, choice),
        if (differs(fields, original.sheetById(sheetId!)!.documentFields))
          SetSheetDocumentFields(sheetId!, fields),
      ],
    ];
  }
}

String frameTemplateName(FrameTemplate template) =>
    template.id == FrameTemplates.builtinId && template.name == 'Generic'
        ? 'Základní rámeček'
        : template.name;

const frameDocumentLabels = <String, String>{
  'documentNumber': 'Číslo dokumentu',
  'drawingRevision': 'Revize výkresu',
  'issueDate': 'Datum vydání',
  'drawnBy': 'Kreslil',
  'checkedBy': 'Kontroloval',
  'approvedBy': 'Schválil',
  'company': 'Firma',
  'customer': 'Zákazník',
};

String frameError(Object error) {
  if (error is FormatException) return error.message;
  if (error is EcadException) {
    return switch (error.code) {
      'invalid_frame_binding' =>
        'Neplatná vazba v textu. Použijte nabídku údajů a dvojité složené závorky.',
      'invalid_frame_layout' =>
        'Rámeček se nevejde na papír. Zkontrolujte okraje a rozměry razítka.',
      'invalid_frame_template' =>
        'Neplatná šablona. Zkontrolujte rozměry, oddělovače a pole uvnitř razítka.',
      'invalid_document_fields' =>
        'Neplatné údaje dokumentu. Klíče musí začínat písmenem a obsahovat jen písmena bez diakritiky, číslice nebo podtržítko.',
      'limit_exceeded' => 'Překročen povolený počet položek nebo délka textu.',
      _ =>
        'Nastavení nelze použít. Zkontrolujte hodnoty a odkazy na šablony (${error.code}).',
    };
  }
  return 'Operace se nezdařila: $error';
}
