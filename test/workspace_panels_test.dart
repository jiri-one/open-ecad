// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/theme.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/interface_preferences.dart';
import 'package:open_ecad/widgets/workspace_panels.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'model_fixtures.dart';

Finder panel(String side) => find.byKey(ValueKey('workspace-$side-panel'));
Finder grip(String side) => find.byKey(ValueKey('workspace-$side-resize'));
final editor = find.byKey(const ValueKey('workspace-editor-area'));

Widget host({bool showProject = true, bool showInspector = true}) =>
    MaterialApp(
      theme: buildEcadTheme(EcadAppearance.paper),
      home: Scaffold(
        body: WorkspacePanels(
          showProject: showProject,
          showInspector: showInspector,
          project: const ColoredBox(color: Colors.white),
          inspector: const ColoredBox(color: Colors.white),
          editor: const MouseRegion(
            cursor: SystemMouseCursors.precise,
            child: ColoredBox(color: Colors.white),
          ),
        ),
      ),
    );

Future<void> mount(
  WidgetTester tester, {
  Map<String, Object> stored = const {},
}) async {
  SharedPreferences.setMockInitialValues(stored);
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(host());
  await tester.pumpAndSettle();
}

Future<void> drag(WidgetTester tester, String side, double delta) async {
  final mouse = await tester.startGesture(
    tester.getCenter(grip(side)),
    kind: PointerDeviceKind.mouse,
  );
  await mouse.moveBy(Offset(delta, 0));
  await tester.pump();
  await mouse.up();
  await tester.pumpAndSettle();
}

