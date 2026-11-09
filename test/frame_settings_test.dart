// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/services/frame_template_files.dart';
import 'package:open_ecad/services/mounting_annotations.dart';
import 'package:open_ecad/widgets/frame_settings.dart';
import 'package:open_ecad/widgets/frame_settings_draft.dart';
import 'package:open_ecad/widgets/frame_template_preview.dart';
import 'package:open_ecad/widgets/sheet_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

EcadProject sample() => EcadProject(
  id: 'frames',
  name: 'Zkušební projekt',
  documentFields: {'drawnBy': 'Autor', 'company': 'Firma'},
  pages: [
    Sheet(id: 's1', name: 'První', number: '01'),
    Sheet(id: 's2', name: 'Druhý', number: '02'),
  ],
);

Future<void> mount(
  WidgetTester tester,
  EditorController app, {
  String? sheetId,
  FrameTemplateFiles files = const FrameTemplateFiles(),
  bool properties = false,
  Size size = const Size(1100, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder:
              (context) => TextButton(
                onPressed: () {
                  if (properties) {
                    editSheetSettings(context, app);
                  } else {
                    editFrameSettings(
                      context,
                      app,
                      sheetId: sheetId,
                      files: files,
                    );
                  }
                },
                child: const Text('Otevřít'),
              ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Otevřít'));
  await tester.pumpAndSettle();
}

Future<void> click(WidgetTester tester, String label) async {
  final finder = find.text(label).last;
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder dropdown(String label) => find.byWidgetPredicate(
  (w) => w is DropdownButtonFormField && w.decoration.labelText == label,
);

Future<void> select(WidgetTester tester, String label, String value) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await Scrollable.ensureVisible(
    tester.element(dropdown(label)),
    alignment: .3,
  );
  await tester.pumpAndSettle();
  await tester.tap(dropdown(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(value).last);
  await tester.pumpAndSettle();
}

void main() {
  for (final override in [false, true]) {
    test(
      'independent copy preserves inherited part switches (override=$override)',
      () {
        final p = sample().copyWith(
          defaultFrame: const FrameChoice.template(
            FrameTemplates.builtinId,
            border: false,
            titleBlock: false,
            zones: false,
          ),
          pages: [
            Sheet(
              id: 's1',
              name: 'Sheet',
              number: '1',
              frame: FrameChoice.inherit(titleBlock: override ? true : null),
            ),
          ],
        );
        final draft = FrameSettingsDraft(p, sheetId: 's1');
        final before = resolveSheetFrame(p, p.pages.single)!;
        draft.copyForSelection(draft.selectedTemplate!);
        final afterProject = draft.project;
        final after =
            resolveSheetFrame(afterProject, afterProject.pages.single)!;
        expect(
          [after.border, after.titleBlock, after.zones],
          [before.border, before.titleBlock, before.zones],
        );
        final paper = p.pages.single.paperSizeMm;
        expect(
          layoutFrameGeometry(paper, after).contentRectMm.toJson(),
          layoutFrameGeometry(paper, before).contentRectMm.toJson(),
        );
      },
    );
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'draft shared changes and independent copies commit in one undo step',
    () {
      final engine = ProjectEngine(sample());
      final draft = FrameSettingsDraft(engine.project, sheetId: 's1');
      expect(draft.commands(), isEmpty);
      final copy = draft.copyForSelection(FrameTemplates.builtin);
      draft.replace(copy.copyWith(name: 'Vlastní razítko'));
      draft.fields['drawingRevision'] = 'A';
      engine.execute(draft.commands());
      expect(engine.project.frameTemplates, hasLength(2));
      expect(
        resolveSheetFrame(
          engine.project,
          engine.project.pages.first,
        )!.template.name,
        'Vlastní razítko',
      );
      expect(
        resolveSheetFrame(
          engine.project,
          engine.project.pages.last,
        )!.template.id,
        FrameTemplates.builtinId,
      );
      expect(engine.project.revision, 1);
      engine.undo();
      expect(engine.project.frameTemplates, hasLength(1));
      expect(engine.project.pages.first.frame.mode, FrameMode.inherit);

      final shared = FrameSettingsDraft(engine.project);
      shared.replace(FrameTemplates.builtin.copyWith(name: 'Společná'));
      engine.execute(shared.commands());
      for (final sheet in engine.project.pages) {
        expect(
          resolveSheetFrame(engine.project, sheet)!.template.name,
          'Společná',
        );
      }
    },
  );

  test(
    'rejects live deletion; allows replacing default and explicit reference atomically',
    () {
      final project = sample().copyWith(
        pages: [
          sample().pages.first.copyWith(
            frame: const FrameChoice.template(FrameTemplates.builtinId),
          ),
        ],
      );
      final draft = FrameSettingsDraft(project);
      expect(
        () => draft.delete(FrameTemplates.builtinId),
        throwsFormatException,
      );
      draft.choice = const FrameChoice.none();
      expect(
        () => draft.delete(FrameTemplates.builtinId),
        throwsFormatException,
      );
      final inherited = FrameSettingsDraft(sample())
        ..choice = const FrameChoice.none();
      inherited.delete(FrameTemplates.builtinId);
      final engine = ProjectEngine(sample());
      engine.execute(inherited.commands());
      expect(engine.project.frameTemplates, isEmpty);
      expect(
        resolveSheetFrame(engine.project, engine.project.pages.first),
        isNull,
      );
    },
  );

  testWidgets(
    'project default and independent sheet part overrides save and undo',
    (tester) async {
      final app = EditorController(
        initialProject: sample().copyWith(
          defaultFrame: const FrameChoice.template(
            FrameTemplates.builtinId,
            border: false,
            titleBlock: false,
          ),
        ),
      );
      addTearDown(app.dispose);
      await mount(tester, app, sheetId: 's1');
      await select(tester, 'Obvodový rámeček', 'Zapnuto');
      await select(tester, 'Souřadnicové zóny', 'Vypnuto');
      await click(tester, 'Uložit');
      final resolved = resolveSheetFrame(app.project, app.sheet)!;
      expect(app.sheet.frame.mode, FrameMode.inherit);
      expect(app.sheet.frame.titleBlock, isNull);
      expect(resolved.border, isTrue);
      expect(resolved.titleBlock, isFalse);
      expect(resolved.zones, isFalse);
      expect(app.project.revision, 1);
      app.undo();
      expect(app.sheet.frame.border, isNull);
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets('metadata distinguishes inherited, suppressed and own text', (
    tester,
  ) async {
    final app = EditorController(initialProject: sample());
    addTearDown(app.dispose);
    await mount(tester, app, sheetId: 's1');
    await click(tester, 'Údaje');
    await select(tester, 'Kreslil', 'Potlačit (prázdný text)');
    await select(tester, 'Revize výkresu', 'Vlastní hodnota');
    final row = find.byKey(const ValueKey('document-drawingRevision'));
    await tester.enterText(
      find.descendant(of: row, matching: find.byType(TextField)),
      'B',
    );
    await click(tester, 'Uložit');
    expect(app.sheet.documentFields, {'drawnBy': '', 'drawingRevision': 'B'});
    expect(app.sheet.documentFields.containsKey('company'), isFalse);
    expect(app.project.documentFields['drawnBy'], 'Autor');
    await tester.tap(find.text('Otevřít'));
    await tester.pumpAndSettle();
    await click(tester, 'Údaje');
    await select(tester, 'Kreslil', 'Z projektu');
    await click(tester, 'Uložit');
    expect(app.sheet.documentFields.containsKey('drawnBy'), isFalse);
  });

  testWidgets(
    'cancel drops independent copy; save applies it only to target sheet',
    (tester) async {
      final app = EditorController(initialProject: sample());
      addTearDown(app.dispose);
      await mount(tester, app, sheetId: 's1');
      await click(tester, 'Vytvořit a použít samostatnou kopii');
      expect(app.project.frameTemplates, hasLength(1));
      await click(tester, 'Zrušit');
      expect(app.project.revision, 0);
      await tester.tap(find.text('Otevřít'));
      await tester.pumpAndSettle();
      await click(tester, 'Vytvořit a použít samostatnou kopii');
      await click(tester, 'Uložit');
      expect(app.project.frameTemplates, hasLength(2));
      expect(app.sheet.frame.templateId, isNot(FrameTemplates.builtinId));
      expect(app.project.pages.last.frame.mode, FrameMode.inherit);
    },
  );

  testWidgets('used template deletion shows explanation and does not mutate', (
    tester,
  ) async {
    final app = EditorController(initialProject: sample());
    addTearDown(app.dispose);
    await mount(tester, app);
    await click(tester, 'Šablony');
    await click(tester, 'Odstranit');
    expect(find.textContaining('Šablona je používána.'), findsOneWidget);
    expect(app.project.frameTemplates, hasLength(1));
    await click(tester, 'Zrušit');
    expect(app.project.revision, 0);
  });

  for (final replace in [false, true]) {
    testWidgets(
      'stale ${replace ? 'document' : 'revision'} cannot receive dialog edits',
      (tester) async {
        final app = EditorController(initialProject: sample());
        addTearDown(app.dispose);
        await mount(tester, app, sheetId: 's1');
        await select(tester, 'Rámeček listu', 'Bez rámečku');
        if (replace) {
          app.newProject();
        } else {
          app.execute([
            SetProjectDocumentFields({'drawnBy': 'Jiný'}),
          ], 'Úprava');
        }
        final after = app.project;
        await click(tester, 'Uložit');
        expect(find.text(FrameEditGuard.staleMessage), findsOneWidget);
        expect(app.project, same(after));
        await click(tester, 'Zrušit');
      },
    );
  }

  testWidgets('pending import is rejected after document replacement', (
    tester,
  ) async {
    final pending = Completer<String?>();
    final app = EditorController(initialProject: sample());
    addTearDown(app.dispose);
    await mount(
      tester,
      app,
      files: FrameTemplateFiles(read: () => pending.future),
    );
    await click(tester, 'Šablony');
    await click(tester, 'Importovat definici…');
    app.newProject();
    final after = app.project;
    pending.complete(FrameTemplateCodec.encode(FrameTemplates.builtin));
    await tester.pumpAndSettle();
    expect(find.textContaining('Projekt se mezitím změnil.'), findsOneWidget);
    expect(app.project, same(after));
    await click(tester, 'Zrušit');
  });

  testWidgets(
    'file import stays a draft and export contains the imported definition',
    (tester) async {
      String? exported;
      final files = FrameTemplateFiles(
        read:
            () async => FrameTemplateCodec.encode(
              FrameTemplates.builtin.copyWith(name: 'Přenositelná'),
            ),
        write: (source, name, canCommit) async {
          expect(canCommit(), isTrue);
          exported = source;
          return name;
        },
      );
      final app = EditorController(initialProject: sample());
      addTearDown(app.dispose);
      await mount(tester, app, files: files);
      await click(tester, 'Šablony');
      await click(tester, 'Importovat definici…');
      expect(app.project.frameTemplates, hasLength(1));
      await click(tester, 'Exportovat definici…');
      final definition = FrameTemplateCodec.decode(exported!);
      expect(definition.id, isNot(FrameTemplates.builtinId));
      expect(definition.name, 'Přenositelná');
      await click(tester, 'Uložit');
      expect(app.project.frameTemplates.last.toJson(), definition.toJson());
    },
  );

  testWidgets('sheet properties and nested frame edits are one atomic draft', (
    tester,
  ) async {
    final app = EditorController(initialProject: sample());
    addTearDown(app.dispose);
    await mount(tester, app, properties: true);
    final title = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Název listu',
    );
    await tester.enterText(title, 'Změněný list');
    await select(tester, 'Papír', 'A4 na šířku');
    await click(tester, 'Rámeček a údaje listu…');
    final preview = tester.widget<FrameTemplatePreview>(
      find.byType(FrameTemplatePreview),
    );
    expect(preview.frame.source.geometry.paperRectMm.width, 297);
    expect(
      preview.frame.source.texts.firstWhere((f) => f.id == 'sheet').text,
      'Změněný list',
    );
    await select(tester, 'Rámeček listu', 'Bez rámečku');
    await click(tester, 'Použít v návrhu');
    expect(app.project.revision, 0);
    await click(tester, 'Uložit');
    expect(app.project.revision, 1);
    expect(app.sheet.frame.mode, FrameMode.none);
    expect(app.sheet.name, 'Změněný list');
    app.undo();
    expect(app.sheet.frame.mode, FrameMode.inherit);
    expect(app.sheet.name, 'První');
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('settings remain usable at 900 by 600', (tester) async {
    final app = EditorController(initialProject: sample());
    addTearDown(app.dispose);
    await mount(tester, app, size: const Size(900, 600));
    for (final tab in ['Údaje', 'Šablony', 'Výběr rámečku']) {
      await click(tester, tab);
      expect(tester.takeException(), isNull);
      expect(find.text('Uložit').hitTestable(), findsOneWidget);
      expect(find.text('Zrušit').hitTestable(), findsOneWidget);
    }
    await click(tester, 'Zrušit');
  });
  testWidgets(
    'project default none releases inherited sheets but preserves explicit choices',
    (tester) async {
      final p = sample();
      final app = EditorController(
        initialProject: p.copyWith(
          pages: [
            p.pages.first,
            p.pages.last.copyWith(
              frame: const FrameChoice.template(FrameTemplates.builtinId),
            ),
          ],
        ),
      );
      addTearDown(app.dispose);
      await mount(tester, app);
      await select(tester, 'Výchozí rámeček projektu', 'Bez rámečku');
      await click(tester, 'Uložit');
      expect(resolveSheetFrame(app.project, app.project.pages.first), isNull);
      expect(resolveSheetFrame(app.project, app.project.pages.last), isNotNull);
    },
  );

  testWidgets(
    'nested Cancel and outer Cancel preserve all frame and sheet state',
    (tester) async {
      final app = EditorController(initialProject: sample());
      addTearDown(app.dispose);
      final before = app.project;
      await mount(tester, app, properties: true);
      await click(tester, 'Rámeček a údaje listu…');
      await click(tester, 'Vytvořit a použít samostatnou kopii');
      await click(tester, 'Zrušit');
      await click(tester, 'Rámeček a údaje listu…');
      expect(find.textContaining('– kopie'), findsNothing);
      await select(tester, 'Rámeček listu', 'Bez rámečku');
      await click(tester, 'Použít v návrhu');
      await click(tester, 'Zrušit');
      expect(app.project, same(before));
    },
  );

  testWidgets('cancel revokes an export waiting on its destination', (
    tester,
  ) async {
    final destination = Completer<void>();
    var wrote = false;
    final files = FrameTemplateFiles(
      write: (_, _, canCommit) async {
        await destination.future;
        if (!canCommit()) throw const FormatException('Zrušeno');
        wrote = true;
        return 'ramecek.oecadframe';
      },
    );
    final app = EditorController(initialProject: sample());
    addTearDown(app.dispose);
    await mount(tester, app, files: files);
    await click(tester, 'Šablony');
    await click(tester, 'Exportovat definici…');
    await tester.tap(find.text('Zrušit'));
    destination.complete();
    await tester.pumpAndSettle();
    expect(wrote, isFalse);
    expect(app.project.revision, 0);
  });

  testWidgets('new mounting viewport is derived from selected frame content', (
    tester,
  ) async {
    final app = EditorController(initialProject: sample());
    addTearDown(app.dispose);
    final expected = defaultMountingViewport(app.project, app.sheet);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder:
                (context) => TextButton(
                  onPressed: () => editMountingView(context, app),
                  child: const Text('Montáž'),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Montáž'));
    await tester.pumpAndSettle();
    for (final e
        in {
          'Okno X': expected.x,
          'Okno Y': expected.y,
          'Okno šířka': expected.width,
          'Okno výška': expected.height,
        }.entries) {
      final widget = tester.widget<TextField>(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == e.key,
        ),
      );
      expect(
        double.parse(widget.controller!.text.replaceAll(',', '.')),
        closeTo(e.value, .051),
      );
    }
    await click(tester, 'Zrušit');
    await tester.pump(const Duration(milliseconds: 500));
  });
  testWidgets('project metadata refreshes bound preview and persists once', (
    tester,
  ) async {
    final app = EditorController(initialProject: sample());
    addTearDown(app.dispose);
    await mount(tester, app);
    await click(tester, 'Údaje');
    final row = find.byKey(const ValueKey('document-drawnBy'));
    await tester.enterText(
      find.descendant(of: row, matching: find.byType(TextField)),
      'Nový autor',
    );
    await click(tester, 'Výběr rámečku');
    final preview = tester.widget<FrameTemplatePreview>(
      find.byType(FrameTemplatePreview),
    );
    expect(
      preview.frame.source.texts.firstWhere((f) => f.id == 'author').text,
      contains('Nový autor'),
    );
    expect(app.project.documentFields['drawnBy'], 'Autor');
    await click(tester, 'Uložit');
    expect(app.project.documentFields['drawnBy'], 'Nový autor');
    expect(app.project.revision, 1);
  });

  testWidgets(
    'shared layout edits reach all inheriting sheets only on outer Save',
    (tester) async {
      final app = EditorController(initialProject: sample());
      addTearDown(app.dispose);
      await mount(tester, app, sheetId: 's1');
      await click(tester, 'Upravit sdílenou šablonu…');
      await tester.enterText(
        find.byKey(const ValueKey('frame-template-name')),
        'Sdílený rámeček',
      );
      await click(tester, 'Použít v návrhu');
      expect(app.project.frameTemplates.single.name, 'Generic');
      await click(tester, 'Uložit');
      expect(app.project.frameTemplates.single.name, 'Sdílený rámeček');
      for (final sheet in app.project.pages) {
        expect(
          resolveSheetFrame(app.project, sheet)!.template.name,
          'Sdílený rámeček',
        );
      }
      expect(app.project.revision, 1);
    },
  );
}
