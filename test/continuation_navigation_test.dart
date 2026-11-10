import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/workspace_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'continuation_fixtures.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a visible target near the viewport edge does not pan', (
    tester,
  ) async {
    final app = continuationController();
    await mountContinuations(tester, app);
    final viewport = app.viewport.worldViewport!;
    final point = Vec2(viewport.right - 12, viewport.center.dy);
    app.execute([
      UpdateContinuationMarker(
        app.sheet.id,
        app.sheet.continuationById('same-0')!.copyWith(position: point),
      ),
    ], 'position target');
    await tester.pump();
    await selectContinuation(tester, app);
    final before = app.project;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    expect(app.viewport.worldViewport, viewport);
    expect(app.viewport.continuationFocus, point);
    expect(app.project, same(before));
    await unmountContinuations(tester);
  });

  for (final distant in [false, true]) {
    testWidgets(
      'F reveals same-sheet target, preserves zoom and history (distant=$distant)',
      (tester) async {
        final app = continuationController(
          continuationProject(distant: distant),
        );
        await mountContinuations(tester, app);
        await selectContinuation(tester, app);
        final before = app.project;
        final net = ConnectivityIndex.build(
          before,
        ).net(const ElectricalNode.link('network'));
        final viewport = app.viewport.worldViewport;
        final target = app.sheet.continuationById('same-0')!.position;
        expect(viewport!.contains(Offset(target.x, target.y)), !distant);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pumpAndSettle();
        expect(app.selectedIds, {'same-0'});
        expect(app.viewport.zoom, 1);
        expect(
          app.viewport.worldViewport!.contains(Offset(target.x, target.y)),
          isTrue,
        );
        expect(app.viewport.worldViewport == viewport, !distant);
        expect(app.viewport.continuationFocus, target);
        expect(
          find.byKey(const ValueKey('continuation-focus')),
          findsOneWidget,
        );
        expect(app.project, same(before));
        expect(app.dirty, isFalse);
        expect(app.canUndo, isFalse);
        expect(
          ConnectivityIndex.build(
            app.project,
          ).net(const ElectricalNode.link('network')),
          net,
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(
          location: continuationPoint(tester, app, target),
        );
        await mouse.moveTo(
          continuationPoint(tester, app, target) + const Offset(40, 40),
        );
        await tester.pump();
        expect(app.viewport.continuationFocus, isNull);
        await mouse.removePointer();
        await unmountContinuations(tester);
      },
    );
  }

  testWidgets(
    'F under the mouse opens the right tab in the owning project, even with identical IDs',
    (tester) async {
      final a = continuationController(
        continuationProject(sameSheet: 0, otherSheet: 1),
      );
      final workspace = await mountContinuations(tester, a);
      final b = continuationController(
        a.project.copyWith(name: 'Second project'),
      );
      workspace.add(b);
      workspace.openSheet(b, 'target-sheet');
      workspace.openSheet(a, 'source-sheet');
      await tester.pumpAndSettle();
      a.viewport.reset();
      await tester.pump();
      final aBefore = a.project, bBefore = b.project;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: continuationPoint(tester, a, const Vec2(1200, 800)),
      );
      await mouse.moveTo(continuationPoint(tester, a, const Vec2(1201, 800)));
      await tester.pump();
      expect(a.selectedIds, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(workspace.active, same(a));
      expect(
        workspace.activeTab,
        SheetTab(a.documentSessionId, 'target-sheet'),
      );
      expect(
        workspace.tabs,
        contains(SheetTab(b.documentSessionId, 'target-sheet')),
      );
      expect(a.selectedIds, {'other-0'});
      expect(a.viewport.zoom, 1);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'Schematic canvas',
      );
      expect(a.viewport.continuationFocus, const Vec2(950, 650));
      expect(
        a.viewport.worldViewport!.contains(const Offset(950, 650)),
        isTrue,
      );
      expect(a.project, same(aBefore));
      expect(b.project, same(bBefore));
      expect(b.selectedIds, isEmpty);
      await mouse.removePointer();
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'multiple targets require explicit choice with full page and location',
    (tester) async {
      final app = continuationController(
        continuationProject(sameSheet: 1, otherSheet: 2),
      );
      final workspace = await mountContinuations(tester, app);
      await selectContinuation(tester, app);
      final before = app.project;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(find.text('Vybrat protějšek'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('continuation-picker-search')),
        'CONTROL',
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('=CONTROL+LEFT&SCH/01 · Source sheet'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('=CONTROL+RIGHT&SCH/01 · Destination sheet'),
        ),
        findsNWidgets(2),
      );
      expect(find.textContaining('X 950,0 · Y 550,0'), findsOneWidget);
      expect(app.activeSheetId, 'source-sheet');
      await tester.tap(
        find.byKey(
          const ValueKey(('continuation-target', 'target-sheet', 'other-1')),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        workspace.activeTab,
        SheetTab(app.documentSessionId, 'target-sheet'),
      );
      expect(app.selectedIds, {'other-1'});
      expect(app.viewport.continuationFocus, const Vec2(950, 550));
      expect(app.project, same(before));
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'target click in properties and toolbar share reveal navigation',
    (tester) async {
      final app = continuationController(
        continuationProject(sameSheet: 1, otherSheet: 1),
      );
      await mountContinuations(tester, app, panel: true);
      await selectContinuation(tester, app);
      await tester.pumpAndSettle();
      final before = app.project;
      final target = find.byKey(
        const ValueKey(('continuation-target', 'target-sheet', 'other-0')),
      );
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(app.activeSheetId, 'target-sheet');
      expect(app.selectedIds, {'other-0'});
      expect(app.viewport.continuationFocus, const Vec2(950, 650));
      await tester.tap(find.byTooltip('Přejít na protějšek · F'));
      await tester.pumpAndSettle();
      expect(find.text('Vybrat protějšek'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('continuation-picker-search')),
        'CONTROL',
      );
      await tester.pumpAndSettle();
      await continuationClick(tester, 'Zrušit');
      expect(app.project, same(before));
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'orphan F is explicit and leaves model, viewport and selection unchanged',
    (tester) async {
      final app = continuationController(continuationProject(sameSheet: 0));
      await mountContinuations(tester, app);
      await selectContinuation(tester, app);
      final before = app.project, viewport = app.viewport.worldViewport;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(app.status, contains('nemá protějšek'));
      expect(app.project, same(before));
      expect(app.viewport.worldViewport, viewport);
      expect(app.selectedIds, {'source'});
      expect(app.canUndo, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      await unmountContinuations(tester);
    },
  );

  for (final change in [
    'switch',
    'switch-back',
    'replace',
    'delete-source',
    'delete-target',
    'delete-sheet',
    'close',
  ]) {
    testWidgets('late target picker refuses $change', (tester) async {
      final app = continuationController(
        continuationProject(sameSheet: 1, otherSheet: 1),
      );
      final workspace = await mountContinuations(tester, app);
      await selectContinuation(tester, app);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('continuation-picker-search')),
        'other-0',
      );
      await tester.pumpAndSettle();
      final b = continuationController(
        app.project.copyWith(name: 'Other owner'),
      );
      switch (change) {
        case 'switch':
        case 'switch-back':
          workspace.add(b);
          if (change == 'switch-back') workspace.openSheet(app, 'source-sheet');
        case 'replace':
          app.newProject();
          b.dispose();
        case 'delete-source':
          app.execute([
            DeleteContinuationMarker('source-sheet', 'source'),
          ], 'remove');
          b.dispose();
        case 'delete-target':
          app.execute([
            DeleteContinuationMarker('target-sheet', 'other-0'),
          ], 'remove');
          b.dispose();
        case 'delete-sheet':
          app.execute([DeleteSheet('target-sheet')], 'remove');
          b.dispose();
        case 'close':
          workspace.add(b);
          await workspace.closeDocument(app);
      }
      await tester.pumpAndSettle();
      final active = workspace.active;
      final before = active.project, sheet = active.activeSheetId;
      final target = find.byKey(
        const ValueKey(('continuation-target', 'target-sheet', 'other-0')),
      );
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(workspace.active, same(active));
      expect(active.activeSheetId, sheet);
      expect(active.project, same(before));
      expect(active.viewport.continuationFocus, isNull);
      expect(find.textContaining('Zavřete výběr'), findsOneWidget);
      await unmountContinuations(tester);
    });
  }

  testWidgets(
    'a queued reveal cannot land after a project switch before the next frame',
    (tester) async {
      final a = continuationController(
        continuationProject(sameSheet: 0, otherSheet: 1),
      );
      final workspace = await mountContinuations(tester, a);
      await selectContinuation(tester, a);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      final b = continuationController(a.project.copyWith(name: 'Other owner'));
      workspace.add(b);
      await tester.pumpAndSettle();
      expect(workspace.active, same(b));
      expect(b.viewport.continuationFocus, isNull);
      expect(b.selectedIds, isEmpty);
      expect(b.canUndo, isFalse);
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'command palette captures the original marker and rejects a switched owner',
    (tester) async {
      final app = continuationController();
      final workspace = await mountContinuations(tester, app);
      await selectContinuation(tester, app);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      final input = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Hledat příkaz…',
      );
      await tester.enterText(input, 'Přejít na protějšek');
      await tester.pumpAndSettle();
      final b = continuationController(
        app.project.copyWith(name: 'Second owner'),
      );
      workspace.add(b);
      await tester.pumpAndSettle();
      final before = b.project;
      await continuationClick(tester, 'Přejít na protějšek odkazu');
      expect(b.project, same(before));
      expect(b.selectedIds, isEmpty);
      expect(b.viewport.continuationFocus, isNull);
      expect(find.textContaining('Zopakujte akci'), findsOneWidget);
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'editor target click uses the same reveal without saving draft edits',
    (tester) async {
      final app = continuationController(
        continuationProject(sameSheet: 0, otherSheet: 1),
      );
      await mountContinuations(tester, app);
      await selectContinuation(tester, app);
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      await tester.enterText(continuationField('Poloha X'), '900');
      final target = find.byKey(
        const ValueKey(('continuation-target', 'target-sheet', 'other-0')),
      );
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(app.selectedIds, {'other-0'});
      expect(app.viewport.continuationFocus, const Vec2(950, 650));
      expect(app.project.revision, 0);
      expect(
        app.project.pages.first.continuationById('source')!.position,
        const Vec2(1200, 800),
      );
      await unmountContinuations(tester);
    },
  );
}
