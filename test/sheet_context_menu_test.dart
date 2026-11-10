// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace_controller.dart';
import 'package:open_ecad/widgets/sheet_context_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_editing_feedback_test.dart' show MemoryPersistence;

Future<WorkspaceController> _mount(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1000, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  EditorController document(String name) => EditorController(
    initialProject: EcadProject(
      id: 'synthetic-project',
      name: name,
      pages: [
        Sheet(id: 'first', number: '1', name: '$name first'),
        Sheet(id: 'target', number: '10', name: '$name target'),
        Sheet(id: 'last', number: '2', name: '$name last'),
      ],
    ),
    persistence: MemoryPersistence(),
  );
  final foreground = document('Foreground');
  final background = document('Background');
  final workspace = WorkspaceController(foreground)..add(background);
  workspace.openSheet(foreground, 'first');
  addTearDown(() {
    workspace.dispose();
    foreground.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: workspace,
          builder: (context, _) {
            final sheet = background.project.sheetById('target')!;
            void rename() =>
                workspace.active.renameSheet('Renamed background sheet');
            return Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                child: SheetContextMenu(
                  controller: background,
                  sheet: sheet,
                  workspace: workspace,
                  onRenameSheet: rename,
                  child: ListTile(
                    title: Text(sheet.name),
                    onTap:
                        () => workspace.openSheet(
                          background,
                          sheet.id,
                          newTab: false,
                        ),
                    trailing: SheetContextMenu(
                      controller: background,
                      sheet: sheet,
                      workspace: workspace,
                      onRenameSheet: rename,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return workspace;
}

Future<void> _open(WidgetTester tester, {required bool rightClick}) async {
  if (rightClick) {
    await tester.tap(find.byType(ListTile), buttons: kSecondaryMouseButton);
  } else {
    await tester.tap(find.byIcon(Icons.more_vert));
  }
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final rightClick in [true, false]) {
    final entry = rightClick ? 'right-click row' : 'three-dot menu';

    testWidgets('$entry has no reorder actions and dismissal changes nothing', (
      tester,
    ) async {
      final workspace = await _mount(tester);
      final foreground = workspace.active;
      final background = workspace.documents.last;
      background.renameProject('Edited background');
      background.renameSheet('Temporary name');
      background.undo();
      final projects = [for (final doc in workspace.documents) doc.project];
      final snapshots = [for (final project in projects) project.toJson()];
      final history = [
        for (final entry in background.undoHistory) (entry.label, entry.steps),
      ];
      final redo = [
        for (final entry in background.redoHistory) (entry.label, entry.steps),
      ];
      final tabs = workspace.tabs;
      final activeTab = workspace.activeTab;
      expect(history, hasLength(1));
      expect(redo, hasLength(1));

      void expectUnchanged() {
        for (var i = 0; i < workspace.documents.length; i++) {
          final doc = workspace.documents[i];
          expect(doc.project, same(projects[i]));
          expect(doc.project.toJson(), snapshots[i]);
          expect(doc.project.pages.map((sheet) => sheet.id), [
            'first',
            'target',
            'last',
          ]);
          expect(doc.activeSheetId, 'first');
        }
        expect(foreground.dirty, isFalse);
        expect(foreground.undoHistory, isEmpty);
        expect(foreground.redoHistory, isEmpty);
        expect(background.changesSaved, isTrue);
        expect([
          for (final entry in background.undoHistory)
            (entry.label, entry.steps),
        ], history);
        expect([
          for (final entry in background.redoHistory)
            (entry.label, entry.steps),
        ], redo);
        expect(workspace.active, same(foreground));
        expect(workspace.tabs, tabs);
        expect(workspace.activeTab, activeTab);
      }

      await _open(tester, rightClick: rightClick);
      expect(find.text('Otevřít list'), findsOneWidget);
      expect(find.text('Posunout výše'), findsNothing);
      expect(find.text('Posunout níže'), findsNothing);
      expectUnchanged();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Otevřít list'), findsNothing);
      expectUnchanged();
      expect(tester.takeException(), isNull);
    });

    for (final newTab in [false, true]) {
      testWidgets('$entry opens the clicked sheet (newTab=$newTab)', (
        tester,
      ) async {
        final workspace = await _mount(tester);
        final foreground = workspace.active;
        final background = workspace.documents.last;
        final projects = [foreground.project, background.project];
        final foregroundTab = workspace.activeTab;
        await _open(tester, rightClick: rightClick);
        await tester.tap(
          find.text(newTab ? 'Otevřít v novém tabu' : 'Otevřít list'),
        );
        await tester.pumpAndSettle();
        expect(workspace.active, same(background));
        expect(background.activeSheetId, 'target');
        expect(foreground.activeSheetId, 'first');
        expect(
          workspace.activeTab,
          SheetTab(background.documentSessionId, 'target'),
        );
        expect(workspace.tabs, hasLength(newTab ? 3 : 2));
        expect(workspace.tabs.contains(foregroundTab), newTab);
        for (var i = 0; i < workspace.documents.length; i++) {
          final doc = workspace.documents[i];
          expect(doc.project, same(projects[i]));
          expect(doc.dirty, isFalse);
          expect(doc.canUndo, isFalse);
        }
        expect(tester.takeException(), isNull);
      });
    }

    for (final rename in [true, false]) {
      testWidgets('$entry edits only the clicked sheet (rename=$rename)', (
        tester,
      ) async {
        final workspace = await _mount(tester);
        final foreground = workspace.active;
        final background = workspace.documents.last;
        final original = background.project;
        final foregroundProject = foreground.project;
        await _open(tester, rightClick: rightClick);
        await tester.tap(
          rename
              ? find.text('Přejmenovat list…')
              : find.widgetWithText(
                CheckedPopupMenuItem<String>,
                SheetType.form.label,
              ),
        );
        await tester.pumpAndSettle();
        expect(workspace.active, same(background));
        expect(background.activeSheetId, 'target');
        expect(foreground.activeSheetId, 'first');
        expect(foreground.project, same(foregroundProject));
        expect(foreground.dirty, isFalse);
        expect(foreground.canUndo, isFalse);
        final expected = original
            .sheetById('target')!
            .copyWith(
              name: rename ? 'Renamed background sheet' : null,
              type: rename ? null : SheetType.form,
            );
        expect(background.sheet.toJson(), expected.toJson());
        expect(
          background.project.pages.first.toJson(),
          original.pages.first.toJson(),
        );
        expect(
          background.project.pages.last.toJson(),
          original.pages.last.toJson(),
        );
        expect(background.project.pages.map((sheet) => sheet.id), [
          'first',
          'target',
          'last',
        ]);
        expect(background.undoHistory, hasLength(1));
        background.undo();
        await background.flushWorkingCopy();
        await tester.pump();
        expect(
          background.project.pages.map((sheet) => sheet.toJson()),
          original.pages.map((sheet) => sheet.toJson()),
        );
        expect(background.canUndo, isFalse);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
      '$entry rejects a selection after its project snapshot changes',
      (tester) async {
        final workspace = await _mount(tester);
        final foreground = workspace.active;
        final background = workspace.documents.last;
        await _open(tester, rightClick: rightClick);
        background.renameProject('Changed while menu is open');
        final changed = background.project;
        await tester.pump();
        await tester.tap(
          find.widgetWithText(
            CheckedPopupMenuItem<String>,
            SheetType.form.label,
          ),
        );
        await tester.pumpAndSettle();
        expect(workspace.active, same(foreground));
        expect(background.activeSheetId, 'first');
        expect(background.project, same(changed));
        expect(
          background.project.sheetById('target')!.type,
          SheetType.multiLine,
        );
        expect(background.undoHistory, hasLength(1));
        expect(foreground.dirty, isFalse);
        expect(foreground.canUndo, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
