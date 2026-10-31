// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart' show PortSide, Vec2;
import 'package:ecad_core/terminal_symbol_geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/editor/terminal_symbol_painter.dart';
import 'package:open_ecad/widgets/terminal_symbol_dialog.dart';

const _sides = [PortSide.top, PortSide.right, PortSide.bottom, PortSide.left];
final _preview = find.byKey(const ValueKey('terminal-symbol-preview'));
Finder _choice(PortSide side) =>
    find.byKey(ValueKey('terminal-symbol-side-${side.name}'));

Widget _host({
  Set<PortSide> initialSides = const {PortSide.top, PortSide.bottom},
  int quarterTurns = 0,
  double radius = TerminalSymbolGeometry.defaultRadius,
  double portDistance = TerminalSymbolGeometry.defaultPortDistance,
  required ValueChanged<Set<PortSide>?> onResult,
  double textScale = 1,
}) => MaterialApp(
  home: Builder(
    builder:
        (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              onResult(
                await showTerminalSymbolDialog(
                  context,
                  initialSides: initialSides,
                  quarterTurns: quarterTurns,
                  radius: radius,
                  portDistance: portDistance,
                ),
              );
            },
            child: const Text('Otevřít'),
          ),
        ),
  ),
  builder:
      (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Otevřít'));
  await tester.pumpAndSettle();
}

Future<void> _toggle(WidgetTester tester, PortSide side) async {
  await tester.ensureVisible(_choice(side));
  await tester.tap(_choice(side));
  await tester.pumpAndSettle();
}

TerminalSymbolGeometry _previewGeometry(WidgetTester tester) =>
    tester.widget<TerminalSymbolPreview>(_preview).geometry;