void main() {
  for (final side in ['project', 'inspector']) {
    testWidgets(
      'resizing $side in a constrained window preserves the other preference',
      (tester) async {
        await mount(
          tester,
          stored: {
            WorkspacePanels.projectWidthKey: 430.0,
            WorkspacePanels.inspectorWidthKey: 540.0,
          },
        );
        tester.view.physicalSize = const Size(960, 900);
        await tester.pumpAndSettle();
        final other = side == 'project' ? 'inspector' : 'project';
        final untouchedWidth = tester.getSize(panel(other)).width;
        await drag(tester, side, side == 'project' ? -40 : 40);
        expect(tester.getSize(panel(other)).width, untouchedWidth);
        tester.view.physicalSize = const Size(1440, 900);
        await tester.pumpAndSettle();
        final store = await SharedPreferences.getInstance();
        expect(
          tester.getSize(panel(other)).width,
          other == 'project' ? 430 : 540,
        );
        expect(
          store.getDouble(
            other == 'project'
                ? WorkspacePanels.projectWidthKey
                : WorkspacePanels.inspectorWidthKey,
          ),
          other == 'project' ? 430 : 540,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('captured resize cursor covers the command and status bars', (
    tester,
  ) async {
    await mount(tester);
    final app = EditorController(initialProject: testDemoProject());
    addTearDown(app.dispose);
    await tester.pumpWidget(OpenEcadApp(controller: app));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    addTearDown(mouse.removePointer);
    await mouse.down(tester.getCenter(grip('project')));
    await mouse.moveBy(const Offset(40, 0));
    await tester.pump();
    for (final position in [const Offset(500, 10), const Offset(500, 890)]) {
      await mouse.moveTo(position);
      await tester.pump();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.resizeLeftRight,
      );
    }
    await mouse.up();
    await tester.pumpAndSettle();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      isNot(SystemMouseCursors.resizeLeftRight),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('each panel grows toward the editor and persists independently', (
    tester,
  ) async {
    await mount(tester);
    final left = tester.getSize(panel('project')).width;
    final right = tester.getSize(panel('inspector')).width;
    await drag(tester, 'project', 100);
    expect(tester.getSize(panel('project')).width, closeTo(left + 100, .01));
    expect(tester.getSize(panel('inspector')).width, right);
    await drag(tester, 'inspector', -80);
    expect(tester.getSize(panel('inspector')).width, closeTo(right + 80, .01));
    expect(tester.getSize(panel('project')).width, closeTo(left + 100, .01));
    final store = await SharedPreferences.getInstance();
    expect(
      store.getDouble(WorkspacePanels.projectWidthKey),
      closeTo(left + 100, .01),
    );
    expect(
      store.getDouble(WorkspacePanels.inspectorWidthKey),
      closeTo(right + 80, .01),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(tester.getSize(panel('project')).width, closeTo(left + 100, .01));
    expect(tester.getSize(panel('inspector')).width, closeTo(right + 80, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the whole grip responds and the cursor stays while captured beyond a limit',
    (tester) async {
      await mount(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(5, 5));
      addTearDown(mouse.removePointer);
      final target = tester.getTopLeft(grip('project')) + const Offset(1, 180);
      await mouse.moveTo(target);
      await tester.pump();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.resizeLeftRight,
      );
      await mouse.down(target);
      await mouse.moveTo(const Offset(1400, 180));
      await tester.pumpAndSettle();
      expect(tester.getSize(editor).width, greaterThanOrEqualTo(320));
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.resizeLeftRight,
      );
      await mouse.up();
      await tester.pumpAndSettle();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        isNot(SystemMouseCursors.resizeLeftRight),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'window constraints preserve a usable canvas and restore preferred widths',
    (tester) async {
      await mount(
        tester,
        stored: {
          WorkspacePanels.projectWidthKey: 430.0,
          WorkspacePanels.inspectorWidthKey: 540.0,
        },
      );
      for (final width in [1024.0, 960.0, 800.0, 680.0, 640.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpAndSettle();
        expect(tester.getSize(editor).width, greaterThanOrEqualTo(320 - .01));
        expect(tester.takeException(), isNull, reason: '$width');
      }
      expect(tester.getSize(panel('project')).width, 430);
      expect(tester.getSize(panel('inspector')).width, 540);
      await tester.pumpWidget(host(showProject: false, showInspector: false));
      await tester.pumpAndSettle();
      expect(find.byType(WorkspacePanels), findsOneWidget);
      expect(tester.getSize(editor).width, 1440);
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(tester.getSize(panel('project')).width, 430);
      expect(tester.getSize(panel('inspector')).width, 540);
    },
  );

  testWidgets(
    'keyboard arrows move each separator and double click restores its default',
    (tester) async {
      await mount(tester);
      final left = tester.getSize(panel('project')).width;
      final right = tester.getSize(panel('inspector')).width;
      await tester.tap(grip('project'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(tester.getSize(panel('project')).width, left + 16);
      await tester.tap(grip('inspector'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(tester.getSize(panel('inspector')).width, right + 16);
      await tester.tap(grip('project'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(grip('project'));
      await tester.pumpAndSettle();
      expect(tester.getSize(panel('project')).width, left);
      expect(tester.getSize(panel('inspector')).width, right + 16);
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          WorkspacePanels.projectWidthKey,
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancel and hiding an active grip release mouse capture', (
    tester,
  ) async {
    await mount(tester);
    final mouse = await tester.startGesture(
      tester.getCenter(grip('project')),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(80, 0));
    await tester.pump();
    tester.view.physicalSize = const Size(800, 900);
    await tester.pumpAndSettle();
    await mouse.cancel();
    await tester.pumpAndSettle();
    expect(grip('project'), findsNothing);
    final width = tester.getSize(panel('inspector')).width;
    await drag(tester, 'inspector', -60);
    expect(tester.getSize(panel('inspector')).width, closeTo(width + 60, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'minimum panel widths keep maximum system and app text scrollable and unclipped',
    (tester) async {
      await mount(
        tester,
        stored: {
          WorkspacePanels.projectWidthKey: 220.0,
          WorkspacePanels.inspectorWidthKey: 260.0,
          InterfacePreferences.storageKey: 2.0,
        },
      );
      tester.platformDispatcher.textScaleFactorTestValue = 24 / 14;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.physicalSize = const Size(960, 640);
      final app = EditorController(initialProject: testDemoProject());
      addTearDown(app.dispose);
      await tester.pumpWidget(OpenEcadApp(controller: app));
      await tester.pumpAndSettle();
      for (final element
          in find
              .descendant(
                of: find.byType(TabBar),
                matching: find.byType(RichText),
              )
              .evaluate()) {
        final paragraph = element.renderObject! as RenderParagraph;
        expect(
          paragraph.size.height + .5,
          greaterThanOrEqualTo(
            paragraph.getMaxIntrinsicHeight(paragraph.size.width),
          ),
          reason: paragraph.text.toPlainText(),
        );
      }
      expect(tester.takeException(), isNull);
      for (final tab in ['Značky', 'Přístroje', 'Artikly', 'Listy']) {
        final target = find.widgetWithText(Tab, tab);
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tab);
      }
    },
  );

  testWidgets(
    'resizing in the editor keeps canvas state, manual zoom and document intact',
    (tester) async {
      await mount(tester);
      final app = EditorController(initialProject: testDemoProject());
      addTearDown(app.dispose);
      await tester.pumpWidget(OpenEcadApp(controller: app));
      await tester.pumpAndSettle();
      app.viewport.zoomIn();
      app.select({app.sheet.devices.first.id});
      await tester.pumpAndSettle();
      final canvas = tester.element(find.byType(SchematicCanvas));
      final project = app.project;
      final selected = Set.of(app.selectedIds);
      final zoom = app.viewport.zoom;
      await drag(tester, 'project', 100);
      await drag(tester, 'inspector', -80);
      expect(tester.element(find.byType(SchematicCanvas)), same(canvas));
      expect(app.project, same(project));
      expect(app.selectedIds, selected);
      expect(app.viewport.zoom, zoom);
      expect(tester.takeException(), isNull);
    },
  );
}
