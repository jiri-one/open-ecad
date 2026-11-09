// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/theme.dart';
import 'package:open_ecad/app/typography.dart';
import 'package:open_ecad/app/workspace_controller.dart';
import 'package:open_ecad/services/export_fonts.dart';
import 'package:open_ecad/widgets/sheet_context_menu.dart';
import 'package:open_ecad/widgets/sheet_navigator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_editing_feedback_test.dart' show MemoryPersistence;

final _navigator = find.byType(SheetNavigator);
final _horizontal = _namedKey('sheet-tree-horizontal');
final _vertical = _namedKey('sheet-tree-vertical');
final _horizontalScrollbar = _namedKey('sheet-tree-horizontal-scrollbar');

Finder _namedKey(String value) => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value == value,
);

final _sheetRows = find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is SheetContextMenu && widget.child is ListTile,
  ),
  matching: find.byType(ListTile),
);

Finder _row(Sheet sheet) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) =>
        widget is SheetContextMenu &&
        widget.sheet.id == sheet.id &&
        widget.child is ListTile,
  ),
  matching: find.byType(ListTile),
);

Finder _title(WidgetTester tester, Sheet sheet) => find.descendant(
  of: find.byWidget(tester.widget<ListTile>(_row(sheet)).title!),
  matching: find.byType(Text),
  matchRoot: true,
);

EditorController _controller(List<Sheet> sheets, {String id = 'synthetic'}) {
  final controller = EditorController(
    initialProject: EcadProject(id: id, name: 'Synthetic $id', pages: sheets),
    persistence: MemoryPersistence(),
  );
  addTearDown(controller.dispose);
  return controller;
}

