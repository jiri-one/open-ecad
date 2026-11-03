// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/keyboard_shortcuts.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<EditorController> mount(
  WidgetTester tester,
  KeyboardShortcuts shortcuts,
) async {
  SharedPreferences.setMockInitialValues({
    KeyboardShortcutPreferences.storageKey: shortcuts.encode(),
  });
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final device = createBuiltinComponent(
    componentId: 'breaker',
    deviceId: 'symbol',
    kind: DeviceKind.breaker,
    designation: '-Q1',
    position: const Vec2(400, 300),
  );
  final app = EditorController(
    initialProject: EcadProject(
      id: 'shortcuts',
      name: 'Shortcuts',
      components: [device.component],
      pages: [
        Sheet(
          id: 'first',
          name: 'First',
          number: '1',
          devices: [device.device],
        ),
        Sheet(id: 'second', name: 'Second', number: '2'),
      ],
    ),
  );
  addTearDown(app.dispose);
  await tester.pumpWidget(OpenEcadApp(controller: app));
  await tester.pumpAndSettle();
  app.viewport.focus();
  await tester.pump();
  return app;
}

void main() {
  testWidgets(
    'stored page shortcuts replace defaults and update toolbar and help',
    (tester) async {
      final shortcuts = const KeyboardShortcuts.defaults()
          .withBindings(EditorCommand.nextSheet, [
            const ShortcutBinding(key: LogicalKeyboardKey.f8),
          ])
          .withBindings(EditorCommand.previousSheet, [
            const ShortcutBinding(key: LogicalKeyboardKey.f7),
          ]);
      final app = await mount(tester, shortcuts);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      expect(app.activeSheetId, 'first');
      expect(find.byTooltip('Následující list · F8'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pumpAndSettle();
      expect(app.activeSheetId, 'second');
      await tester.sendKeyEvent(LogicalKeyboardKey.f7);
      await tester.pumpAndSettle();
      expect(app.activeSheetId, 'first');
      await tester.ensureVisible(
        find.byTooltip('Ovládání a klávesové zkratky'),
      );
      await tester.tap(find.byTooltip('Ovládání a klávesové zkratky'));
      await tester.pumpAndSettle();
      expect(find.textContaining('F8 — Následující list'), findsOneWidget);
      expect(app.dirty, isFalse);
    },
  );

  testWidgets(
    'canvas properties, delete, cancel and held pan obey remapped chords',
    (tester) async {
      final shortcuts = const KeyboardShortcuts.defaults()
          .withBindings(EditorCommand.editProperties, [
            const ShortcutBinding(key: LogicalKeyboardKey.f3),
          ])
          .withBindings(EditorCommand.deleteSelection, [
            const ShortcutBinding(key: LogicalKeyboardKey.f9),
          ])
          .withBindings(EditorCommand.cancelTool, [
            const ShortcutBinding(key: LogicalKeyboardKey.keyU),
          ])
          .withBindings(EditorCommand.temporaryPan, [
            const ShortcutBinding(key: LogicalKeyboardKey.keyI),
          ]);
      final app = await mount(tester, shortcuts);
      app.select({'symbol'});
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      expect(find.text('Vlastnosti přístroje'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.f3);
      await tester.pumpAndSettle();
      expect(find.text('Vlastnosti přístroje'), findsOneWidget);
      await tester.tap(find.text('Zavřít'));
      await tester.pumpAndSettle();
      app.viewport.focus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      expect(app.sheet.devices, hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.f9);
      await tester.pump();
      expect(app.sheet.devices, isEmpty);
      app.setMode(CanvasMode.drawLine);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(app.mode, CanvasMode.drawLine);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
      await tester.pump();
      expect(app.mode, CanvasMode.select);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      expect(app.viewport.hasActiveGesture, isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyI);
      expect(app.viewport.hasActiveGesture, isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyI);
      expect(app.viewport.hasActiveGesture, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'remapping does not steal typing or native text selection shortcuts',
    (tester) async {
      final shortcuts = const KeyboardShortcuts.defaults()
          .withBindings(EditorCommand.nextSheet, [
            const ShortcutBinding(key: LogicalKeyboardKey.keyN),
          ])
          .withBindings(EditorCommand.saveProject, [
            const ShortcutBinding(key: LogicalKeyboardKey.keyA, control: true),
          ])
          .withBindings(EditorCommand.selectAll, []);
      final app = await mount(tester, shortcuts);
      final search = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.hintText == 'Najít list nebo typ…',
      );
      await tester.tap(search);
      await tester.enterText(search, 'First');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      expect(app.activeSheetId, 'first');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      final field = tester.widget<TextField>(search);
      expect(
        field.controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: 5),
      );
      app.viewport.focus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(app.activeSheetId, 'second');
      expect(app.dirty, isFalse);
    },
  );

  testWidgets(
    'program settings opens the shortcut configuration without editing the project',
    (tester) async {
      final app = await mount(tester, const KeyboardShortcuts.defaults());
      await tester.ensureVisible(find.byTooltip('Nastavení programu'));
      await tester.tap(find.byTooltip('Nastavení programu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Klávesové zkratky…'));
      await tester.pumpAndSettle();
      expect(find.text('Klávesové zkratky'), findsOneWidget);
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      expect(app.dirty, isFalse);
      expect(app.canUndo, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saving a shortcut through program settings takes effect immediately',
    (tester) async {
      final app = await mount(tester, const KeyboardShortcuts.defaults());
      await tester.ensureVisible(find.byTooltip('Nastavení programu'));
      await tester.tap(find.byTooltip('Nastavení programu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Klávesové zkratky…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('shortcuts-search')),
        'nasledujici',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('shortcut-binding-nextSheet-0')),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Uložit'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Následující list · F8'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      expect(app.activeSheetId, 'first');
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pumpAndSettle();
      expect(app.activeSheetId, 'second');
      expect(app.dirty, isFalse);
      final restored = KeyboardShortcutPreferences();
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.value.labelFor(EditorCommand.nextSheet), 'F8');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native word deletion and navigation take priority over remapped project commands',
    (tester) async {
      final shortcuts = const KeyboardShortcuts.defaults().withBindings(
        EditorCommand.commandPalette,
        [
          const ShortcutBinding(
            key: LogicalKeyboardKey.backspace,
            control: true,
          ),
          const ShortcutBinding(key: LogicalKeyboardKey.delete, control: true),
          const ShortcutBinding(
            key: LogicalKeyboardKey.arrowLeft,
            control: true,
          ),
          const ShortcutBinding(key: LogicalKeyboardKey.home, control: true),
        ],
      );
      final app = await mount(tester, shortcuts);
      final search = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.hintText == 'Najít list nebo typ…',
      );
      await tester.tap(search);
      Future<void> chord(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(find.text('Hledat příkaz…'), findsNothing);
      }

      final field = tester.widget<TextField>(search).controller!;
      await tester.enterText(search, 'first second');
      await chord(LogicalKeyboardKey.backspace);
      expect(field.text.length, lessThan('first second'.length));
      await tester.enterText(search, 'first second');
      await chord(LogicalKeyboardKey.arrowLeft);
      expect(field.selection.extentOffset, lessThan(field.text.length));
      await chord(LogicalKeyboardKey.home);
      expect(field.selection.extentOffset, 0);
      await chord(LogicalKeyboardKey.delete);
      expect(field.text.length, lessThan('first second'.length));
      expect(app.dirty, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
