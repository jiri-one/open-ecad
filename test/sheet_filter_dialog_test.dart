// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/theme.dart';
import 'package:open_ecad/app/typography.dart';
import 'package:open_ecad/app/workspace_controller.dart';
import 'package:open_ecad/services/export_fonts.dart';
import 'package:open_ecad/widgets/project_panel.dart';
import 'package:open_ecad/widgets/sheet_context_menu.dart';
import 'package:open_ecad/widgets/sheet_filter_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_editing_feedback_test.dart' show MemoryPersistence;

final _sheets = [
  Sheet(
    id: 'heating',
    number: '01',
    name: 'Čerpadlo patro',
    structure: StructureContext(
      functionPath: ['TECH', 'HEAT'],
      locationPath: ['Patro A'],
      productPath: ['A1'],
    ),
    documentCode: 'EL',
  ),
  Sheet(
    id: 'water',
    number: '02',
    name: 'Čerpadlo sklep',
    structure: StructureContext(
      functionPath: ['WATER'],
      locationPath: ['Sklep'],
      productPath: ['B1'],
    ),
    paperSizeMm: SizeMm.a4Landscape,
  ),
  Sheet(
    id: 'terminals',
    number: '03',
    name: 'Čerpadlo svorky',
    type: SheetType.singleLine,
    structure: StructureContext(
      functionPath: ['TECH', 'HEAT'],
      locationPath: ['Patro A'],
      productPath: ['A1'],
    ),
    paperSizeMm: const SizeMm(width: 210, height: 297),
  ),
];

