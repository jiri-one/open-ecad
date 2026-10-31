import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import '../app/controller.dart';
import 'inventory.dart';
import 'structure_fields.dart';

export 'continuation_editor.dart' show editContinuation;

Future<void> editSheetSettings(
  BuildContext context,
  EditorController app,
) async {
  final sheet = app.sheet;
  final generation = app.documentGeneration;
  final structure = StructureFieldsController(sheet.structure);
  final fields = {
    for (final e
        in {
          'Název listu': sheet.name,
          'Číslo listu': sheet.number,
          'Kód dokumentu (&)': sheet.documentCode,
          'Nadpis reportu': sheet.report?.title ?? '',
          'Poznámka reportu': sheet.report?.note ?? '',
        }.entries)
      e.key: TextEditingController(text: e.value),
  };
  var reportKind = sheet.report?.kind ?? BomReportKind.articles;
  var paper = sheet.paperSizeMm;
  String? error;
  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, refresh) => editorDialog(
                ctx,
                title: 'Vlastnosti listu',
                error: error,
                children: [
                  formField('Název listu', fields['Název listu']!),
                  formField('Číslo listu', fields['Číslo listu']!),
                  StructureFields(controller: structure),
                  formField('Kód dokumentu (&)', fields['Kód dokumentu (&)']!),
                  ListenableBuilder(
                    listenable: Listenable.merge([structure, ...fields.values]),
                    builder:
                        (_, _) => Text(
                          fullPageDesignation(
                            sheet.copyWith(
                              structure: structure.value,
                              documentCode:
                                  fields['Kód dokumentu (&)']!.text.trim(),
                              number: fields['Číslo listu']!.text.trim(),
                            ),
                          ),
                        ),
                  ),
                  const Text(
                    'Změna struktury listu nepřejmenuje existující fyzické přístroje.',
                  ),
                  DropdownButtonFormField<String>(
                    initialValue:
                        paper.width == SizeMm.a4Landscape.width ? 'a4' : 'a3',
                    decoration: const InputDecoration(labelText: 'Papír'),
                    items: const [
                      DropdownMenuItem(value: 'a3', child: Text('A3 na šířku')),
                      DropdownMenuItem(value: 'a4', child: Text('A4 na šířku')),
                    ],
                    onChanged:
                        (v) =>
                            paper =
                                v == 'a3'
                                    ? SizeMm.a3Landscape
                                    : SizeMm.a4Landscape,
                  ),
                  if (sheet.type == SheetType.billOfMaterials) ...[
                    DropdownButtonFormField<BomReportKind>(
                      initialValue: reportKind,
                      decoration: const InputDecoration(
                        labelText: 'Obsah reportu',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: BomReportKind.articles,
                          child: Text('Kusovník podle artiklů'),
                        ),
                        DropdownMenuItem(
                          value: BomReportKind.components,
                          child: Text('Seznam komponent a výskytů'),
                        ),
                      ],
                      onChanged: (v) => reportKind = v!,
                    ),
                    formField('Nadpis reportu', fields['Nadpis reportu']!),
                    formField('Poznámka reportu', fields['Poznámka reportu']!),
                  ],
                ],
                save: () {
                  if (!app.isDocumentCurrent(generation) ||
                      app.project.sheetById(sheet.id) == null) {
                    refresh(() => error = 'Původní list již není otevřen.');
                    return;
                  }
                  if (app.updateSheet(
                    app.project
                        .sheetById(sheet.id)!
                        .copyWith(
                          structure: structure.value,
                          documentCode:
                              fields['Kód dokumentu (&)']!.text.trim(),
                          name: fields['Název listu']!.text.trim(),
                          number: fields['Číslo listu']!.text.trim(),
                          paperSizeMm: paper,
                          report:
                              sheet.type == SheetType.billOfMaterials
                                  ? BomTableSpec(
                                    kind: reportKind,
                                    title:
                                        fields['Nadpis reportu']!.text.trim(),
                                    note:
                                        fields['Poznámka reportu']!.text.trim(),
                                  )
                                  : null,
                        ),
                  )) {
                    Navigator.pop(ctx);
                  } else {
                    refresh(() => error = app.status);
                  }
                },
              ),
        ),
  );
  Future<void>.delayed(const Duration(milliseconds: 400), () {
    structure.dispose();
    for (final f in fields.values) {
      f.dispose();
    }
  });
}

