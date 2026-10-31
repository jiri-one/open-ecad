import 'dart:async';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'clipboard_workspace_test.dart' show shortcut;
import 'continuation_fixtures.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'history shows labels, jumps multiple steps in one change, then redo and clears branch',
    (tester) async {
      final app = continuationController();
      await mountContinuations(tester, app);
      app.renameProject('First');
      app.addContinuation(position: const Vec2(1300, 900), label: 'NEW');
      app.renameSheet('Second');
      final revision = app.project.revision;
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('Vrátit · Ctrl Z\n${app.undoLabel}'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Historie úprav'));
      await tester.pumpAndSettle();
      expect(find.text('Aktuální stav'), findsOneWidget);
      expect(find.text('Vrátit tyto 3 kroky'), findsOneWidget);
      var changes = 0;
      void changed() => changes++;
      app.addListener(changed);
      await tester.tap(find.text('Vrátit tyto 3 kroky'));
      await tester.pumpAndSettle();
      app.removeListener(changed);
      expect(changes, 1);
      expect(app.project.revision, revision + 3);
      expect(app.canUndo, isFalse);
      expect(app.redoHistory.length, 3);
      expect(app.project.name, 'Synthetic continuation editor');
      await tester.tap(find.byTooltip('Historie úprav'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Obnovit tyto 2 kroky'));
      await tester.pumpAndSettle();
      expect(app.project.name, 'First');
      expect(app.sheet.continuations.length, 3);
      expect(app.canRedo, isTrue);
      app.renameProject('New branch');
      await tester.pump();
      expect(app.redoHistory, isEmpty);
      await unmountContinuations(tester);
    },
  );

  for (final change in [
    'switch',
    'away-back',
    'replace',
    'revision',
    'close',
  ]) {
    testWidgets(
      'open history cannot mutate a stale $change owner with matching IDs',
      (tester) async {
        final root = continuationController();
        final workspace = await mountContinuations(tester, root);
        final app = continuationController(root.project);
        workspace.add(app);
        app.renameProject('First');
        app.renameSheet('Second');
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Historie úprav'));
        await tester.pumpAndSettle();
        switch (change) {
          case 'switch':
            workspace.openSheet(root, root.activeSheetId);
          case 'away-back':
            workspace.openSheet(root, root.activeSheetId);
            workspace.openSheet(app, app.activeSheetId);
          case 'replace':
            app.newProject();
          case 'revision':
            app.renameProject('Third');
          case 'close':
            workspace.closeDocument(app);
        }
        final before = app.project, active = workspace.active.project;
        await tester.pumpAndSettle();
        await tester.tap(find.text('Vrátit tyto 2 kroky'));
        await tester.pumpAndSettle();
        expect(app.project, same(before));
        expect(workspace.active.project, same(active));
        expect(find.textContaining('Historie už nepatří'), findsOneWidget);
        await unmountContinuations(tester);
      },
    );
  }

  testWidgets(
    'history cancels pending clipboard read; Ctrl Z cancels a preview even with empty history',
    (tester) async {
      final pending = Completer<Object?>();
      String copied = '';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
              return null;
            }
            if (call.method == 'Clipboard.getData') return pending.future;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final app = continuationController();
      await mountContinuations(tester, app);
      await selectContinuation(tester, app);
      await shortcut(tester, LogicalKeyboardKey.keyC);
      await shortcut(tester, LogicalKeyboardKey.keyV);
      await tester.tap(find.byTooltip('Historie úprav'));
      await tester.pumpAndSettle();
      pending.complete({'text': copied});
      await tester.pumpAndSettle();
      expect(app.pastePreview, isNull);
      await tester.tap(find.text('Zavřít').last);
      await tester.pumpAndSettle();
      app.viewport.focus();
      await tester.pump();
      await shortcut(tester, LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      expect(app.pastePreview, isNotNull);
      await shortcut(tester, LogicalKeyboardKey.keyZ);
      await tester.pumpAndSettle();
      expect(app.pastePreview, isNull);
      expect(find.byKey(const ValueKey('clipboard-preview')), findsNothing);
      expect(app.project.revision, 0);
      await unmountContinuations(tester);
    },
  );

  testWidgets('history is reachable in command palette', (tester) async {
    final app = continuationController();
    await mountContinuations(tester, app);
    app.renameProject('Edited');
    await tester.pump();
    await shortcut(tester, LogicalKeyboardKey.keyK);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Historie');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Historie úprav'));
    await tester.pumpAndSettle();
    expect(find.text('Aktuální stav'), findsOneWidget);
    await tester.tap(find.text('Vrátit tento krok'));
    await tester.pumpAndSettle();
    expect(app.canUndo, isFalse);
    await unmountContinuations(tester);
  });
}
