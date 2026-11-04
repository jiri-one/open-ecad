// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/theme.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/app/workspace_controller.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/sheet_navigation.dart';
import 'package:open_ecad/widgets/project_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'model_fixtures.dart';

EcadProject pagesProject(String name) => EcadProject(
  id: 'navigation',
  name: name,
  pages: [
    Sheet(id: 'first', number: '1', name: 'First page'),
    Sheet(id: 'last', number: '10', name: 'Last page', type: SheetType.form),
    Sheet(
      id: 'second',
      number: '2',
      name: 'Second page',
      type: SheetType.cabinetLayout,
    ),
  ],
);

Future<WorkspaceController> mount(
  WidgetTester tester, {
  bool twoDocuments = false,
  EcadProject? project,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final app = EditorController(
    initialProject: project ?? pagesProject('Project A'),
  );
  final workspace = WorkspaceController(app);
  if (twoDocuments) {
    workspace.add(EditorController(initialProject: pagesProject('Project B')));
    workspace.openSheet(app, 'first');
  }
  addTearDown(() {
    workspace.dispose();
    app.dispose();
  });
  await tester.pumpWidget(
    ListenableBuilder(
      listenable: workspace,
      builder:
          (context, _) => MaterialApp(
            theme: buildEcadTheme(workspace.active.appearance),
            home: EditorWorkspace(
              controller: workspace.active,
              workspace: workspace,
            ),
          ),
    ),
  );
  await tester.pumpAndSettle();
  return workspace;
}

Finder sheetRow(String label) => find.descendant(
  of: find.byType(ProjectPanel),
  matching: find.widgetWithText(ListTile, label),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'sheet order follows structure nesting, chosen aspect, and natural numbers',
    () {
      final sheets = [
        Sheet(
          id: 'b',
          number: '1',
          name: 'B',
          structure: StructureContext(
            functionPath: ['F2'],
            locationPath: ['L1'],
          ),
        ),
        Sheet(
          id: 'a',
          number: '10',
          name: 'A10',
          structure: StructureContext(
            functionPath: ['F1'],
            locationPath: ['L2'],
          ),
        ),
        Sheet(
          id: 'c',
          number: '2',
          name: 'A2',
          structure: StructureContext(
            functionPath: ['F1'],
            locationPath: ['L2'],
          ),
        ),
        Sheet(id: 'empty', number: '99', name: 'No structure'),
        Sheet(
          id: 'nested',
          number: '1',
          name: 'Nested',
          structure: StructureContext(functionPath: ['F1', 'SUB']),
        ),
      ];
      expect(orderedSheets(sheets).map((s) => s.id), [
        'empty',
        'c',
        'a',
        'nested',
        'b',
      ]);
      expect(
        orderedSheets(sheets, first: StructureAspect.location).map((s) => s.id),
        ['empty', 'nested', 'b', 'c', 'a'],
      );
    },
  );

  testWidgets(
    'PgUp/PgDown follow the active project without accumulating tabs or wrapping',
    (tester) async {
      final workspace = await mount(tester, twoDocuments: true);
      final app = workspace.active;
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      expect(app.activeSheetId, 'first');
      for (final id in ['second', 'last', 'last']) {
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
        expect(app.activeSheetId, id);
        expect(workspace.active, same(app));
        expect(workspace.tabs, hasLength(2));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(app.activeSheetId, 'second');
      expect(app.dirty, isFalse);
      expect(app.canUndo, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('typing and modal menus keep page navigation out of the editor', (
    tester,
  ) async {
    final workspace = await mount(tester);
    final search = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'Najít list nebo typ…',
    );
    await tester.tap(search);
    await tester.enterText(search, 'First');
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    expect(workspace.active.activeSheetId, 'first');
    workspace.active.viewport.focus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(workspace.active.activeSheetId, 'first');
    await tester.tap(find.byTooltip('Vlastnosti listu'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    expect(workspace.active.activeSheetId, 'first');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    workspace.active.viewport.focus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(workspace.active.activeSheetId, 'second');
  });

  testWidgets(
    'navigation keeps the chosen tree grouping when the panel is reopened',
    (tester) async {
      final workspace = await mount(
        tester,
        project: EcadProject(
          id: 'grouping',
          name: 'Grouping',
          pages: [
            Sheet(
              id: 'a',
              number: '1',
              name: 'A',
              structure: StructureContext(
                functionPath: ['F1'],
                locationPath: ['L2'],
              ),
            ),
            Sheet(
              id: 'b',
              number: '2',
              name: 'B',
              structure: StructureContext(
                functionPath: ['F2'],
                locationPath: ['L1'],
              ),
            ),
          ],
        ),
      );
      await tester.tap(find.byType(DropdownButton<StructureAspect>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Struktura: umístění').last);
      await tester.pumpAndSettle();
      expect(
        workspace.sheetNavigationAspect(workspace.active),
        StructureAspect.location,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == 'Předchozí list · PgUp',
              ),
            )
            .onPressed,
        isNotNull,
      );
      final toggle = find.byTooltip('Zobrazit projekt a knihovnu');
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButton<StructureAspect>>(
              find.byType(DropdownButton<StructureAspect>),
            )
            .value,
        StructureAspect.location,
      );
      workspace.active.viewport.focus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(workspace.active.activeSheetId, 'b');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'left click replaces the active tab and Ctrl click opens another tab',
    (tester) async {
      final workspace = await mount(tester);
      await tester.tap(sheetRow('2 · Second page'));
      await tester.pumpAndSettle();
      expect(workspace.tabs.map((t) => t.sheetId), ['second']);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(sheetRow('10 · Last page'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(workspace.tabs.map((t) => t.sheetId), ['second', 'last']);
    },
  );

  testWidgets(
    'right click opens a different document page in a new tab and acts on the clicked page',
    (tester) async {
      final workspace = await mount(tester, twoDocuments: true);
      final other = workspace.documents.last;
      final otherRow = sheetRow('10 · Last page').last;
      await tester.ensureVisible(otherRow);
      await tester.tap(otherRow, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(workspace.active, isNot(same(other)));
      await tester.tap(find.text('Otevřít v novém tabu'));
      await tester.pumpAndSettle();
      expect(workspace.active, same(other));
      expect(other.activeSheetId, 'last');
      expect(workspace.tabs, hasLength(3));
      final firstRow = sheetRow('1 · First page').first;
      await tester.ensureVisible(firstRow);
      await tester.tap(firstRow, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Číslo, papír a vlastnosti…'));
      await tester.pumpAndSettle();
      expect(find.text('Vlastnosti listu'), findsOneWidget);
      expect(workspace.active, same(workspace.documents.first));
      expect(workspace.active.activeSheetId, 'first');
      expect(other.activeSheetId, 'last');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tab context menu closes a background tab without changing the active sheet',
    (tester) async {
      final workspace = await mount(tester);
      workspace.openSheet(workspace.active, 'last');
      await tester.pumpAndSettle();
      await tester.tap(
        find.byTooltip('Project A · 1 First page'),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zavřít tab'));
      await tester.pumpAndSettle();
      expect(workspace.tabs.map((t) => t.sheetId), ['last']);
      expect(workspace.active.activeSheetId, 'last');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an active drawing gesture blocks page navigation', (
    tester,
  ) async {
    final workspace = await mount(tester);
    final center = tester.getCenter(find.byType(SchematicCanvas));
    final gesture = await tester.startGesture(center);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    expect(workspace.active.activeSheetId, 'first');
    await gesture.up();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(workspace.active.activeSheetId, 'second');
  });

  testWidgets(
    'mounting placement drags block paging until the move is committed',
    (tester) async {
      final workspace = await mount(
        tester,
        project: EcadProject(
          id: 'mounting_project',
          name: 'Mounting navigation',
          components: const [
            Component(
              id: 'piece',
              designation: '-Q1',
              mountingSizeOverrideMm: DimensionsMm(width: 30, height: 40),
            ),
          ],
          mountingLayouts: [
            MountingLayout(
              id: 'layout',
              name: 'Panel',
              widthMm: 300,
              heightMm: 200,
              placements: const [
                MountingPlacement(
                  id: 'placement',
                  componentId: 'piece',
                  centerMm: Vec2(100, 100),
                ),
              ],
            ),
          ],
          pages: [
            Sheet(
              id: 'mounting',
              number: '1',
              name: 'Mounting',
              type: SheetType.cabinetLayout,
              mountingView: const MountingView(
                layoutId: 'layout',
                viewport: RectUnits(x: 20, y: 60, width: 1000, height: 650),
              ),
            ),
            Sheet(id: 'next', number: '2', name: 'Next page'),
          ],
        ),
      );
      final app = workspace.active;
      final surface = find.byKey(const ValueKey('mounting-surface'));
      final rect = tester.getRect(surface);
      final scale = rect.width / app.sheet.width;
      final point = MountingTransform(
        app.sheet,
        app.sheet.mountingView!,
      ).toSheet(const Vec2(100, 100));
      final gesture = await tester.startGesture(
        rect.topLeft + Offset(point.x * scale, point.y * scale),
      );
      await gesture.moveBy(const Offset(30, 20));
      await tester.pump();
      await gesture.moveBy(const Offset(20, 10));
      await tester.pump();
      expect(app.viewport.hasActiveGesture, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      expect(app.activeSheetId, 'mounting');
      expect(
        app.activeLayout!.placements.single.centerMm,
        const Vec2(100, 100),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(app.viewport.hasActiveGesture, isFalse);
      expect(
        app.activeLayout!.placements.single.centerMm,
        isNot(const Vec2(100, 100)),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(app.activeSheetId, 'next');
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'page buttons remain usable after a device selection and reject navigation during its gesture',
    (tester) async {
      final workspace = await mount(tester, project: testDemoProject());
      final app = workspace.active;
      app.viewport.reset();
      await tester.pumpAndSettle();
      final first = app.sheet.id, second = app.project.pages[1].id;
      final next = find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            widget.tooltip == 'Následující list · PgDown',
      );
      final point =
          tester.getTopLeft(find.byType(SchematicCanvas)) +
          app.viewport.worldToLocal(app.sheet.devices.first.position)!;
      final gesture = await tester.startGesture(point);
      await tester.pump(const Duration(milliseconds: 50));
      expect(app.selectedIds, contains(app.sheet.devices.first.id));
      expect(app.viewport.hasActiveGesture, isTrue);
      tester.widget<IconButton>(next).onPressed!();
      expect(app.activeSheetId, first);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(app.viewport.hasActiveGesture, isFalse);
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(app.activeSheetId, second);
      expect(tester.takeException(), isNull);
    },
  );
}
