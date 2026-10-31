import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'continuation_fixtures.dart';

Future<void> editSource(WidgetTester tester, EditorController app) async {
  await selectContinuation(tester, app);
  await tester.sendKeyEvent(LogicalKeyboardKey.f4);
  await tester.pumpAndSettle();
}

Future<void> selectNetwork(WidgetTester tester, String text) async {
  final picker = find.byKey(const ValueKey('continuation-link-picker'));
  await tester.ensureVisible(picker);
  await tester.tap(picker);
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('continuation-picker-search')),
    text.split(' · ').last,
  );
  await tester.pumpAndSettle();
  await continuationClick(tester, text);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'controller requires explicit link identity and never merges by label',
    () {
      final app = continuationController();
      addTearDown(app.dispose);
      final before = app.project;
      expect(
        app.addContinuation(position: const Vec2(500, 500), label: 'SIGNAL'),
        isFalse,
      );
      expect(app.project, same(before));
      expect(
        app.addContinuation(
          position: const Vec2(500, 500),
          label: 'SIGNAL',
          linkId: 'network',
        ),
        isTrue,
      );
      expect(app.sheet.continuations.last.linkId, 'network');
      expect(app.project.continuationLinks, hasLength(2));
    },
  );

  testWidgets(
    'toolbar places at the clicked point, explicit existing network and one-step undo',
    (tester) async {
      final app = continuationController();
      await mountContinuations(tester, app);
      final before = app.project.toJson();
      await tester.tap(find.byTooltip('Vložit pokračovací odkaz'));
      await tester.pump();
      expect(app.mode, CanvasMode.continuation);
      await tester.tapAt(continuationPoint(tester, app, const Vec2(1113, 913)));
      await tester.pumpAndSettle();
      expect(find.text('Vložit pokračovací odkaz'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(continuationField('Poloha X'))
            .controller!
            .text,
        '1110,0',
      );
      expect(
        tester
            .widget<TextField>(continuationField('Poloha Y'))
            .controller!
            .text,
        '910,0',
      );
      await selectNetwork(tester, 'SIGNAL · network');
      expect(
        tester.widget<TextField>(continuationField('Označení sítě')).enabled,
        isFalse,
      );
      await continuationClick(tester, 'Uložit');
      expect(app.project.continuationLinks, hasLength(2));
      final marker = app.sheet.continuations.last;
      expect(marker.linkId, 'network');
      expect(marker.position, const Vec2(1110, 910));
      expect(app.selectedIds, {marker.id});
      expect(app.mode, CanvasMode.select);
      expect(app.project.revision, 1);
      app.undo();
      expect(app.project.copyWith(revision: 0).toJson(), before);
      expect(app.canUndo, isFalse);
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'a new named network and marker commit atomically at the chosen point',
    (tester) async {
      final app = continuationController();
      await mountContinuations(tester, app);
      await tester.tap(find.byTooltip('Vložit pokračovací odkaz'));
      await tester.pump();
      await tester.tapAt(continuationPoint(tester, app, const Vec2(1100, 900)));
      await tester.pumpAndSettle();
      await tester.enterText(continuationField('Označení sítě'), 'NEW SIGNAL');
      await continuationClick(tester, 'Uložit');
      final marker = app.sheet.continuations.last;
      expect(marker.linkId, isNot('network'));
      expect(
        app.project.continuationLinkById(marker.linkId)!.label,
        'NEW SIGNAL',
      );
      expect(app.project.revision, 1);
      app.undo();
      expect(app.project.continuationLinkById(marker.linkId), isNull);
      expect(app.sheet.continuationById(marker.id), isNull);
      expect(app.canUndo, isFalse);
      await unmountContinuations(tester);
    },
  );

  for (final method in ['double-click', 'F4']) {
    testWidgets(
      '$method edits continuation with the inspector closed and preserves wiring',
      (tester) async {
        final app = continuationController();
        await mountContinuations(tester, app);
        await selectContinuation(tester, app);
        if (method == 'double-click') {
          await tester.pump(const Duration(milliseconds: 70));
          await selectContinuation(tester, app);
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.f4);
        }
        await tester.pumpAndSettle();
        expect(find.text('Upravit pokračovací odkaz'), findsOneWidget);
        final wire = app.sheet.wires.single;
        await tester.enterText(continuationField('Poloha X'), '1210');
        await continuationClick(tester, 'Uložit');
        expect(
          app.sheet.continuationById('source')!.position,
          const Vec2(1210, 800),
        );
        expect(app.project.continuationLinkById('network')!.label, 'SIGNAL');
        expect(app.sheet.wires.single.to, wire.to);
        expect(app.sheet.wires.single.id, wire.id);
        app.undo();
        expect(
          app.sheet.continuationById('source')!.position,
          const Vec2(1200, 800),
        );
        expect(app.canUndo, isFalse);
        await unmountContinuations(tester);
      },
    );
  }

  testWidgets(
    'shared rename is explicit; reassignment does not rename either network',
    (tester) async {
      final app = continuationController();
      await mountContinuations(tester, app);
      await editSource(tester, app);
      expect(
        tester.widget<TextField>(continuationField('Označení sítě')).enabled,
        isFalse,
      );
      await continuationClick(tester, 'Přejmenovat společnou síť');
      await tester.enterText(continuationField('Označení sítě'), 'RENAMED');
      await continuationClick(tester, 'Uložit');
      expect(app.project.continuationLinkById('network')!.label, 'RENAMED');
      expect(
        app.sheet.continuations.every((m) => m.linkId == 'network'),
        isTrue,
      );
      app.undo();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      await selectNetwork(tester, 'RETURN · second-network');
      expect(
        find.textContaining('Přepojení změní elektrickou síť'),
        findsOneWidget,
      );
      await continuationClick(tester, 'Uložit');
      expect(app.sheet.continuationById('source')!.linkId, 'second-network');
      expect(app.sheet.continuationById('same-0')!.linkId, 'network');
      expect(app.project.continuationLinkById('network')!.label, 'SIGNAL');
      expect(
        app.project.continuationLinkById('second-network')!.label,
        'RETURN',
      );
      expect(
        app.sheet.wires.single.to,
        const ContinuationRef(markerId: 'source'),
      );
      app.undo();
      expect(app.sheet.continuationById('source')!.linkId, 'network');
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'peer placement chooses a page then places in the same identified network',
    (tester) async {
      final app = continuationController();
      await mountContinuations(tester, app, panel: true);
      await selectContinuation(tester, app);
      await tester.pumpAndSettle();
      await continuationClick(tester, 'Další marker této sítě…');
      await tester.enterText(
        find.byKey(const ValueKey('continuation-picker-search')),
        'target-sheet',
      );
      await tester.pumpAndSettle();
      await continuationClick(
        tester,
        '=CONTROL+RIGHT&SCH/01 · Destination sheet',
      );
      expect(app.activeSheetId, 'target-sheet');
      expect(app.mode, CanvasMode.continuation);
      await tester.tapAt(continuationPoint(tester, app, const Vec2(500, 400)));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(continuationField('Označení sítě'))
            .controller!
            .text,
        'SIGNAL',
      );
      await continuationClick(tester, 'Uložit');
      expect(app.sheet.continuations.last.linkId, 'network');
      expect(app.sheet.continuations.last.position, const Vec2(500, 400));
      expect(app.project.continuationLinks, hasLength(2));
      await unmountContinuations(tester);
    },
  );

  for (final change in [
    'switch',
    'switch-back',
    'sheet',
    'replace',
    'delete',
    'delete-sheet',
    'close',
  ]) {
    testWidgets(
      'late save refuses $change and cannot write into matching IDs',
      (tester) async {
        final app = continuationController();
        final workspace = await mountContinuations(tester, app);
        await editSource(tester, app);
        await tester.enterText(continuationField('Poloha X'), '999');
        final b = continuationController(
          app.project.copyWith(name: 'Second project'),
        );
        switch (change) {
          case 'switch':
          case 'switch-back':
            workspace.add(b);
            if (change == 'switch-back') {
              workspace.openSheet(app, 'source-sheet');
            }
          case 'sheet':
            workspace.openSheet(app, 'target-sheet');
            b.dispose();
          case 'replace':
            app.newProject();
            b.dispose();
          case 'delete':
            app.execute([
              DeleteContinuationMarker('source-sheet', 'source'),
            ], 'remove');
            b.dispose();
          case 'delete-sheet':
            app.execute([DeleteSheet('source-sheet')], 'remove');
            b.dispose();
          case 'close':
            workspace.add(b);
            workspace.closeDocument(app);
        }
        await tester.pumpAndSettle();
        final active = workspace.active;
        final activeBefore = active.project, ownerBefore = app.project;
        await continuationClick(tester, 'Uložit');
        expect(find.textContaining('Otevřete editor znovu'), findsOneWidget);
        expect(active.project, same(activeBefore));
        expect(app.project, same(ownerBefore));
        await unmountContinuations(tester);
      },
    );
  }

  testWidgets('typing F, F4 and Home in editor does not navigate or fit', (
    tester,
  ) async {
    final app = continuationController();
    await mountContinuations(tester, app);
    await editSource(tester, app);
    final viewport = app.viewport.worldViewport;
    await continuationClick(tester, 'Přejmenovat společnou síť');
    await tester.enterText(continuationField('Označení sítě'), 'F');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(app.selectedIds, {'source'});
    expect(app.viewport.worldViewport, viewport);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(app.project.revision, 0);
    await continuationClick(tester, 'Zrušit');
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(app.viewport.zoom, lessThan(1));
    await unmountContinuations(tester);
  });

  testWidgets(
    'F and F4 during a pending wire leave it intact and finish its original endpoints',
    (tester) async {
      final app = continuationController();
      await mountContinuations(tester, app);
      app.setMode(CanvasMode.wire);
      await tester.pump();
      await tester.tapAt(continuationPoint(tester, app, const Vec2(1200, 800)));
      await tester.pump();
      expect(app.viewport.hasActiveGesture, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(app.viewport.hasActiveGesture, isTrue);
      await tester.tapAt(continuationPoint(tester, app, const Vec2(1350, 800)));
      await tester.pumpAndSettle();
      expect(app.sheet.wires, hasLength(2));
      expect(
        app.sheet.wires.last.from,
        const ContinuationRef(markerId: 'source'),
      );
      expect(
        app.sheet.wires.last.to,
        const ContinuationRef(markerId: 'same-0'),
      );
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'F4 and F during a drag neither edit nor jump and the move commits once',
    (tester) async {
      final app = continuationController();
      await mountContinuations(tester, app);
      final start = continuationPoint(tester, app, const Vec2(1200, 800));
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(app.viewport.continuationFocus, isNull);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        app.sheet.continuationById('source')!.position,
        const Vec2(1220, 800),
      );
      expect(app.project.revision, 1);
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'assistant text focus and Alt+F4 do not edit or navigate a selected marker',
    (tester) async {
      final app = continuationController();
      await mountContinuations(tester, app, panel: true);
      await selectContinuation(tester, app);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      final input = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == 'Co chcete ve schématu změnit?',
      );
      await tester.enterText(input, 'F text');
      final viewport = app.viewport.worldViewport;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(app.selectedIds, {'source'});
      expect(app.viewport.worldViewport, viewport);
      expect(find.byType(AlertDialog), findsNothing);
      expect(app.project.revision, 0);
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'pending graphic drawing keeps its gesture through F, F4 and Home',
    (tester) async {
      final app = continuationController();
      await mountContinuations(tester, app);
      app.select({'source'});
      app.setMode(CanvasMode.drawLine);
      await tester.pump();
      final gesture = await tester.startGesture(
        continuationPoint(tester, app, const Vec2(1100, 950)),
      );
      await gesture.moveBy(const Offset(80, 40));
      await tester.pump();
      final viewport = app.viewport.worldViewport;
      for (final key in [
        LogicalKeyboardKey.keyF,
        LogicalKeyboardKey.f4,
        LogicalKeyboardKey.home,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(app.viewport.worldViewport, viewport);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(app.sheet.graphics, hasLength(1));
      expect(app.sheet.graphics.single.width, 80);
      expect(app.project.revision, 1);
      await unmountContinuations(tester);
    },
  );
}