Future<WorkspaceController> _mount(
  WidgetTester tester, {
  bool large = false,
  ValueListenable<bool>? panelVisible,
}) async {
  tester.view.physicalSize =
      large ? const Size(960, 640) : const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final app = EditorController(
    initialProject: EcadProject(id: 'filters', name: 'Filtry', pages: _sheets),
    persistence: MemoryPersistence(),
  );
  final workspace = WorkspaceController(app);
  addTearDown(() {
    workspace.dispose();
    app.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEcadTheme(EcadAppearance.paper, fontFamily: 'NotoSans'),
      builder:
          (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler:
                  large
                      ? const InterfaceTextScaler(
                        system: TextScaler.noScaling,
                        fontSize: 24,
                        magnification: 2,
                      )
                      : TextScaler.noScaling,
            ),
            child: child!,
          ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 320,
            child: ListenableBuilder(
              listenable: Listenable.merge([
                workspace,
                if (panelVisible != null) panelVisible,
              ]),
              builder:
                  (context, _) =>
                      panelVisible?.value == false
                          ? const SizedBox.shrink()
                          : ProjectPanel(
                            controller: workspace.active,
                            workspace: workspace,
                            onAddSheet: () {},
                            onRenameSheet: () {},
                          ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return workspace;
}

Set<String> _visibleSheets(WidgetTester tester) =>
    tester
        .widgetList<SheetContextMenu>(
          find.byWidgetPredicate(
            (w) => w is SheetContextMenu && w.child is ListTile,
          ),
        )
        .map((menu) => menu.sheet.id)
        .toSet();

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('sheet-filter-button')));
  await tester.pumpAndSettle();
  expect(find.byType(SheetFilterDialog), findsOneWidget);
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final field = find.byKey(ValueKey('sheet-filter-$key'));
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> _click(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ExportFonts.load);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'advanced criteria combine with quick search, cancel and clear without editing the project',
    (tester) async {
      final panelVisible = ValueNotifier(true);
      addTearDown(panelVisible.dispose);
      final workspace = await _mount(tester, panelVisible: panelVisible);
      final app = workspace.active;
      final original = app.project;
      final active = app.activeSheetId;
      final quick = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.hintText == 'Najít list nebo typ…',
      );
      await tester.enterText(quick, 'cerpadlo ');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(quick).controller!.text, 'cerpadlo ');
      await _open(tester);
      await _enter(tester, 'function', '=tech=heat');
      await _click(
        tester,
        find.byKey(const ValueKey('sheet-filter-type-multiLine')),
      );
      expect(find.text('Nalezeno: 1 / 3'), findsOneWidget);
      await _click(tester, find.text('Použít filtr'));
      expect(_visibleSheets(tester), {'heating'});
      expect(tester.widget<TextField>(quick).controller!.text, 'cerpadlo');
      await _click(tester, find.widgetWithText(Tab, 'Značky'));
      await _click(tester, find.widgetWithText(Tab, 'Listy'));
      expect(_visibleSheets(tester), {'heating'});
      panelVisible.value = false;
      await tester.pumpAndSettle();
      expect(find.byType(ProjectPanel), findsNothing);
      panelVisible.value = true;
      await tester.pumpAndSettle();
      expect(_visibleSheets(tester), {'heating'});
      expect(tester.widget<TextField>(quick).controller!.text, 'cerpadlo');

      await _open(tester);
      await _enter(tester, 'name', 'neexistuje');
      expect(find.text('Nalezeno: 0 / 3'), findsOneWidget);
      await _click(tester, find.text('Zrušit'));
      expect(_visibleSheets(tester), {'heating'});
      await _click(tester, find.byTooltip('Zrušit filtr listů'));
      expect(_visibleSheets(tester), {'heating', 'water', 'terminals'});
      expect(tester.widget<TextField>(quick).controller!.text, isEmpty);
      expect(app.project, same(original));
      expect(app.activeSheetId, active);
      expect(app.canUndo, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an empty result stays clearable without switching or editing the active sheet',
    (tester) async {
      final workspace = await _mount(tester);
      final app = workspace.active;
      final project = app.project;
      final active = app.activeSheetId;
      await _open(tester);
      await _enter(tester, 'name', 'neexistující list');
      await _click(tester, find.text('Použít filtr'));
      expect(_visibleSheets(tester), isEmpty);
      expect(find.text('Žádný list neodpovídá filtru.'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('sheet-filter-button')),
            )
            .isSelected,
        isTrue,
      );
      await _click(tester, find.byTooltip('Zrušit filtr listů'));
      expect(_visibleSheets(tester), {'heating', 'water', 'terminals'});
      expect(app.project, same(project));
      expect(app.activeSheetId, active);
      expect(app.canUndo, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'applying a filter survives recreating the panel while the dialog is open',
    (tester) async {
      final panelVisible = ValueNotifier(true);
      addTearDown(panelVisible.dispose);
      final workspace = await _mount(tester, panelVisible: panelVisible);
      final original = workspace.active.project;
      final active = workspace.active.activeSheetId;
      await _open(tester);
      await _enter(tester, 'function', 'WATER');
      panelVisible.value = false;
      await tester.pumpAndSettle();
      expect(find.byType(ProjectPanel), findsNothing);
      panelVisible.value = true;
      await tester.pumpAndSettle();
      await _click(tester, find.text('Použít filtr'));
      expect(_visibleSheets(tester), {'water'});
      expect(workspace.active.project, same(original));
      expect(workspace.active.activeSheetId, active);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'paper and orientation filter separately and resetting the draft resets form selections',
    (tester) async {
      await _mount(tester);
      await _open(tester);
      await _click(
        tester,
        find.byKey(const ValueKey('sheet-filter-paper-format')),
      );
      await _click(tester, find.text('A4 · 210 × 297 mm').last);
      expect(find.text('Nalezeno: 2 / 3'), findsOneWidget);
      await _click(
        tester,
        find.byKey(const ValueKey('sheet-filter-orientation')),
      );
      await _click(tester, find.text('Na výšku').last);
      expect(find.text('Nalezeno: 1 / 3'), findsOneWidget);
      await _click(tester, find.text('Použít filtr'));
      expect(_visibleSheets(tester), {'terminals'});
      await _open(tester);
      await _click(tester, find.text('Vymazat kritéria'));
      expect(find.text('Nalezeno: 3 / 3'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('sheet-filter-orientation')),
      );
      expect(find.text('Libovolná orientace'), findsOneWidget);
      await _click(tester, find.text('Použít filtr'));
      expect(_visibleSheets(tester), {'heating', 'water', 'terminals'});
      expect(find.byTooltip('Zrušit filtr listů'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'filter dialog scrolls and applies with 48px body text in a small window',
    (tester) async {
      final workspace = await _mount(tester, large: true);
      final original = workspace.active.project;
      await _open(tester);
      await _enter(tester, 'name', 'patro');
      await _enter(tester, 'function', 'HEAT');
      await _click(
        tester,
        find.byKey(const ValueKey('sheet-filter-type-multiLine')),
      );
      expect(find.text('Nalezeno: 1 / 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _click(tester, find.text('Použít filtr'));
      expect(find.byType(SheetFilterDialog), findsNothing);
      expect(workspace.active.project, same(original));
      expect(workspace.active.canUndo, isFalse);
      await _click(tester, find.byTooltip('Zrušit filtr listů'));
      expect(tester.takeException(), isNull);
    },
  );
}
