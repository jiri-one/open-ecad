// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/theme.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/editor/mounting_canvas.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/editor/wire_hover_overlay.dart';
import 'package:open_ecad/services/device_hover_info.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/services/schematic_clipboard.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_hover_fixtures.dart';

const _delay = Duration(milliseconds: 350);

class _MemoryPersistence extends ProjectPersistence {
  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async => 'memory';
}

class _EqualIdentity {
  @override
  bool operator ==(Object other) => other is _EqualIdentity;
  @override
  int get hashCode => 0;
}

EditorController _app({bool mounting = false, EcadProject? project}) {
  final app = EditorController(
    initialProject: project ?? deviceHoverProject(),
    persistence: _MemoryPersistence(),
  );
  if (mounting) app.setSheet('mounting');
  addTearDown(app.dispose);
  return app;
}

Future<void> _show(
  WidgetTester tester,
  EditorController app, {
  bool mounting = false,
  Object? identity,
  bool readOnly = false,
  ClipboardPlacement? paste,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEcadTheme(EcadAppearance.paper),
      home: Scaffold(
        body: Column(
          children: [
            const SizedBox(height: 48, child: TextField()),
            Expanded(
              child: ListenableBuilder(
                listenable: app,
                builder:
                    (context, _) =>
                        mounting
                            ? MountingCanvas(app: app)
                            : SchematicCanvas(
                              sheet: app.sheet,
                              project: app.project,
                              documentIdentity: identity ?? app,
                              controller: app.viewport,
                              selectedIds: app.selectedIds,
                              mode: app.mode,
                              showGrid: false,
                              readOnly: readOnly,
                              pastePreview: paste,
                              palette:
                                  EcadColors.forAppearance(
                                    EcadAppearance.paper,
                                  ).canvasPalette,
                              onSelectionChanged: app.select,
                              onMoveDevices: (_) {},
                              onPlaceDevice: (_, _) {},
                              onConnect: (_, _) {},
                              onDeleteWire: (_) {},
                            ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

DeviceHoverInfo _info(EditorController app, bool mounting) =>
    mounting
        ? resolveMountingHoverInfo(
          resolver: app.resolver,
          sheetId: 'mounting',
          placementId: 'opaque-placement',
        )!
        : resolveDeviceHoverInfo(
          resolver: app.resolver,
          sheetId: 'schematic',
          deviceId: 'opaque-device',
        )!;

Offset _schematicPoint(WidgetTester tester, EditorController app, Vec2 point) =>
    tester.getTopLeft(find.byType(SchematicCanvas)) +
    app.viewport.worldToLocal(point)!;

Offset _mountingPoint(WidgetTester tester, EditorController app, Vec2 point) {
  final surface = tester.renderObject<RenderBox>(
    find.byKey(const ValueKey('mounting-surface')),
  );
  final sheet = app.sheet;
  final scale = surface.size.width / sheet.width;
  final sheetPoint = MountingTransform(
    sheet,
    sheet.mountingView!,
  ).toSheet(point);
  return surface.localToGlobal(Offset(sheetPoint.x, sheetPoint.y) * scale);
}

Offset _point(WidgetTester tester, EditorController app, bool mounting) =>
    mounting
        ? _mountingPoint(tester, app, const Vec2(150, 110))
        : _schematicPoint(tester, app, const Vec2(400, 300));

Future<void> _dwell(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(_delay);
}

Future<TestGesture> _mouse(WidgetTester tester, Offset position) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: position - const Offset(1, 0));
  await mouse.moveTo(position);
  await _dwell(tester);
  return mouse;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final readOnly in [false, true]) {
    testWidgets(
      'schematic hover and device priority over wires, readOnly=$readOnly',
      (tester) async {
        final app = _app();
        await _show(tester, app, readOnly: readOnly);
        final info = _info(app, false);
        final mouse = await _mouse(
          tester,
          _schematicPoint(tester, app, const Vec2(400, 332)),
        );
        expect(find.text(info.tooltip), findsOneWidget);
        expect(
          tester.widget<WireHoverOverlay>(find.byType(WireHoverOverlay)).info,
          isNull,
        );
        expect(app.project.revision, 0);
        await mouse.moveTo(_schematicPoint(tester, app, const Vec2(400, 410)));
        await _dwell(tester);
        expect(find.text(info.tooltip), findsNothing);
        final wire =
            tester
                .widget<WireHoverOverlay>(find.byType(WireHoverOverlay))
                .info!;
        expect(find.text(wire.tooltip), findsOneWidget);
        await mouse.moveTo(const Offset(2, 2));
        await tester.pump();
        expect(find.text(wire.tooltip), findsNothing);
        await mouse.removePointer();
      },
    );
  }

  testWidgets('schematic hides on drag, pan, scroll, tools and paste', (
    tester,
  ) async {
    final app = _app();
    await _show(tester, app);
    final info = _info(app, false);
    var point = _point(tester, app, false);
    final mouse = await _mouse(tester, point);
    expect(find.text(info.tooltip), findsOneWidget);
    await mouse.down(point);
    await tester.pump();
    expect(app.viewport.hasActiveGesture, isTrue);
    expect(find.text(info.tooltip), findsNothing);
    await mouse.moveBy(const Offset(20, 0));
    await _dwell(tester);
    expect(find.text(info.tooltip), findsNothing);
    await mouse.up();
    await mouse.moveTo(point + const Offset(1, 0));
    await _dwell(tester);
    expect(find.text(info.tooltip), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text(info.tooltip), findsNothing);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await mouse.moveTo(point + const Offset(2, 0));
    await _dwell(tester);
    expect(find.text(info.tooltip), findsOneWidget);
    await tester.sendEventToBinding(
      PointerScrollEvent(position: point, scrollDelta: const Offset(0, 20)),
    );
    await tester.pump();
    expect(find.text(info.tooltip), findsNothing);
    app.setMode(CanvasMode.wire);
    point = _point(tester, app, false);
    await mouse.moveTo(point + const Offset(3, 0));
    await _dwell(tester);
    expect(find.text(info.tooltip), findsNothing);
    app.setMode(CanvasMode.select);
    final fragment = SchematicFragment.capture(
      project: app.project,
      sheet: app.sheet,
      selectedIds: {'opaque-device'},
      sessionId: 'test',
      instanceId: 'test',
      generation: 0,
    );
    final paste = fragment.prepare(
      project: app.project,
      target: app.sheet,
      sessionId: 'test',
      instanceId: 'test',
      generation: 0,
    );
    await _show(tester, app, paste: paste);
    await mouse.moveTo(point + const Offset(4, 0));
    await _dwell(tester);
    expect(find.text(info.tooltip), findsNothing);
    await mouse.removePointer();
  });

  testWidgets(
    'equal document identity and identical project cannot retain schematic hover',
    (tester) async {
      final app = _app();
      final identity = _EqualIdentity();
      await _show(tester, app, identity: identity);
      final point = _point(tester, app, false);
      final mouse = await _mouse(tester, point);
      final info = _info(app, false);
      expect(find.text(info.tooltip), findsOneWidget);
      await _show(tester, app, identity: _EqualIdentity());
      await _dwell(tester);
      expect(find.text(info.tooltip), findsNothing);
      await mouse.moveTo(point + const Offset(1, 0));
      await _dwell(tester);
      expect(find.text(info.tooltip), findsOneWidget);
      app.setSheet('mounting');
      await _dwell(tester);
      expect(find.text(info.tooltip), findsNothing);
      await mouse.removePointer();
    },
  );

  testWidgets(
    'mounting hover uses centered, zoomed and panned paper coordinates',
    (tester) async {
      final app = _app(mounting: true);
      await _show(tester, app, mounting: true);
      final info = _info(app, true);
      final mouse = await _mouse(tester, _point(tester, app, true));
      expect(find.text(info.tooltip), findsOneWidget);
      final beforeSize = tester.getSize(find.text(info.tooltip));
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      viewer.transformationController!.value =
          Matrix4.identity()
            ..translateByDouble(-50, -80, 0, 1)
            ..scaleByDouble(1.4, 1.4, 1, 1);
      await _dwell(tester);
      expect(find.text(info.tooltip), findsNothing);
      final point = _point(tester, app, true);
      await mouse.moveTo(point);
      await _dwell(tester);
      expect(find.text(info.tooltip), findsOneWidget);
      expect(tester.getSize(find.text(info.tooltip)), beforeSize);
      await mouse.down(point);
      await tester.pump();
      expect(app.viewport.hasActiveGesture, isTrue);
      expect(find.text(info.tooltip), findsNothing);
      await mouse.up();
      await tester.pump();
      expect(app.viewport.hasActiveGesture, isFalse);
      await mouse.moveTo(point + const Offset(1, 0));
      await _dwell(tester);
      expect(find.text(info.tooltip), findsOneWidget);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: const Offset(0, 20)),
      );
      await tester.pump();
      expect(find.text(info.tooltip), findsNothing);
      await mouse.removePointer();
    },
  );

  testWidgets(
    'mounting hit follows rotated component outline and viewport clip',
    (tester) async {
      final base = deviceHoverProject();
      final layout = base.mountingLayouts.single;
      final sheet = base.pages.last;
      final app = _app(
        mounting: true,
        project: base.copyWith(
          mountingLayouts: [
            layout.copyWith(
              placements: [layout.placements.single.copyWith(rotation: 90)],
            ),
          ],
          pages: [
            base.pages.first,
            sheet.copyWith(
              mountingView: sheet.mountingView!.copyWith(
                viewport: const RectUnits(
                  x: 40,
                  y: 80,
                  width: 400,
                  height: 600,
                ),
              ),
            ),
          ],
        ),
      );
      await _show(tester, app, mounting: true);
      final info = _info(app, true);
      final mouse = await _mouse(tester, _point(tester, app, true));
      expect(find.text(info.tooltip), findsOneWidget);
      await mouse.moveTo(_mountingPoint(tester, app, const Vec2(115, 110)));
      await _dwell(tester);
      expect(find.text(info.tooltip), findsOneWidget);
      await mouse.moveTo(_mountingPoint(tester, app, const Vec2(150, 145)));
      await _dwell(tester);
      expect(find.text(info.tooltip), findsNothing);
      await mouse.moveTo(_mountingPoint(tester, app, const Vec2(160, 110)));
      await _dwell(tester);
      expect(find.text(info.tooltip), findsNothing);
      await mouse.moveTo(_point(tester, app, true));
      await _dwell(tester);
      expect(find.text(info.tooltip), findsOneWidget);
      await mouse.removePointer();
    },
  );

  for (final mounting in [false, true]) {
    testWidgets(
      'trackpad interaction suppresses new mouse hover, mounting=$mounting',
      (tester) async {
        final app = _app(mounting: mounting);
        await _show(tester, app, mounting: mounting);
        final info = _info(app, mounting);
        final point = _point(tester, app, mounting);
        final mouse = await _mouse(tester, point);
        expect(find.text(info.tooltip), findsOneWidget);
        final trackpad = await tester.createGesture(
          kind: PointerDeviceKind.trackpad,
        );
        await trackpad.panZoomStart(point);
        await tester.pump();
        expect(app.viewport.hasActiveGesture, isTrue);
        expect(find.text(info.tooltip), findsNothing);
        await mouse.moveTo(point + const Offset(1, 0));
        await _dwell(tester);
        expect(find.text(info.tooltip), findsNothing);
        await trackpad.panZoomUpdate(
          point,
          pan: const Offset(10, 15),
          scale: 1.2,
        );
        await trackpad.panZoomEnd();
        await tester.pumpAndSettle();
        expect(app.viewport.hasActiveGesture, isFalse);
        await mouse.moveTo(_point(tester, app, mounting));
        await _dwell(tester);
        expect(find.text(info.tooltip), findsOneWidget);
        await mouse.removePointer();
        await trackpad.removePointer();
      },
    );

    testWidgets(
      'stationary revision and same-ID document switch clear hover, mounting=$mounting',
      (tester) async {
        final project = deviceHoverProject();
        final app = _app(mounting: mounting, project: project);
        await _show(tester, app, mounting: mounting);
        final first = _info(app, mounting);
        final point = _point(tester, app, mounting);
        final mouse = await _mouse(tester, point);
        expect(find.text(first.tooltip), findsOneWidget);
        app.saveComponent(
          app.project.components.first.copyWith(description: 'Změněný popis'),
        );
        await _dwell(tester);
        expect(find.text(first.tooltip), findsNothing);
        await mouse.moveTo(point + const Offset(1, 0));
        await _dwell(tester);
        var edited = _info(app, mounting);
        expect(edited.detail, contains('Změněný popis'));
        expect(find.text(edited.tooltip), findsOneWidget);
        app.saveArticle(
          app.project.articles.single.copyWith(partNumber: 'TEST-99'),
        );
        await _dwell(tester);
        expect(find.text(edited.tooltip), findsNothing);
        await mouse.moveTo(point + const Offset(2, 0));
        await _dwell(tester);
        edited = _info(app, mounting);
        expect(edited.detail, contains('Model: TEST-99'));
        expect(find.text(edited.tooltip), findsOneWidget);
        final second = _app(mounting: mounting, project: app.project);
        await _show(tester, second, mounting: mounting);
        await _dwell(tester);
        expect(find.text(edited.tooltip), findsNothing);
        await mouse.moveTo(
          _point(tester, second, mounting) + const Offset(3, 0),
        );
        await _dwell(tester);
        expect(find.text(edited.tooltip), findsOneWidget);
        second.setMode(CanvasMode.pan);
        await _dwell(tester);
        expect(find.text(edited.tooltip), findsNothing);
        await mouse.removePointer();
      },
    );

    testWidgets(
      'modal, text focus, window focus and lifecycle dismiss hover, mounting=$mounting',
      (tester) async {
        final app = _app(mounting: mounting);
        await _show(tester, app, mounting: mounting);
        final info = _info(app, mounting);
        final point = _point(tester, app, mounting);
        final mouse = await _mouse(tester, point);
        expect(find.text(info.tooltip), findsOneWidget);
        final canvas = find.byType(mounting ? MountingCanvas : SchematicCanvas);
        final context = tester.element(canvas);
        final dialog = showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('Synthetic modal')),
        );
        await tester.pumpAndSettle();
        expect(find.text(info.tooltip), findsNothing);
        Navigator.of(context).pop();
        await tester.pumpAndSettle();
        await dialog;
        expect(find.text(info.tooltip), findsNothing);
        await mouse.moveTo(point + const Offset(1, 0));
        await _dwell(tester);
        expect(find.text(info.tooltip), findsOneWidget);
        void focus(ViewFocusState state) =>
            tester.binding.platformDispatcher.onViewFocusChange?.call(
              ViewFocusEvent(
                viewId: tester.view.viewId,
                state: state,
                direction: ViewFocusDirection.undefined,
              ),
            );
        focus(ViewFocusState.unfocused);
        await _dwell(tester);
        expect(find.text(info.tooltip), findsNothing);
        focus(ViewFocusState.focused);
        await _dwell(tester);
        expect(find.text(info.tooltip), findsNothing);
        await mouse.moveTo(point + const Offset(2, 0));
        await _dwell(tester);
        expect(find.text(info.tooltip), findsOneWidget);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(find.text(info.tooltip), findsNothing);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await mouse.moveTo(point + const Offset(3, 0));
        await _dwell(tester);
        expect(find.text(info.tooltip), findsOneWidget);
        await tester.tap(find.byType(TextField));
        await tester.pump();
        expect(find.text(info.tooltip), findsNothing);
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'workspace switches from schematic to mounting with real mouse hover',
    (tester) async {
      tester.view.physicalSize = const Size(1700, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = _app();
      await tester.pumpWidget(OpenEcadApp(controller: app));
      await tester.pumpAndSettle();
      final mouse = await _mouse(tester, _point(tester, app, false));
      expect(find.text(_info(app, false).tooltip), findsOneWidget);
      app.setSheet('mounting');
      await tester.pumpAndSettle();
      await mouse.moveTo(_point(tester, app, true));
      await _dwell(tester);
      expect(find.text(_info(app, true).tooltip), findsOneWidget);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
