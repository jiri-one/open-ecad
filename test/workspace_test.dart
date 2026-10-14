import 'dart:ui' show SemanticsAction;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/theme.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/widgets/components.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<EditorController> mountWorkspace(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = EditorController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(OpenEcadApp(controller: controller));
  await tester.pumpAndSettle();
  return controller;
}

Finder fieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  testWidgets('workspace fits desktop sizes in all three appearances', (
    tester,
  ) async {
    final app = await mountWorkspace(tester);
    for (final size in [const Size(1440, 900), const Size(1024, 768)]) {
      tester.view.physicalSize = size;
      for (final appearance in EcadAppearance.values) {
        await app.setAppearance(appearance);
        await tester.pumpAndSettle();
        for (final tab in ['Listy projektu', 'Přístroje']) {
          await tester.tap(find.widgetWithText(Tab, tab));
          await tester.pumpAndSettle();
          expect(find.byType(SchematicCanvas), findsOneWidget);
          expect(find.text('Asistent'), findsOneWidget);
          expect(
            tester.takeException(),
            isNull,
            reason: '$size / $appearance / $tab',
          );
        }
      }
    }
  });

  testWidgets('icon buttons support semantic activation', (tester) async {
    final handle = tester.ensureSemantics();
    final app = await mountWorkspace(tester);
    final node = tester.getSemantics(find.bySemanticsLabel('Barevný'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(app.appearance, EcadAppearance.studio);
    handle.dispose();
  });

  testWidgets('property changes preserve fractional imported coordinates', (
    tester,
  ) async {
    final app = await mountWorkspace(tester);
    final device = app.sheet.devices.first;
    app.moveDevices({device.id: const Vec2(400.25, 150.75)});
    app.select({device.id});
    app.setPanel(SidePanel.properties);
    await tester.pumpAndSettle();
    await tester.enterText(fieldWithLabel('Parametry'), '230 V');
    await tester.ensureVisible(find.text('Použít vlastnosti'));
    await tester.tap(find.text('Použít vlastnosti'));
    await tester.pumpAndSettle();
    final changed = app.selectedDevices.single;
    expect(changed.rating, '230 V');
    expect(changed.position.x, 400.25);
    expect(changed.position.y, 150.75);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('double clicking an inactive tab renames that sheet', (
    tester,
  ) async {
    final app = await mountWorkspace(tester);
    final first = app.project.pages.first;
    final second = app.project.pages[1];
    final tab = find.text(second.name).last;
    await tester.tap(tab);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(tab);
    await tester.pumpAndSettle();
    expect(find.text('Název listu'), findsOneWidget);
    await tester.enterText(fieldWithLabel('Název'), 'Pomocné obvody');
    await tester.tap(find.text('Uložit název'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(app.project.pages.first.name, first.name);
    expect(app.project.pages[1].name, 'Pomocné obvody');
    expect(app.activeSheetId, second.id);
  });

  testWidgets(
    'graphic inspector edits Unicode text without changing source position',
    (tester) async {
      final app = await mountWorkspace(tester);
      app.createGraphic(
        DrawingElement(
          id: 'editable_text',
          kind: DrawingKind.text,
          position: const Vec2(100.25, 120.75),
          width: 120,
          height: 16,
          fill: '#000000',
          text: 'Původní text',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Grafický objekt bez elektrických vývodů.'),
        findsOneWidget,
      );
      await tester.enterText(fieldWithLabel('Text'), 'Přívod čerpadla');
      await tester.ensureVisible(find.text('Použít vlastnosti'));
      await tester.tap(find.text('Použít vlastnosti'));
      await tester.pumpAndSettle();
      expect(app.selectedGraphics.single.text, 'Přívod čerpadla');
      expect(app.selectedGraphics.single.position, const Vec2(100.25, 120.75));
      app.undo();
      await tester.pumpAndSettle();
      expect(app.selectedGraphics.single.text, 'Původní text');
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets('multiple selection inspector can focus a single device', (
    tester,
  ) async {
    final app = await mountWorkspace(tester);
    final selected = app.sheet.devices.take(2).toList();
    app.select(selected.map((device) => device.id).toSet());
    app.setPanel(SidePanel.properties);
    await tester.pumpAndSettle();
    expect(find.text('2 objektů ve výběru'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text(selected.first.designation));
    await tester.pumpAndSettle();
    expect(app.selectedIds, {selected.first.id});
    expect(tester.takeException(), isNull);
  });

  testWidgets('typing in the assistant does not invoke drawing shortcuts', (
    tester,
  ) async {
    final app = await mountWorkspace(tester);
    final device = app.sheet.devices.first;
    app.select({device.id});
    await tester.pump();
    final prompt = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Co chcete ve schématu změnit?',
    );
    await tester.tap(prompt);
    await tester.enterText(prompt, 'Uprav výběr');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(app.mode, CanvasMode.select);
    expect(app.sheet.devices.first.rotation, device.rotation);
    expect(app.sheet.devices.any((d) => d.id == device.id), isTrue);
    expect(app.project.revision, 0);
  });

  testWidgets(
    'assistant proposal previews then applies and undoes as one edit',
    (tester) async {
      final app = await mountWorkspace(tester);
      final originalCount = app.sheet.devices.length;
      final prompt = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Co chcete ve schématu změnit?',
      );
      await tester.tap(prompt);
      await tester.enterText(prompt, 'Přidej motorový vývod');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(app.showingProposal, isTrue);
      expect(app.sheet.devices.length, originalCount);
      expect(app.displaySheet.devices.length, greaterThan(originalCount));
      expect(
        tester.widget<SchematicCanvas>(find.byType(SchematicCanvas)).readOnly,
        isTrue,
      );
      await tester.ensureVisible(find.text('Použít změny'));
      await tester.tap(find.text('Použít změny'));
      await tester.pumpAndSettle();
      expect(app.sheet.devices.length, greaterThan(originalCount));
      expect(app.showingProposal, isFalse);
      final undo = find.byWidgetPredicate(
        (widget) =>
            widget is EcadIconButton && widget.label.startsWith('Vrátit'),
      );
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(app.sheet.devices.length, originalCount);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets('assistant validation exposes navigable diagnostics', (
    tester,
  ) async {
    final app = await mountWorkspace(tester);
    await tester.tap(find.text('Zkontroluj projekt'));
    await tester.pumpAndSettle();
    expect(app.diagnostics, isNotEmpty);
    expect(find.textContaining('Kontrola projektu ·'), findsOneWidget);
    final diagnostic = app.diagnostics.first;
    await tester.tap(find.text(diagnostic.message));
    await tester.pumpAndSettle();
    expect(app.activeSheetId, diagnostic.sheetId);
    expect(app.selectedIds, contains(diagnostic.deviceId));
    expect(app.sidePanel, SidePanel.properties);
    expect(tester.takeException(), isNull);
  });
}