Future<void> _pumpNavigator(
  WidgetTester tester,
  EditorController controller, {
  WorkspaceController? workspace,
  String query = '',
  double width = 260,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEcadTheme(
        EcadAppearance.paper,
        fontFamily: 'NotoSans',
      ).copyWith(platform: TargetPlatform.linux),
      builder:
          (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 600,
            child: ListenableBuilder(
              listenable: workspace ?? controller,
              builder:
                  (context, _) => SheetNavigator(
                    controller: workspace?.active ?? controller,
                    workspace: workspace,
                    query: query,
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
}

ScrollController _horizontalController(WidgetTester tester) =>
    tester.widget<SingleChildScrollView>(_horizontal).controller!;

ScrollController _verticalController(WidgetTester tester) =>
    tester.widget<CustomScrollView>(_vertical).controller!;

Rect _visibleRect(WidgetTester tester, Finder finder) => tester
    .getRect(finder)
    .intersect(tester.getRect(_horizontal))
    .intersect(tester.getRect(_vertical));

void _expectSingleLine(WidgetTester tester, Sheet sheet) {
  final row = _row(sheet);
  final tile = tester.widget<ListTile>(row);
  final title = tester.widget<Text>(_title(tester, sheet));
  expect(tile.subtitle, isNull);
  expect(title.maxLines, 1);
  expect(title.softWrap, isFalse);
  expect(title.data, isNot(matches(RegExp(r'[\r\n\u2028\u2029]'))));
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: _title(tester, sheet), matching: find.byType(RichText)),
  );
  expect(paragraph.didExceedMaxLines, isFalse);
  expect(
    paragraph.size.height + .5,
    greaterThanOrEqualTo(paragraph.getMaxIntrinsicHeight(double.infinity)),
  );
  final titleRect = tester.getRect(_title(tester, sheet));
  final rowRect = tester.getRect(row);
  expect(titleRect.top, greaterThanOrEqualTo(rowRect.top - .5));
  expect(titleRect.bottom, lessThanOrEqualTo(rowRect.bottom + .5));
}

Offset _mouseThumb(WidgetTester tester) {
  final paintFinder =
      find
          .descendant(
            of: _horizontalScrollbar,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is CustomPaint &&
                  widget.foregroundPainter is ScrollbarPainter,
            ),
          )
          .first;
  final painter =
      tester.widget<CustomPaint>(paintFinder).foregroundPainter!
          as ScrollbarPainter;
  final box = tester.renderObject<RenderBox>(paintFinder);
  for (var y = box.size.height - 1; y > 0; y -= 2) {
    final hits = <double>[];
    for (var x = 1.0; x < box.size.width; x += 2) {
      if (painter.hitTestOnlyThumbInteractive(
        Offset(x, y),
        PointerDeviceKind.mouse,
      )) {
        hits.add(x);
      }
    }
    if (hits.isNotEmpty) {
      return box.localToGlobal(Offset((hits.first + hits.last) / 2, y));
    }
  }
  throw TestFailure('The horizontal scrollbar has no mouse-draggable thumb.');
}

void _expectInRange(ScrollController controller) {
  expect(
    controller.offset,
    inInclusiveRange(
      controller.position.minScrollExtent - .5,
      controller.position.maxScrollExtent + .5,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ExportFonts.load);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('4000 grouped sheets stay lazy and the last sheet is reachable', (
    tester,
  ) async {
    final sheets = [
      for (var i = 1; i <= 4000; i++)
        Sheet(
          id: 'sheet-$i',
          number: '$i'.padLeft(4, '0'),
          name: 'Synthetic circuit $i with a long description of its signals',
          structure: StructureContext(
            functionPath: ['FUNCTION${(i - 1) ~/ 100 + 1}'],
          ),
        ),
    ];
    final controller = _controller(sheets);
    expect(
      EcadProject.fromJson(controller.project.toJson()).pages,
      hasLength(4000),
    );
    await _pumpNavigator(tester, controller);

    expect(_sheetRows.evaluate().length, inInclusiveRange(1, 80));
    expect(_row(sheets.first), findsOneWidget);
    expect(_row(sheets.last), findsNothing);
    final vertical = _verticalController(tester);
    expect(vertical.positions, hasLength(1));
    expect(vertical.position.maxScrollExtent, greaterThan(600));
    vertical.jumpTo(vertical.position.maxScrollExtent);
    await tester.pumpAndSettle();

    expect(_sheetRows.evaluate().length, inInclusiveRange(1, 80));
    expect(_row(sheets.first), findsNothing);
    expect(_row(sheets.last), findsOneWidget);
    final visible = _visibleRect(tester, _row(sheets.last));
    expect(visible.width, greaterThan(0));
    expect(visible.height, greaterThan(0));
    await tester.tapAt(visible.center);
    await tester.pumpAndSettle();
    expect(controller.activeSheetId, sheets.last.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('titles stay on one line and hover reveals the full title', (
    tester,
  ) async {
    final sheets = [
      Sheet(
        id: 'multiline',
        number: '01',
        documentCode: 'CTRL',
        name: 'Řízení pohonu\r\nJištění motoru\nSignál start',
      ),
      Sheet(
        id: 'layout',
        number: '02',
        documentCode: 'CTRL',
        name: 'Výstup diagnostiky',
        type: SheetType.cabinetLayout,
      ),
    ];
    final controller = _controller(sheets);
    await _pumpNavigator(tester, controller);

    for (final sheet in sheets) {
      _expectSingleLine(tester, sheet);
      expect(
        find.byTooltip('${fullPageDesignation(sheet)} · ${sheet.name}'),
        findsOneWidget,
      );
      final typeTooltip = find.descendant(
        of: _row(sheet),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              (widget.message?.contains(sheet.type.label) ?? false),
        ),
      );
      expect(typeTooltip, findsOneWidget);
      expect(
        find.descendant(of: typeTooltip, matching: find.byType(Icon)),
        findsOneWidget,
      );
    }
    expect(
      tester.widget<Text>(_title(tester, sheets.first)).data,
      '${fullPageDesignation(sheets.first)} · '
      'Řízení pohonu Jištění motoru Signál start',
    );
    final fullTitle =
        '${fullPageDesignation(sheets.first)} · ${sheets.first.name}';
    expect(find.text(fullTitle, findRichText: true), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(799, 599));
    await mouse.moveTo(
      _visibleRect(tester, _title(tester, sheets.first)).center,
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text(fullTitle, findRichText: true), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpAndSettle();

    final height = tester.getSize(_row(sheets.first)).height;
    final extent = _horizontalController(tester).position.maxScrollExtent;
    await _pumpNavigator(
      tester,
      controller,
      textScaler: const InterfaceTextScaler(
        system: TextScaler.noScaling,
        fontSize: 24,
        magnification: 2,
      ),
    );
    for (final sheet in sheets) {
      _expectSingleLine(tester, sheet);
    }
    expect(tester.getSize(_row(sheets.first)).height, greaterThan(height));
    expect(
      _horizontalController(tester).position.maxScrollExtent,
      greaterThan(extent),
    );
    final vertical = _verticalController(tester);
    vertical.jumpTo(vertical.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      _visibleRect(tester, _row(sheets.last)).height,
      closeTo(tester.getSize(_row(sheets.last)).height, .5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('one mouse-draggable scrollbar moves rows in both projects', (
    tester,
  ) async {
    final first = Sheet(
      id: 'first',
      number: '01',
      name: List.filled(5, 'Long synthetic control circuit').join(' '),
      structure: StructureContext(functionPath: ['FIRST']),
    );
    final second = Sheet(
      id: 'second',
      number: '02',
      name: List.filled(5, 'Long synthetic diagnostic circuit').join(' '),
      structure: StructureContext(functionPath: ['SECOND']),
    );
    final a = _controller([first], id: 'a');
    final b = _controller([second], id: 'b');
    final workspace = WorkspaceController(a)..add(b, owned: false);
    addTearDown(workspace.dispose);
    await _pumpNavigator(tester, a, workspace: workspace);

    final horizontal = _horizontalController(tester);
    final vertical = _verticalController(tester);
    expect(horizontal.positions, hasLength(1));
    expect(horizontal.position.maxScrollExtent, greaterThan(260));
    expect(
      tester.widget<Scrollbar>(_horizontalScrollbar).controller,
      same(horizontal),
    );
    expect(
      find.descendant(
        of: _navigator,
        matching: find.byWidgetPredicate(
          (widget) => widget is RawScrollbar && widget.controller == horizontal,
        ),
      ),
      findsOneWidget,
    );
    final scrollables = tester.widgetList<Scrollable>(
      find.descendant(of: _navigator, matching: find.byType(Scrollable)),
    );
    expect(
      scrollables.where(
        (widget) => widget.axisDirection == AxisDirection.right,
      ),
      hasLength(1),
    );
    expect(
      scrollables.where((widget) => widget.axisDirection == AxisDirection.down),
      hasLength(1),
    );
    for (final sheet in [first, second]) {
      expect(_visibleRect(tester, _row(sheet)).height, greaterThan(0));
    }
    final before = [
      for (final sheet in [first, second])
        tester.getTopLeft(_title(tester, sheet)),
    ];
    final verticalOffset = vertical.offset;
    final horizontalOffset = horizontal.offset;
    final mouse = await tester.startGesture(
      _mouseThumb(tester),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(35, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(35, 0));
    await tester.pump();
    await mouse.up();
    await mouse.removePointer();
    await tester.pumpAndSettle();

    final moved = horizontal.offset - horizontalOffset;
    expect(moved, greaterThan(0));
    expect(vertical.offset, closeTo(verticalOffset, .5));
    for (var i = 0; i < 2; i++) {
      final after = tester.getTopLeft(_title(tester, [first, second][i]));
      expect(before[i].dx - after.dx, closeTo(moved, .5));
      expect(after.dy, closeTo(before[i].dy, .5));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'filtering and resizing recompute widths and clamp both offsets',
    (tester) async {
      final needle = Sheet(id: 'needle', number: '01', name: 'Needle');
      final controller = _controller([
        needle,
        for (var i = 2; i <= 180; i++)
          Sheet(
            id: 'sheet-$i',
            number: '$i'.padLeft(3, '0'),
            name: List.filled(5, 'Synthetic wiring description $i').join(' '),
          ),
      ]);
      await _pumpNavigator(tester, controller);
      final state = tester.state(_navigator);
      final horizontal = _horizontalController(tester);
      final vertical = _verticalController(tester);
      final unfilteredWidth = horizontal.position.maxScrollExtent;
      horizontal.jumpTo(unfilteredWidth);
      vertical.jumpTo(vertical.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(horizontal.offset, greaterThan(0));
      expect(vertical.offset, greaterThan(0));

      await _pumpNavigator(tester, controller, query: 'Needle');
      expect(tester.state(_navigator), same(state));
      expect(_horizontalController(tester), same(horizontal));
      expect(_verticalController(tester), same(vertical));
      expect(_sheetRows, findsOneWidget);
      expect(_row(needle), findsOneWidget);
      expect(horizontal.position.maxScrollExtent, lessThan(unfilteredWidth));
      _expectInRange(horizontal);
      _expectInRange(vertical);
      expect(vertical.offset, closeTo(0, .5));
      expect(_visibleRect(tester, _row(needle)).height, greaterThan(0));
      expect(tester.takeException(), isNull);

      await _pumpNavigator(tester, controller, query: 'Needle', width: 760);
      expect(horizontal.position.maxScrollExtent, closeTo(0, .5));
      expect(horizontal.offset, closeTo(0, .5));
      expect(tester.takeException(), isNull);

      await _pumpNavigator(tester, controller, width: 760);
      final wideExtent = horizontal.position.maxScrollExtent;
      expect(wideExtent, greaterThan(0));
      await _pumpNavigator(tester, controller);
      expect(horizontal.position.maxScrollExtent, greaterThan(wideExtent));
      horizontal.jumpTo(horizontal.position.maxScrollExtent);
      await tester.pumpAndSettle();
      await _pumpNavigator(tester, controller, width: 760);
      expect(horizontal.position.maxScrollExtent, closeTo(wideExtent, .5));
      _expectInRange(horizontal);
      _expectInRange(vertical);
      expect(tester.state(_navigator), same(state));
      expect(tester.takeException(), isNull);
    },
  );
}
