import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'continuation_fixtures.dart';

Future<void> chooseEarth(WidgetTester tester) async {
  await tester.tap(find.text('Značky'));
  await tester.pumpAndSettle();
  final search = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == 'Najít symbol…',
  );
  await tester.enterText(search, 'Ochranné uzemnění');
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Vložit: Ochranné uzemnění'));
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'library PE uses the shared editor for first and repeated placement',
    (tester) async {
      final app = continuationController();
      await mountContinuations(tester, app);
      final original = app.project;
      await chooseEarth(tester);
      expect(app.mode, CanvasMode.continuation);
      await tester.tapAt(continuationPoint(tester, app, const Vec2(1100, 900)));
      await tester.pumpAndSettle();
      expect(find.text('Vložit pokračovací odkaz'), findsOneWidget);
      expect(app.project, same(original));
      expect(
        tester
            .widget<TextField>(continuationField('Označení sítě'))
            .controller!
            .text,
        'PE',
      );
      expect(
        tester
            .widget<DropdownButtonFormField<ContinuationGlyph>>(
              find.byType(DropdownButtonFormField<ContinuationGlyph>),
            )
            .initialValue,
        ContinuationGlyph.earth,
      );
      await continuationClick(tester, 'Uložit');
      final first =
          app.sheet.continuations
              .where((m) => m.glyph == ContinuationGlyph.earth)
              .single;
      expect(first.position, const Vec2(1100, 900));
      expect(app.project.continuationLinkById(first.linkId)!.label, 'PE');
      final beforeSecond = app.project;
      await chooseEarth(tester);
      await tester.tapAt(continuationPoint(tester, app, const Vec2(1200, 900)));
      await tester.pumpAndSettle();
      expect(app.project, same(beforeSecond));
      await tester.tap(find.byKey(const ValueKey('continuation-link-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('continuation-picker-search')),
        first.linkId,
      );
      await tester.pumpAndSettle();
      await continuationClick(tester, 'PE · ${first.linkId}');
      await continuationClick(tester, 'Uložit');
      final terminals =
          app.sheet.continuations
              .where((m) => m.glyph == ContinuationGlyph.earth)
              .toList();
      expect(terminals, hasLength(2));
      expect(terminals.map((m) => m.linkId).toSet(), {first.linkId});
      expect(
        app.project.continuationLinks.length,
        beforeSecond.continuationLinks.length,
      );
      app.undo();
      expect(
        app.project.copyWith(revision: beforeSecond.revision).toJson(),
        beforeSecond.toJson(),
      );
      await unmountContinuations(tester);
    },
  );

  testWidgets('cancelled library PE editor leaves no network or marker', (
    tester,
  ) async {
    final app = continuationController();
    await mountContinuations(tester, app);
    final original = app.project;
    await chooseEarth(tester);
    await tester.tapAt(continuationPoint(tester, app, const Vec2(1100, 900)));
    await tester.pumpAndSettle();
    await continuationClick(tester, 'Zrušit');
    expect(app.project, same(original));
    expect(app.canUndo, isFalse);
    app.setContinuationTool();
    expect(app.placingContinuationGlyph, ContinuationGlyph.arrow);
    expect(app.placingContinuationLabel, isEmpty);
    await unmountContinuations(tester);
  });

  for (final transform in ['fit', 'reset', 'zoom']) {
    testWidgets('F hit-tests the stationary pointer after $transform', (
      tester,
    ) async {
      final app = continuationController();
      await mountContinuations(tester, app);
      if (transform == 'reset') {
        app.viewport.fit();
        await tester.pump();
      }
      final point = continuationPoint(tester, app, const Vec2(1350, 800));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: point);
      await mouse.moveTo(point + const Offset(1, 0));
      await tester.pump();
      expect(app.viewport.hoveredContinuationId, 'same-0');
      expect(app.selectedIds, isEmpty);
      final original = app.project;
      switch (transform) {
        case 'fit':
          await tester.sendKeyEvent(LogicalKeyboardKey.home);
        case 'reset':
          app.viewport.reset();
        case 'zoom':
          app.viewport.zoomOut();
      }
      await tester.pumpAndSettle();
      expect(
        (continuationPoint(tester, app, const Vec2(1350, 800)) - point)
            .distance,
        greaterThan(12),
      );
      expect(app.viewport.hoveredContinuationId, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(app.selectedIds, isEmpty);
      expect(app.viewport.continuationFocus, isNull);
      expect(app.project, same(original));
      await mouse.removePointer();
      await unmountContinuations(tester);
    });
  }

  testWidgets('F hit-tests the current scene after a marker moves away', (
    tester,
  ) async {
    final app = continuationController();
    await mountContinuations(tester, app);
    final point = continuationPoint(tester, app, const Vec2(1350, 800));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: point);
    await mouse.moveTo(point + const Offset(1, 0));
    await tester.pump();
    expect(app.viewport.hoveredContinuationId, 'same-0');
    app.execute([
      UpdateContinuationMarker(
        app.sheet.id,
        app.sheet
            .continuationById('same-0')!
            .copyWith(position: const Vec2(1700, 1000)),
      ),
    ], 'Move marker');
    await tester.pumpAndSettle();
    final changed = app.project;
    expect(app.viewport.hoveredContinuationId, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    expect(app.selectedIds, isEmpty);
    expect(app.project, same(changed));
    await mouse.removePointer();
    await unmountContinuations(tester);
  });
}