Future<void> editMountingView(
  BuildContext context,
  EditorController app,
) async {
  final view = app.sheet.mountingView;
  String? layoutId = view?.layoutId;
  final fields = {
    for (final e
        in {
          'Šířka plochy mm': decimal(app.activeLayout?.widthMm),
          'Výška plochy mm': decimal(app.activeLayout?.heightMm),
          'Měřítko 1 :': decimal(view?.scaleDenominator ?? 5),
          'Počátek X mm': decimal(view?.originMm.x ?? 0),
          'Počátek Y mm': decimal(view?.originMm.y ?? 0),
          'Okno X': decimal(view?.viewport.x ?? 65),
          'Okno Y': decimal(view?.viewport.y ?? 120),
          'Okno šířka': decimal(view?.viewport.width ?? 950),
          'Okno výška': decimal(view?.viewport.height ?? 520),
        }.entries)
      e.key: TextEditingController(text: e.value),
  };
  bool surfaceDimensions = view?.showSurfaceDimensions ?? true,
      componentDimensions = view?.showComponentDimensions ?? false;
  double n(String key) => double.parse(fields[key]!.text.replaceAll(',', '.'));
  String? error;
  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, refresh) => editorDialog(
                ctx,
                title: 'Montážní pohled v mm',
                error: error,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: layoutId ?? '',
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Sdílená montážní plocha',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Nová plocha'),
                      ),
                      for (final l in app.project.mountingLayouts)
                        DropdownMenuItem(value: l.id, child: Text(l.name)),
                    ],
                    onChanged:
                        (v) => refresh(() {
                          layoutId = optionalText(v!);
                          final l = app.project.mountingLayoutById(v);
                          fields['Šířka plochy mm']!.text = decimal(l?.widthMm);
                          fields['Výška plochy mm']!.text = decimal(
                            l?.heightMm,
                          );
                        }),
                  ),
                  for (final f in fields.entries) formField(f.key, f.value),
                  CheckboxListTile(
                    value: surfaceDimensions,
                    onChanged: (v) => refresh(() => surfaceDimensions = v!),
                    title: const Text('Rozměry montážní plochy'),
                  ),
                  CheckboxListTile(
                    value: componentDimensions,
                    onChanged: (v) => refresh(() => componentDimensions = v!),
                    title: const Text('Rozměry komponent'),
                  ),
                  const Text(
                    'Další pohled stejné plochy sdílí polohy v mm. Měřítko ani posun pohledu nemění skutečné rozměry.',
                  ),
                ],
                save: () {
                  try {
                    if (app.configureMounting(
                      layout: app.project.mountingLayoutById(layoutId ?? ''),
                      width: n('Šířka plochy mm'),
                      height: n('Výška plochy mm'),
                      scale: n('Měřítko 1 :'),
                      origin: Vec2(n('Počátek X mm'), n('Počátek Y mm')),
                      viewport: RectUnits(
                        x: n('Okno X'),
                        y: n('Okno Y'),
                        width: n('Okno šířka'),
                        height: n('Okno výška'),
                      ),
                      surfaceDimensions: surfaceDimensions,
                      componentDimensions: componentDimensions,
                    )) {
                      Navigator.pop(ctx);
                    } else {
                      refresh(() => error = app.status);
                    }
                  } catch (e) {
                    refresh(() => error = '$e');
                  }
                },
              ),
        ),
  );
  Future<void>.delayed(const Duration(milliseconds: 400), () {
    for (final f in fields.values) {
      f.dispose();
    }
  });
}

Future<void> confirmDeleteSheet(
  BuildContext context,
  EditorController app,
) async {
  final sheet = app.sheet;
  final generation = app.documentGeneration;
  final yes = await showDialog<bool>(
    context: context,
    builder:
        (ctx) => AlertDialog(
          title: Text('Odstranit list ${fullPageDesignation(sheet)}?'),
          content: const Text(
            'Zobrazení a vodiče tohoto listu budou odstraněny. Fyzické komponenty i sdílená montážní plocha zůstávají v projektu. Změnu lze vrátit.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Odstranit list'),
            ),
          ],
        ),
  );
  if (yes == true &&
      app.isDocumentCurrent(generation) &&
      app.project.sheetById(sheet.id) != null) {
    app.execute([
      DeleteSheet(sheet.id),
    ], 'List odstraněn; komponenty zůstávají');
  }
}
