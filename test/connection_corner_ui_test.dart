// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/app/theme.dart';
import 'package:open_ecad/app/workspace_controller.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/editor/drawing_cursor.dart';
import 'package:open_ecad/widgets/drawing_cursor_dialog.dart';
import 'package:open_ecad/editor/wire_hover_overlay.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'wiring_fixtures.dart';

class MemoryPersistence extends ProjectPersistence {
  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async => 'memory';
}

void screen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1700, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Offset at(WidgetTester tester, Vec2 point) =>
    tester.getRect(find.byType(SchematicCanvas)).center +
    Offset(point.x - 550, point.y - 390);

Future<void> shortcut(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final orientation in CornerOrientation.values) {
    testWidgets(
      'menu inserts ${orientation.glyph}, edits a real connection and reopens it',
      (tester) async {
        screen(tester);
        final app = EditorController(
          initialProject: wiringScene(orientation: orientation),
          persistence: MemoryPersistence(),
        );
        addTearDown(app.dispose);
        await tester.pumpWidget(OpenEcadApp(controller: app));
        app.viewport.reset();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Spojovací roh'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Spojovací roh ${orientation.glyph}'));
        await tester.pumpAndSettle();
        await tester.tapAt(at(tester, const Vec2(402, 302)));
        await tester.pump();
        final corner = app.sheet.corners.single;
        expect(corner.position, const Vec2(400, 300));
        expect(corner.orientation, orientation);
        expect(app.sheet.wires, isEmpty);
        expect(AutoConnect.wires(app.sheet), hasLength(2));
        final r = ProjectResolver(app.project);
        expect(
          ConnectivityIndex.build(app.project).connected(
            r.nodeFor(
              app.sheet,
              const TerminalRef(deviceId: 'a', portId: 'p'),
            )!,
            r.nodeFor(
              app.sheet,
              const TerminalRef(deviceId: 'b', portId: 'p'),
            )!,
          ),
          isTrue,
        );
        expect(app.project.components, hasLength(2));
        final reopened = EcadProject.fromJson(
          jsonDecode(jsonEncode(app.project.toJson())),
        );
        expect(AutoConnect.wires(reopened.pages.single), hasLength(2));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(app.mode, CanvasMode.select);
        await tester.tapAt(at(tester, const Vec2(400, 300)));
        await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
        await tester.pump();
        expect(app.sheet.corners.single.orientation, orientation.rotated);
        await shortcut(tester, LogicalKeyboardKey.keyZ);
        expect(app.sheet.corners.single.orientation, orientation);
        final drag = await tester.startGesture(
          at(tester, const Vec2(400, 300)),
        );
        await drag.moveBy(const Offset(30, 20));
        await tester.pump();
        await drag.up();
        await tester.pump();
        expect(app.sheet.corners.single.position, const Vec2(430, 320));
        expect(AutoConnect.wires(app.sheet), isEmpty);
        await shortcut(tester, LogicalKeyboardKey.keyZ);
        expect(AutoConnect.wires(app.sheet), hasLength(2));
        await shortcut(tester, LogicalKeyboardKey.keyY);
        expect(AutoConnect.wires(app.sheet), isEmpty);
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pump();
        expect(app.sheet.corners, isEmpty);
        await shortcut(tester, LogicalKeyboardKey.keyZ);
        expect(app.sheet.corners.single.id, corner.id);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'automatic wire hover follows a corner and clears across same-ID documents',
    (tester) async {
      screen(tester);
      final first = EditorController(
        initialProject: wiringScene(withCorner: true),
        persistence: MemoryPersistence(),
      );
      final second = EditorController(
        initialProject: wiringScene(),
        persistence: MemoryPersistence(),
      );
      final workspace = WorkspaceController(first);
      workspace.add(second, owned: false);
      workspace.openSheet(first, 's');
      addTearDown(() {
        workspace.dispose();
        first.dispose();
        second.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildEcadTheme(EcadAppearance.paper),
          home: ListenableBuilder(
            listenable: workspace,
            builder:
                (context, _) => EditorWorkspace(
                  controller: workspace.active,
                  workspace: workspace,
                ),
          ),
        ),
      );
      first.viewport.reset();
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: at(tester, const Vec2(470, 300)));
      await mouse.moveTo(at(tester, const Vec2(471, 300)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('-A:1'), findsOneWidget);
      final overlay = tester.widget<WireHoverOverlay>(
        find.byType(WireHoverOverlay),
      );
      expect(overlay.info!.label, anyOf('-A:1 → -B:1', '-B:1 → -A:1'));
      first.setMode(CanvasMode.wire);
      await tester.pump();
      await tester.tapAt(at(tester, const Vec2(540, 300)));
      second.setMode(CanvasMode.wire);
      workspace.openSheet(second, 's');
      await tester.pumpAndSettle();
      second.viewport.reset();
      await tester.pump();
      expect(
        tester.widget<WireHoverOverlay>(find.byType(WireHoverOverlay)).info,
        isNull,
      );
      await tester.tapAt(at(tester, const Vec2(400, 440)));
      expect(second.sheet.wires, isEmpty);
      await tester.tapAt(at(tester, const Vec2(540, 300)));
      expect(second.sheet.wires, hasLength(1));
      expect(first.sheet.wires, isEmpty);
      await mouse.removePointer();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'workspace cursor settings control the deepest canvas region without editing the document',
    (tester) async {
      screen(tester);
      final app = EditorController(
        initialProject: wiringScene(),
        persistence: MemoryPersistence(),
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(OpenEcadApp(controller: app));
      await tester.pumpAndSettle();
      final snapshot = app.project;
      final canvas = find.byType(SchematicCanvas);
      Iterable<MouseRegion> regions() => tester.widgetList<MouseRegion>(
        find.descendant(of: canvas, matching: find.byType(MouseRegion)),
      );
      expect(find.byType(DrawingCursorRegion), findsOneWidget);
      expect(regions().any((r) => r.cursor == SystemMouseCursors.none), isTrue);
      await tester.tap(find.byTooltip('Nastavení programu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kreslicí kurzor…'));
      await tester.pumpAndSettle();
      expect(find.byType(DrawingCursorDialog), findsOneWidget);
      expect(
        regions().any((r) => r.cursor == SystemMouseCursors.none),
        isFalse,
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.tap(
        find.descendant(
          of: find.byType(DrawingCursorDialog),
          matching: find.text('Uložit'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DrawingCursorDialog), findsNothing);
      expect(
        regions().any((r) => r.cursor == SystemMouseCursors.none),
        isFalse,
      );
      expect(app.project, same(snapshot));
      expect(app.canUndo, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
