import 'model_fixtures.dart';
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/services/ecad_services.dart';
import 'package:open_ecad/services/pdf_conversion.dart';
import 'package:open_ecad/widgets/components.dart';
import 'package:open_ecad/widgets/project_panel.dart';
import 'package:open_ecad/widgets/properties_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<EditorController> _mount(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = EditorController(initialProject: testDemoProject());
  addTearDown(controller.dispose);
  await tester.pumpWidget(OpenEcadApp(controller: controller));
  await tester.pumpAndSettle();
  return controller;
}

Finder _iconButton(String label) => find.byWidgetPredicate(
  (widget) => widget is EcadIconButton && widget.label == label,
);

Finder _inDialog(String text) => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.textContaining(text),
);

Finder _inSheetList(String text) => find.descendant(
  of: find.byType(ProjectPanel),
  matching: find.textContaining(text),
);

void main() {
  group('controller', () {
    test('adds typed sheets as single undoable steps', () {
      final app = EditorController(initialProject: testDemoProject());
      addTearDown(app.dispose);
      final pages = app.project.pages.length;

      app.addSheet();
      expect(app.sheet.type, SheetType.multiLine);
      expect(app.sheet.name, 'Nové schéma');
      expect(app.sheet.graphics, isEmpty);

      app.addSheet(type: SheetType.cabinetLayout, name: '  Skříň B  ');
      expect(app.sheet.type, SheetType.cabinetLayout, reason: app.status);
      expect(app.sheet.name, 'Skříň B');
      expect(app.sheet.number, '04');
      expect(app.sheet.paperSizeMm.width, 297);
      expect(app.sheet.paperSizeMm.height, 210);
      expect(app.sheet.frame.mode, FrameMode.inherit);
      expect(resolveSheetFrame(app.project, app.sheet)?.border, isTrue);

      app.addSheet(type: SheetType.form, formStarter: true);
      expect(app.sheet.name, 'Nový formulář');
      expect(app.sheet.graphics, hasLength(SheetTemplates.blankForm().length));
      expect(
        app.sheet.graphics
            .where((g) => g.kind == DrawingKind.text)
            .map((g) => g.text),
        SheetTemplates.formColumns.map((column) => column.$1),
      );
      expect(app.sheet.devices, isEmpty);

      app.addSheet(type: SheetType.singleLine, formStarter: true);
      expect(app.sheet.name, 'Nové jednopólové schéma');
      expect(app.sheet.graphics, isEmpty, reason: 'Only forms get a table');

      app.undo();
      app.undo();
      expect(app.project.pages, hasLength(pages + 2));
      expect(app.project.pages.last.type, SheetType.cabinetLayout);
      app.redo();
      expect(app.project.pages.last.type, SheetType.form);
      expect(app.project.pages.last.graphics, isNotEmpty);

      app.addSheet(type: SheetType.form);
      expect(app.sheet.graphics, isEmpty, reason: 'The table is optional');
      expect(
        validateProject(app.project).where((d) => d.code == 'duplicate_id'),
        isEmpty,
      );
    });

    test('new sheets keep an inherited frame that needs larger paper', () {
      final original = testDemoProject();
      final frame = original.frameTemplates.single;
      final project = EcadProject(
        id: 'wide-frame-project',
        name: 'Wide frame',
        frameTemplates: [
          frame.copyWith(titleBlock: frame.titleBlock.copyWith(widthMm: 300)),
        ],
        defaultFrame: FrameChoice.template(frame.id),
        pages: [Sheet(id: 'first', name: 'First', number: '01')],
      );
      final app = EditorController(initialProject: project);
      addTearDown(app.dispose);
      for (final type in [
        SheetType.multiLine,
        SheetType.cabinetLayout,
        SheetType.form,
      ]) {
        final count = app.project.pages.length;
        app.addSheet(type: type, formStarter: type == SheetType.form);
        expect(app.project.pages, hasLength(count + 1), reason: app.status);
        expect(app.sheet.type, type);
        expect(app.sheet.paperSizeMm.width, 420);
        expect(app.sheet.paperSizeMm.height, 297);
        expect(app.sheet.frame.mode, FrameMode.inherit);
        expect(resolveSheetFrame(app.project, app.sheet)?.border, isTrue);
        if (type == SheetType.form) expect(app.sheet.graphics, isNotEmpty);
      }
    });

    test('changes the active sheet type with undo, redo and no-op', () {
      final app = EditorController(initialProject: testDemoProject());
      addTearDown(app.dispose);
      app.addSheet(type: SheetType.multiLine);
      final control = app.sheet;
      app.setSheet(control.id);
      expect(app.sheet.type, SheetType.multiLine);

      app.setSheetType(SheetType.form);
      expect(app.sheet.type, SheetType.form);
      expect(app.project.pages.first.type, SheetType.singleLine);
      expect(app.sheet.devices.length, control.devices.length);
      final revision = app.project.revision;
      app.setSheetType(SheetType.form);
      expect(app.project.revision, revision);

      app.undo();
      expect(app.sheet.type, SheetType.multiLine);
      app.redo();
      expect(app.sheet.type, SheetType.form);
    });

    test('persisted v4 types survive save and old formats are rejected', () {
      final persistence = ProjectPersistence();
      final typed = EcadProject(
        id: 'typed',
        name: 'Typed',
        pages: [
          Sheet(
            id: 'layout',
            name: 'Layout',
            number: '01',
            type: SheetType.cabinetLayout,
          ),
          Sheet(id: 'form', name: 'Form', number: '02', type: SheetType.form),
        ],
      );
      final encoded = persistence.encode(typed);
      expect(jsonDecode(encoded)['formatVersion'], EcadProject.formatVersion);
      expect(persistence.decode(encoded).pages.map((s) => s.type), [
        SheetType.cabinetLayout,
        SheetType.form,
      ]);
      final legacy = typed.toJson()..['formatVersion'] = 3;
      expect(
        () => persistence.decode(jsonEncode(legacy)),
        throwsA(isA<EcadException>()),
      );
      final invalid = typed.toJson();
      ((invalid['pages']! as List).first as Map<String, Object?>)['type'] =
          'overview';
      expect(
        () => persistence.decode(jsonEncode(invalid)),
        throwsA(isA<EcadException>()),
      );
    });
    test('incompatible type changes keep electrical content visible', () {
      final app = EditorController(initialProject: testDemoProject());
      addTearDown(app.dispose);
      final before = app.project.toJson();
      app.setSheetType(SheetType.form);
      expect(app.project.toJson(), before);
      expect(app.status, contains('Obsah listu neodpovídá'));
    });
  });

  group('outputs', () {
    test('default frames display sheet names for every sheet type', () {
      final project = EcadProject(
        id: 'typed_export',
        name: 'Typy listů',
        pages: [
          for (final type in SheetType.values)
            Sheet(
              id: 'sheet_${type.name}',
              name: type.label,
              number: type.name,
              type: type,
              report:
                  type == SheetType.billOfMaterials
                      ? const BomTableSpec(kind: BomReportKind.articles)
                      : null,
            ),
        ],
      );
      final exporter = ProjectExportService();
      final svg = exporter.svg(project);
      expect(svg, isNot(contains('ELEKTRICKÉ SCHÉMA')));
      for (final type in SheetType.values) {
        final sheetSvg = exporter.svg(project, sheetId: 'sheet_${type.name}');
        expect(sheetSvg, contains('data-frame="true"'));
        expect(sheetSvg, contains(type.label));
      }
    });

    test('import note reports guessed types only when some exist', () {
      final note = sheetTypeImportNote({
        'source': 'bookmarkTitle',
        'classified': {'form': 2, 'singleLine': 1},
        'unclassified': 5,
      });
      expect(note, contains('u 3 z 8 listů'));
      expect(note, contains('vícepólové schéma'));
      expect(
        sheetTypeImportNote({'classified': <String, int>{}, 'unclassified': 4}),
        isNull,
      );
      expect(sheetTypeImportNote(null), isNull);
      expect(sheetTypeImportNote({'classified': 'form'}), isNull);
    });
  });

  group('workspace', () {
    testWidgets('new sheet dialog creates a form with a blank table', (
      tester,
    ) async {
      final app = await _mount(tester);
      final pages = app.project.pages.length;
      await tester.tap(find.byTooltip('Přidat list').first);
      await tester.pumpAndSettle();
      expect(find.text('Nový list'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'Nové jednopólové schéma',
        reason: 'The dialog starts with the active sheet type',
      );

      await tester.tap(_inDialog(SheetType.form.label));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'Nový formulář',
      );
      expect(_inDialog('Vložit prázdnou tabulku'), findsOneWidget);
      await tester.tap(find.text('Vytvořit list'));
      await tester.pumpAndSettle();

      expect(app.project.pages, hasLength(pages + 1));
      expect(app.sheet.type, SheetType.form);
      expect(app.sheet.name, 'Nový formulář');
      expect(app.sheet.graphics, isNotEmpty);
      expect(
        find.descendant(
          of: find.byType(ProjectPanel),
          matching: find.byTooltip(SheetType.form.label),
        ),
        findsOneWidget,
      );
      app.undo();
      await tester.pumpAndSettle();
      expect(app.project.pages, hasLength(pages));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('tab button keeps quick creation and accepts a custom name', (
      tester,
    ) async {
      final app = await _mount(tester);
      app.setSheet(app.project.pages[1].id);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Přidat list').last);
      await tester.pumpAndSettle();
      expect(_inDialog('Nové schéma'), findsOneWidget);
      await tester.tap(_inDialog(SheetType.cabinetLayout.label));
      await tester.pumpAndSettle();
      expect(_inDialog('Vložit prázdnou tabulku'), findsNothing);
      await tester.enterText(find.byType(TextField).last, 'Skříň čerpadel');
      await tester.tap(_inDialog(SheetType.form.label));
      await tester.pumpAndSettle();
      expect(_inDialog('Skříň čerpadel'), findsOneWidget);
      await tester.tap(_inDialog(SheetType.cabinetLayout.label));
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(app.sheet.name, 'Skříň čerpadel');
      expect(app.sheet.type, SheetType.cabinetLayout, reason: app.status);
      expect(app.sheet.graphics, isEmpty);

      await tester.tap(find.byTooltip('Přidat list').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      expect(app.sheet.name, 'Skříň čerpadel');
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('sheet properties change the type as an undoable edit', (
      tester,
    ) async {
      final app = await _mount(tester);
      app.addSheet(type: SheetType.singleLine);
      app.setPanel(SidePanel.properties);
      await tester.pumpAndSettle();
      final option = find.descendant(
        of: find.byType(PropertiesPanel),
        matching: find.text(SheetType.cabinetLayout.label),
      );
      await tester.ensureVisible(option);
      await tester.pumpAndSettle();
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(app.sheet.type, SheetType.cabinetLayout, reason: app.status);
      expect(
        find.descendant(
          of: find.byType(ProjectPanel),
          matching: find.byTooltip(SheetType.cabinetLayout.label),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byTooltip(SheetType.cabinetLayout.label),
          matching: find.text('03'),
        ),
        findsOneWidget,
      );

      await tester.tap(_iconButton('Vrátit · Ctrl Z\n${app.undoLabel}'));
      await tester.pumpAndSettle();
      expect(app.sheet.type, SheetType.singleLine);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('sheet list menu changes type and search finds types', (
      tester,
    ) async {
      final app = await _mount(tester);
      app.execute([
        DeleteDevices(app.sheet.id, app.sheet.devices.map((d) => d.id).toSet()),
      ], 'Remove occurrences');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Vlastnosti listu'));
      await tester.tap(find.byTooltip('Vlastnosti listu'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, SheetType.form.label),
      );
      await tester.pumpAndSettle();
      expect(app.sheet.type, SheetType.form);

      final search = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Najít list nebo typ…',
      );
      final first = app.project.pages.first.name;
      final second = app.project.pages[1].name;
      for (final (query, visible, hidden) in [
        ('formular', first, second),
        ('VÍCEPÓLOVÉ', second, first),
      ]) {
        await tester.enterText(search, query);
        await tester.pump();
        expect(_inSheetList(visible), findsOneWidget, reason: query);
        expect(_inSheetList(hidden), findsNothing, reason: query);
      }
      app.undo();
      await tester.enterText(search, '1p');
      await tester.pump();
      expect(_inSheetList(first), findsOneWidget);
      expect(_inSheetList(second), findsNothing);
      await tester.enterText(search, 'výstavba');
      await tester.pump();
      expect(_inSheetList(first), findsNothing);
      expect(_inSheetList(second), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 500));
    });
  });
}