void main() {
  for (var mask = 1; mask < 16; mask++) {
    testWidgets(
      'clicking choices saves combination $mask and previews the same data',
      (tester) async {
        Set<PortSide>? result;
        final input = <PortSide>{PortSide.top, PortSide.bottom};
        final wanted = <PortSide>{
          for (var index = 0; index < 4; index++)
            if (mask & (1 << index) != 0) _sides[index],
        };
        await tester.pumpWidget(
          _host(initialSides: input, onResult: (value) => result = value),
        );
        await _open(tester);
        for (final side in _sides) {
          if (input.contains(side) != wanted.contains(side)) {
            await _toggle(tester, side);
          }
        }
        final geometry = _previewGeometry(tester);
        expect(geometry.sides, wanted);
        expect(
          geometry.ports.map((port) => port.side),
          unorderedEquals(wanted),
        );
        for (final side in _sides) {
          expect(
            tester.widget<FilterChip>(_choice(side)).selected,
            wanted.contains(side),
          );
          final choicePreview = tester.widget<TerminalSymbolPreview>(
            find.descendant(
              of: _choice(side),
              matching: find.byType(TerminalSymbolPreview),
            ),
          );
          expect(choicePreview.geometry.ports.single.side, side);
        }
        final painter =
            tester
                    .widget<CustomPaint>(
                      find.descendant(
                        of: _preview,
                        matching: find.byType(CustomPaint),
                      ),
                    )
                    .painter!
                as TerminalSymbolPreviewPainter;
        expect(identical(painter.geometry, geometry), isTrue);
        expect(
          (Canvas canvas) => painter.paint(canvas, const Size(100, 100)),
          paintsExactlyCountTimes(#drawLine, wanted.length),
        );
        expect(input, {PortSide.top, PortSide.bottom});
        await tester.tap(find.text('Uložit'));
        await tester.pumpAndSettle();
        expect(result, wanted);
        expect(find.byType(TerminalSymbolDialog), findsNothing);
        expect(() => result!.clear(), throwsUnsupportedError);
        expect(input, {PortSide.top, PortSide.bottom});
      },
    );
  }

  testWidgets(
    'empty choice disables saving and selecting a direction restores it',
    (tester) async {
      var completed = false;
      Set<PortSide>? result;
      await tester.pumpWidget(
        _host(
          onResult: (value) {
            completed = true;
            result = value;
          },
        ),
      );
      await _open(tester);
      await _toggle(tester, PortSide.top);
      await _toggle(tester, PortSide.bottom);
      expect(find.text('Vyberte alespoň jeden směr.'), findsOneWidget);
      expect(_preview, findsNothing);
      final save = find.widgetWithText(FilledButton, 'Uložit');
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(completed, isFalse);
      expect(find.byType(TerminalSymbolDialog), findsOneWidget);
      await _toggle(tester, PortSide.left);
      expect(find.text('Vyberte alespoň jeden směr.'), findsNothing);
      expect(_previewGeometry(tester).sides, {PortSide.left});
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(result, {PortSide.left});
    },
  );

  testWidgets('cancel returns null and leaves the existing choice untouched', (
    tester,
  ) async {
    final input = {PortSide.right, PortSide.left};
    var completed = false;
    Set<PortSide>? result = {PortSide.top};
    await tester.pumpWidget(
      _host(
        initialSides: input,
        onResult: (value) {
          completed = true;
          result = value;
        },
      ),
    );
    await _open(tester);
    await _toggle(tester, PortSide.top);
    await _toggle(tester, PortSide.right);
    expect(_previewGeometry(tester).sides, {PortSide.top, PortSide.left});
    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
    expect(input, {PortSide.right, PortSide.left});
    await _open(tester);
    expect(_previewGeometry(tester).sides, input);
  });

  testWidgets('dismissing the dialog also discards the draft', (tester) async {
    final input = {PortSide.top};
    var completed = false;
    Set<PortSide>? result = {};
    await tester.pumpWidget(
      _host(
        initialSides: input,
        onResult: (value) {
          completed = true;
          result = value;
        },
      ),
    );
    await _open(tester);
    await _toggle(tester, PortSide.bottom);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
    expect(input, {PortSide.top});
  });

  testWidgets(
    'rotated occurrence shows world directions but saves local keys',
    (tester) async {
      Set<PortSide>? result;
      await tester.pumpWidget(
        _host(
          initialSides: {PortSide.top},
          quarterTurns: 1,
          radius: 6,
          portDistance: 20,
          onResult: (value) => result = value,
        ),
      );
      await _open(tester);
      expect(
        tester.widget<FilterChip>(_choice(PortSide.right)).selected,
        isTrue,
      );
      expect(
        tester.widget<FilterChip>(_choice(PortSide.top)).selected,
        isFalse,
      );
      final port = _previewGeometry(tester).ports.single;
      expect(port.key, 'top');
      expect(port.position, const Vec2(20, 0));
      expect(port.normal, const Vec2(1, 0));
      expect(_previewGeometry(tester).radius, 6);
      await _toggle(tester, PortSide.top);
      final geometry = _previewGeometry(tester);
      expect(geometry.sides, {PortSide.top, PortSide.left});
      expect(geometry.ports.map((port) => port.side), [
        PortSide.right,
        PortSide.top,
      ]);
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(result, {PortSide.top, PortSide.left});
    },
  );

  testWidgets(
    'empty initial draft is editable in a narrow window with larger text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Set<PortSide>? result;
      await tester.pumpWidget(
        _host(
          initialSides: {},
          textScale: 1.5,
          onResult: (value) => result = value,
        ),
      );
      await _open(tester);
      expect(tester.takeException(), isNull);
      await _toggle(tester, PortSide.bottom);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(result, {PortSide.bottom});
    },
  );

  test('shared painter uses only the circle and the exact arm primitives', () {
    for (var mask = 1; mask < 16; mask++) {
      for (var turns = 0; turns < 4; turns++) {
        final geometry = TerminalSymbolGeometry(
          sides: {
            for (var index = 0; index < 4; index++)
              if (mask & (1 << index) != 0) _sides[index],
          },
          center: const Vec2(80, 30),
          quarterTurns: turns,
        );
        void draw(Canvas canvas) => paintTerminalSymbol(
          canvas,
          geometry,
          ink: Colors.black,
          strokeWidth: 2,
        );
        expect(draw, paintsExactlyCountTimes(#drawRect, 0));
        expect(draw, paintsExactlyCountTimes(#drawRRect, 0));
        expect(draw, paintsExactlyCountTimes(#drawPath, 0));
        expect(draw, paintsExactlyCountTimes(#drawCircle, 1));
        expect(draw, paintsExactlyCountTimes(#drawLine, geometry.arms.length));
        final pattern = paints;
        for (final arm in geometry.arms) {
          pattern.line(
            p1: Offset(arm.start.x, arm.start.y),
            p2: Offset(arm.end.x, arm.end.y),
            color: Colors.black,
            strokeWidth: 2,
          );
        }
        pattern.circle(
          x: 80,
          y: 30,
          radius: 4,
          color: Colors.black,
          style: PaintingStyle.stroke,
        );
        expect(draw, pattern);
      }
    }
  });

  test('paper fill masks only the circle interior', () {
    final geometry = TerminalSymbolGeometry(sides: {PortSide.top});
    void draw(Canvas canvas) => paintTerminalSymbol(
      canvas,
      geometry,
      ink: Colors.blue,
      paper: Colors.white,
      strokeWidth: 2,
    );
    expect(draw, paintsExactlyCountTimes(#drawRect, 0));
    expect(draw, paintsExactlyCountTimes(#drawCircle, 2));
    expect(
      draw,
      paints
        ..line(
          p1: const Offset(0, -4),
          p2: const Offset(0, -10),
          color: Colors.blue,
        )
        ..circle(
          x: 0,
          y: 0,
          radius: 4,
          color: Colors.white,
          style: PaintingStyle.fill,
        )
        ..circle(
          x: 0,
          y: 0,
          radius: 4,
          color: Colors.blue,
          strokeWidth: 2,
          style: PaintingStyle.stroke,
        ),
    );
  });

  test(
    'preview fits the same geometry without moving its center when arms change',
    () {
      for (final sides in [
        {PortSide.top},
        {..._sides},
      ]) {
        final geometry = TerminalSymbolGeometry(
          sides: sides,
          center: const Vec2(80, 30),
        );
        final painter = TerminalSymbolPreviewPainter(
          geometry: geometry,
          ink: Colors.black,
          strokeWidth: 2,
          padding: 8,
        );
        void draw(Canvas canvas) => painter.paint(canvas, const Size(104, 60));
        expect(
          draw,
          paints
            ..save()
            ..translate(x: 52, y: 30)
            ..scale(x: 2)
            ..translate(x: -80, y: -30)
            ..circle(x: 80, y: 30, radius: 4)
            ..restore(),
        );
        expect(
          (Canvas canvas) => painter.paint(canvas, const Size(12, 12)),
          paintsNothing,
        );
      }
    },
  );
}
