import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/schematic_annotations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'continuation_fixtures.dart';

dynamic painter(WidgetTester tester) =>
    tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(SchematicCanvas),
            matching: find.byType(CustomPaint),
          ),
        )
        .firstWhere(
          (w) => w.painter.runtimeType.toString() == '_SchematicPainter',
        )
        .painter;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final rebuild in [false, true]) {
    for (final undo in [false, true]) {
      testWidgets(
        'continuation press cancels a network change, rebuild=$rebuild undo=$undo',
        (tester) async {
          final app = continuationController(
            continuationProject(sameSheet: 0, otherSheet: 1),
          );
          await mountContinuations(tester, app);
          final marker = app.sheet.continuationById('source')!;
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await mouse.down(continuationPoint(tester, app, marker.position));
          expect(
            app.execute([
              UpdateContinuationMarker(
                app.sheet.id,
                marker.copyWith(linkId: 'second-network'),
              ),
            ], 'Change continuation network'),
            isTrue,
          );
          if (undo) app.undo();
          if (rebuild) await tester.pump();
          await mouse.up();
          await tester.pumpAndSettle();
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          expect(app.sheet.id, 'source-sheet');
          expect(app.selectedIds, isEmpty);
          expect(
            app.sheet.continuationById('source')!.linkId,
            undo ? 'network' : 'second-network',
          );
          await mouse.removePointer();
          await unmountContinuations(tester);
        },
      );
    }
  }
  for (final label in [false, true]) {
    testWidgets(
      'continuation hover underlines before Ctrl and Ctrl click follows, label=$label',
      (tester) async {
        final app = continuationController(
          continuationProject(sameSheet: 0, otherSheet: 1),
        );
        await mountContinuations(tester, app);
        final before = app.project;
        final marker = app.sheet.continuationById('source')!;
        final reference =
            layoutContinuationCrossReference(app.project, app.sheet, marker)!;
        final point = continuationPoint(
          tester,
          app,
          label
              ? Vec2(reference.bounds.center.dx, reference.bounds.center.dy)
              : marker.position,
        );
        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          pointer: 1,
        );
        await mouse.addPointer(location: point - const Offset(1, 0));
        await mouse.moveTo(point);
        await tester.pump();
        expect(painter(tester).activeContinuationLink, 'source');
        expect(
          tester.binding.mouseTracker.debugDeviceActiveCursor(1),
          isNot(SystemMouseCursors.click),
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(
          tester.binding.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.click,
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(painter(tester).activeContinuationLink, 'source');
        expect(
          tester.binding.mouseTracker.debugDeviceActiveCursor(1),
          isNot(SystemMouseCursors.click),
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await mouse.down(point);
        await mouse.up();
        await tester.pumpAndSettle();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        expect(app.sheet.id, 'target-sheet');
        expect(app.selectedIds, {'other-0'});
        expect(app.viewport.continuationFocus, const Vec2(950, 650));
        expect(painter(tester).activeContinuationLink, isNull);
        expect(app.project, same(before));
        await mouse.removePointer();
        await unmountContinuations(tester);
      },
    );
  }
  testWidgets(
    'continuation hover clears on link exit, sheet switch, and tool change',
    (tester) async {
      final app = continuationController();
      await mountContinuations(tester, app);
      final point = continuationPoint(
        tester,
        app,
        app.sheet.continuationById('source')!.position,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: point);
      await mouse.moveTo(point);
      await tester.pump();
      expect(painter(tester).activeContinuationLink, 'source');
      await mouse.moveTo(point + const Offset(-60, -60));
      await tester.pump();
      expect(painter(tester).activeContinuationLink, isNull);
      await mouse.moveTo(point);
      await tester.pump();
      app.setMode(CanvasMode.pan);
      await tester.pump();
      expect(painter(tester).activeContinuationLink, isNull);
      app.setMode(CanvasMode.select);
      app.setSheet('target-sheet');
      await tester.pumpAndSettle();
      app.setSheet('source-sheet');
      await tester.pumpAndSettle();
      expect(painter(tester).activeContinuationLink, isNull);
      await mouse.removePointer();
      await unmountContinuations(tester);
    },
  );
  testWidgets('a dangling continuation is not styled or activated as a link', (
    tester,
  ) async {
    final app = continuationController(continuationProject(sameSheet: 0));
    await mountContinuations(tester, app);
    final point = continuationPoint(
      tester,
      app,
      app.sheet.continuationById('source')!.position,
    );
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 1,
    );
    await mouse.addPointer(location: point);
    await mouse.moveTo(point);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(painter(tester).activeContinuationLink, isNull);
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      isNot(SystemMouseCursors.click),
    );
    await mouse.down(point);
    await mouse.up();
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(app.sheet.id, 'source-sheet');
    expect(app.project.revision, 0);
    await mouse.removePointer();
    await unmountContinuations(tester);
  });
}
