// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/editor/drawing_cursor.dart';
import 'package:open_ecad/services/drawing_cursor_settings.dart';
import 'package:open_ecad/widgets/drawing_cursor_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _origin = Offset(40, 60);
final _overlay = find.byKey(const ValueKey('drawing-cursor-overlay'));

Widget _host({
  DrawingCursorSettings settings = DrawingCursorSettings.defaults,
  Color background = Colors.white,
  bool active = true,
  Object? resetKey = 'first-sheet',
  double zoom = 1,
  Widget? child,
  Widget? overlay,
}) => MaterialApp(
  theme: ThemeData(splashFactory: InkRipple.splashFactory),
  home: Scaffold(
    body: Stack(
      children: [
        Positioned(
          left: _origin.dx,
          top: _origin.dy,
          width: 320,
          height: 240,
          child: DrawingCursorRegion(
            settings: settings,
            backgroundColor: background,
            active: active,
            resetKey: resetKey,
            child: Builder(
              builder:
                  (context) => MouseRegion(
                    cursor: DrawingCursorRegion.cursorOf(
                      context,
                      fallback: SystemMouseCursors.precise,
                    ),
                    child: Transform.scale(
                      scale: zoom,
                      child: child ?? const SizedBox.expand(),
                    ),
                  ),
            ),
          ),
        ),
        if (overlay != null) overlay,
      ],
    ),
  ),
);

void _expectCrosshair(
  WidgetTester tester,
  Offset? point, {
  double arm = 8,
  double width = 1,
  Color color = Colors.black,
}) {
  final painter = tester.widget<CustomPaint>(_overlay).painter!;
  void paint(Canvas canvas) => painter.paint(canvas, tester.getSize(_overlay));
  if (point == null) {
    expect(paint, paintsNothing);
  } else {
    expect(paint, paintsExactlyCountTimes(#drawLine, 2));
    expect(
      paint,
      paints
        ..clipRect(rect: const Rect.fromLTWH(0, 0, 320, 240))
        ..line(
          p1: point - Offset(arm, 0),
          p2: point + Offset(arm, 0),
          strokeWidth: width,
          color: color,
        )
        ..line(
          p1: point - Offset(0, arm),
          p2: point + Offset(0, arm),
          strokeWidth: width,
          color: color,
        ),
    );
  }
}

MouseCursor? _systemCursor(WidgetTester tester) =>
    tester.binding.mouseTracker.debugDeviceActiveCursor(1);

Future<TestGesture> _mouse(WidgetTester tester, Offset local) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(10, 10));
  await mouse.moveTo(_origin + local);
  await tester.pump();
  return mouse;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'preferences are lazy, round trip, reset and preserve other keys',
    () async {
      SharedPreferences.setMockInitialValues({
        'unrelated-setting': 'untouched',
      });
      final store = await SharedPreferences.getInstance();
      var loads = 0, changes = 0;
      final preferences = DrawingCursorPreferences(
        loadPreferences: () async {
          loads++;
          return store;
        },
      );
      addTearDown(preferences.dispose);
      preferences.addListener(() => changes++);
      expect(loads, 0);
      expect(preferences.value, const DrawingCursorSettings());
      expect(preferences.value.enabled, isTrue);
      expect(preferences.value.armLength, 8);
      expect(preferences.value.strokeWidth, 1);
      expect(preferences.value.color, DrawingCursorColor.automatic);
      await preferences.load();
      expect(loads, 1);
      const changed = DrawingCursorSettings(
        enabled: false,
        armLength: 24,
        strokeWidth: 2.5,
        color: DrawingCursorColor.cyan,
      );
      await preferences.save(changed);
      final restored = DrawingCursorPreferences(
        loadPreferences: () async => store,
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.value, changed);
      expect(changes, 1);
      await preferences.reset();
      await restored.load();
      expect(restored.value, DrawingCursorSettings.defaults);
      expect(changes, 2);
      expect(loads, 1);
      expect(store.getString('unrelated-setting'), 'untouched');
      expect(store.getKeys(), {
        'unrelated-setting',
        DrawingCursorPreferences.storageKey,
      });
    },
  );

  test(
    'malformed preference values are bounded or restored to defaults',
    () async {
      for (final value in [17, false, 'invalid JSON', '[]', '{}']) {
        SharedPreferences.setMockInitialValues({
          DrawingCursorPreferences.storageKey: value,
        });
        final preferences = DrawingCursorPreferences();
        await preferences.load();
        expect(preferences.value, DrawingCursorSettings.defaults);
        preferences.dispose();
      }
      SharedPreferences.setMockInitialValues({
        DrawingCursorPreferences.storageKey:
            '{"enabled":"false","armLength":1000,"strokeWidth":-2,"color":"unknown"}',
      });
      final preferences = DrawingCursorPreferences();
      addTearDown(preferences.dispose);
      await preferences.load();
      expect(
        preferences.value,
        const DrawingCursorSettings(armLength: 32, strokeWidth: 0.5),
      );
    },
  );

  test(
    'queued load and saves keep the last choice and can retry a failure',
    () async {
      final store = await SharedPreferences.getInstance();
      final ready = Completer<SharedPreferences>();
      final preferences = DrawingCursorPreferences(
        loadPreferences: () => ready.future,
      );
      addTearDown(preferences.dispose);
      final loading = preferences.load();
      final first = preferences.save(
        const DrawingCursorSettings(armLength: 12),
      );
      final last = preferences.save(const DrawingCursorSettings(armLength: 28));
      ready.complete(store);
      await Future.wait([loading, first, last]);
      expect(preferences.value.armLength, 28);
      await preferences.load();
      expect(preferences.value.armLength, 28);

      var attempts = 0;
      final retry = DrawingCursorPreferences(
        loadPreferences: () async {
          if (attempts++ == 0) throw StateError('Synthetic store failure');
          return store;
        },
      );
      addTearDown(retry.dispose);
      await expectLater(
        retry.save(const DrawingCursorSettings(armLength: 20)),
        throwsStateError,
      );
      expect(retry.value, DrawingCursorSettings.defaults);
      await retry.save(const DrawingCursorSettings(armLength: 20));
      expect(retry.value.armLength, 20);
    },
  );

  test(
    'disposal during a pending load prevents notification and queued writes',
    () async {
      final store = await SharedPreferences.getInstance();
      final ready = Completer<SharedPreferences>();
      final preferences = DrawingCursorPreferences(
        loadPreferences: () => ready.future,
      );
      var changes = 0;
      preferences.addListener(() => changes++);
      final loading = preferences.load();
      final saving = preferences.save(
        const DrawingCursorSettings(armLength: 20),
      );
      await Future<void>.delayed(Duration.zero);
      preferences.dispose();
      ready.complete(store);
      await Future.wait([loading, saving]);
      expect(changes, 0);
      expect(store.containsKey(DrawingCursorPreferences.storageKey), isFalse);
      await expectLater(preferences.reset(), throwsStateError);
    },
  );

  testWidgets(
    'enter, hover and exit paint a thin cross and restore OS cursor',
    (tester) async {
      await tester.pumpWidget(_host());
      _expectCrosshair(tester, null);
      final mouse = await _mouse(tester, const Offset(100, 100));
      expect(_systemCursor(tester), SystemMouseCursors.none);
      _expectCrosshair(tester, const Offset(100, 100));
      await mouse.moveTo(_origin + const Offset(120, 140));
      await tester.pump();
      _expectCrosshair(tester, const Offset(120, 140));
      await mouse.moveTo(const Offset(10, 10));
      await tester.pump();
      _expectCrosshair(tester, null);
      expect(_systemCursor(tester), SystemMouseCursors.basic);
      await mouse.removePointer();
    },
  );

  testWidgets('crosshair size and position stay in screen pixels across zoom', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    final mouse = await _mouse(tester, const Offset(100, 100));
    for (final scale in [0.5, 1.0, 4.0]) {
      await tester.pumpWidget(_host(zoom: scale));
      _expectCrosshair(tester, const Offset(100, 100));
      final box = tester.renderObject<RenderBox>(_overlay);
      expect(box.localToGlobal(const Offset(92, 100)), const Offset(132, 160));
      expect(box.localToGlobal(const Offset(108, 100)), const Offset(148, 160));
      expect(_systemCursor(tester), SystemMouseCursors.none);
    }
    await mouse.removePointer();
  });

  testWidgets(
    'click, drag, scroll and keyboard reach child with original coordinates',
    (tester) async {
      final down = <Offset>[], moves = <Offset>[], scrolls = <Offset>[];
      final keys = <LogicalKeyboardKey>[];
      var taps = 0, pans = 0, builds = 0;
      await tester.pumpWidget(
        _host(
          child: Builder(
            builder: (context) {
              builds++;
              return Focus(
                autofocus: true,
                onKeyEvent: (_, event) {
                  if (event is KeyDownEvent) keys.add(event.logicalKey);
                  return KeyEventResult.handled;
                },
                child: Listener(
                  onPointerDown: (event) => down.add(event.localPosition),
                  onPointerMove: (event) => moves.add(event.localPosition),
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      scrolls.add(event.scrollDelta);
                    }
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps++,
                    onPanUpdate: (_) => pans++,
                    child: const SizedBox.expand(),
                  ),
                ),
              );
            },
          ),
        ),
      );
      final mouse = await _mouse(tester, const Offset(100, 100));
      await mouse.down(_origin + const Offset(100, 100));
      await mouse.up();
      expect(taps, 1);
      await mouse.down(_origin + const Offset(100, 100));
      await mouse.moveTo(_origin + const Offset(150, 130));
      await mouse.moveTo(_origin + const Offset(180, 140));
      await mouse.up();
      await tester.pump();
      expect(down, [const Offset(100, 100), const Offset(100, 100)]);
      expect(moves, [const Offset(150, 130), const Offset(180, 140)]);
      expect(pans, greaterThan(0));
      _expectCrosshair(tester, const Offset(180, 140));
      tester.binding.handlePointerEvent(
        const PointerScrollEvent(
          device: 1,
          kind: PointerDeviceKind.mouse,
          position: Offset(220, 200),
          scrollDelta: Offset(0, 35),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(scrolls, [const Offset(0, 35)]);
      expect(keys, [LogicalKeyboardKey.keyA]);
      expect(builds, 1);
      await mouse.removePointer();
    },
  );

  testWidgets(
    'trackpad pan and zoom reach InteractiveViewer without moving the crosshair',
    (tester) async {
      final transformation = TransformationController();
      addTearDown(transformation.dispose);
      final pans = <Offset>[], scales = <double>[];
      await tester.pumpWidget(
        _host(
          child: Listener(
            onPointerPanZoomUpdate: (event) {
              pans.add(event.pan);
              scales.add(event.scale);
            },
            child: InteractiveViewer(
              transformationController: transformation,
              constrained: false,
              minScale: 0.5,
              maxScale: 8,
              child: const SizedBox(width: 640, height: 480),
            ),
          ),
        ),
      );
      final mouse = await _mouse(tester, const Offset(100, 100));
      final trackpad = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      const point = Offset(140, 160);
      await trackpad.panZoomStart(point);
      await trackpad.panZoomUpdate(point, pan: const Offset(10, 15), scale: 2);
      await trackpad.panZoomEnd();
      await tester.pump();
      expect(pans, [const Offset(10, 15)]);
      expect(scales, [2]);
      expect(transformation.value.getMaxScaleOnAxis(), 2);
      _expectCrosshair(tester, const Offset(100, 100));
      await trackpad.removePointer();
      await mouse.removePointer();
    },
  );

  testWidgets('deep cursor honors enable, active and live preference changes', (
    tester,
  ) async {
    final preferences = DrawingCursorPreferences();
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: preferences,
        builder: (context, _) => _host(settings: preferences.value),
      ),
    );
    final mouse = await _mouse(tester, const Offset(100, 100));
    await preferences.save(
      const DrawingCursorSettings(
        armLength: 20,
        strokeWidth: 2,
        color: DrawingCursorColor.red,
      ),
    );
    await tester.pump();
    _expectCrosshair(
      tester,
      const Offset(100, 100),
      arm: 20,
      width: 2,
      color: const Color(0xFFD32F2F),
    );
    await preferences.save(preferences.value.copyWith(enabled: false));
    await tester.pump();
    _expectCrosshair(tester, null);
    expect(_systemCursor(tester), SystemMouseCursors.precise);
    await preferences.reset();
    await tester.pump();
    await mouse.moveTo(_origin + const Offset(120, 100));
    await tester.pump();
    _expectCrosshair(tester, const Offset(120, 100));
    expect(_systemCursor(tester), SystemMouseCursors.none);
    await tester.pumpWidget(_host(active: false));
    await tester.pump();
    _expectCrosshair(tester, null);
    expect(_systemCursor(tester), SystemMouseCursors.precise);
    await mouse.removePointer();
  });

  testWidgets(
    'automatic color follows background and cross is clipped at edges',
    (tester) async {
      await tester.pumpWidget(_host());
      final mouse = await _mouse(tester, const Offset(1, 1));
      _expectCrosshair(tester, const Offset(1, 1));
      await tester.pumpWidget(_host(background: Colors.black));
      _expectCrosshair(tester, const Offset(1, 1), color: Colors.white);
      await mouse.removePointer();
    },
  );

  testWidgets(
    'drag exit, cancellation and reentry never leave a stale crosshair',
    (tester) async {
      await tester.pumpWidget(_host());
      final mouse = await _mouse(tester, const Offset(100, 100));
      await mouse.down(_origin + const Offset(100, 100));
      await mouse.moveTo(const Offset(10, 10));
      await tester.pump();
      _expectCrosshair(tester, null);
      expect(_systemCursor(tester), SystemMouseCursors.basic);
      await mouse.moveTo(const Offset(15, 15));
      _expectCrosshair(tester, null);
      await mouse.moveTo(_origin + const Offset(50, 50));
      await tester.pump();
      _expectCrosshair(tester, const Offset(50, 50));
      await mouse.cancel();
      await tester.pump();
      _expectCrosshair(tester, null);
      await mouse.moveTo(_origin + const Offset(60, 60));
      await tester.pump();
      _expectCrosshair(tester, const Offset(60, 60));
      await mouse.removePointer();
    },
  );

  testWidgets('session reset clears coordinates and unmount restores cursor', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    final mouse = await _mouse(tester, const Offset(100, 100));
    await tester.pumpWidget(_host(resetKey: 'second-sheet'));
    _expectCrosshair(tester, null);
    await mouse.moveTo(_origin + const Offset(80, 70));
    await tester.pump();
    _expectCrosshair(tester, const Offset(80, 70));
    await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
    await tester.pump();
    expect(_overlay, findsNothing);
    expect(_systemCursor(tester), SystemMouseCursors.basic);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a captured drag can finish after the region is unmounted', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    final mouse = await _mouse(tester, const Offset(100, 100));
    await mouse.down(_origin + const Offset(100, 100));
    await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
    await tester.pump();
    await mouse.moveTo(_origin + const Offset(150, 100));
    await mouse.up();
    await mouse.removePointer();
    await tester.pump();
    expect(_overlay, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'opaque sibling controls take cursor and hide the drawing overlay',
    (tester) async {
      await tester.pumpWidget(_host());
      final mouse = await _mouse(tester, const Offset(100, 100));
      await tester.pumpWidget(
        _host(
          overlay: const Positioned(
            left: 110,
            top: 130,
            width: 80,
            height: 80,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ColoredBox(color: Colors.grey),
            ),
          ),
        ),
      );
      await tester.pump();
      _expectCrosshair(tester, null);
      expect(_systemCursor(tester), SystemMouseCursors.click);
      await tester.pumpWidget(_host());
      await tester.pump();
      _expectCrosshair(tester, const Offset(100, 100));
      await mouse.removePointer();
    },
  );

  testWidgets(
    'modal dialog suspends cursor and cancellation keeps preferences',
    (tester) async {
      final preferences = DrawingCursorPreferences();
      addTearDown(preferences.dispose);
      await tester.pumpWidget(_host());
      final mouse = await _mouse(tester, const Offset(100, 100));
      unawaited(
        showDrawingCursorDialog(
          tester.element(find.byType(DrawingCursorRegion)),
          preferences: preferences,
        ),
      );
      await tester.pumpAndSettle();
      _expectCrosshair(tester, null);
      expect(_systemCursor(tester), isNot(SystemMouseCursors.none));
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      expect(preferences.value, DrawingCursorSettings.defaults);
      final store = await SharedPreferences.getInstance();
      expect(store.containsKey(DrawingCursorPreferences.storageKey), isFalse);
      await mouse.moveTo(_origin + const Offset(110, 100));
      await tester.pump();
      _expectCrosshair(tester, const Offset(110, 100));
      await mouse.removePointer();
    },
  );

  testWidgets(
    'dialog saves settings, reset updates controls, and failed save can retry',
    (tester) async {
      var fail = false;
      final store = await SharedPreferences.getInstance();
      final preferences = DrawingCursorPreferences(
        loadPreferences: () async {
          if (fail) throw StateError('Synthetic store failure');
          return store;
        },
      );
      addTearDown(preferences.dispose);
      await tester.pumpWidget(_host());
      Future<void> open() async {
        unawaited(
          showDrawingCursorDialog(
            tester.element(find.byType(DrawingCursorRegion)),
            preferences: preferences,
          ),
        );
        await tester.pumpAndSettle();
      }

      await open();
      await tester.tap(find.byType(Switch));
      final arm = find.byKey(const ValueKey('drawing-cursor-arm-length'));
      final width = find.byKey(const ValueKey('drawing-cursor-stroke-width'));
      await tester.tapAt(tester.getCenter(arm) + const Offset(60, 0));
      await tester.tapAt(tester.getCenter(width) + const Offset(60, 0));
      await tester.tap(
        find.byType(DropdownButtonFormField<DrawingCursorColor>),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Červená').last);
      await tester.pumpAndSettle();
      fail = true;
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(
        find.text('Nastavení se nepodařilo uložit. Zkuste to znovu.'),
        findsOneWidget,
      );
      expect(preferences.value, DrawingCursorSettings.defaults);
      fail = false;
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(find.byType(DrawingCursorDialog), findsNothing);
      expect(preferences.value.enabled, isFalse);
      expect(preferences.value.armLength, greaterThan(8));
      expect(preferences.value.strokeWidth, greaterThan(1));
      expect(preferences.value.color, DrawingCursorColor.red);
      await open();
      await tester.tap(find.text('Výchozí'));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(arm).value, 8);
      expect(tester.widget<Slider>(width).value, 1);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text('Automatická podle pozadí'), findsOneWidget);
      expect(preferences.value.color, DrawingCursorColor.red);
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(preferences.value, DrawingCursorSettings.defaults);
      final restored = DrawingCursorPreferences(
        loadPreferences: () async => store,
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.value, DrawingCursorSettings.defaults);
    },
  );

  testWidgets(
    'window focus loss clears the crosshair until a fresh pointer event',
    (tester) async {
      await tester.pumpWidget(_host());
      final mouse = await _mouse(tester, const Offset(100, 100));
      void focus(ViewFocusState state) {
        tester.binding.platformDispatcher.onViewFocusChange?.call(
          ViewFocusEvent(
            viewId: tester.view.viewId,
            state: state,
            direction: ViewFocusDirection.undefined,
          ),
        );
      }

      focus(ViewFocusState.unfocused);
      await tester.pump();
      _expectCrosshair(tester, null);
      expect(_systemCursor(tester), isNot(SystemMouseCursors.none));
      focus(ViewFocusState.focused);
      await tester.pump();
      _expectCrosshair(tester, null);
      await mouse.moveTo(_origin + const Offset(110, 100));
      await tester.pump();
      _expectCrosshair(tester, const Offset(110, 100));
      await mouse.removePointer();
    },
  );

  testWidgets('inactive app and touch input do not leave a mouse crosshair', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.tapAt(_origin + const Offset(100, 100));
    _expectCrosshair(tester, null);
    final mouse = await _mouse(tester, const Offset(100, 100));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    _expectCrosshair(tester, null);
    expect(_systemCursor(tester), isNot(SystemMouseCursors.none));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await mouse.moveTo(_origin + const Offset(110, 100));
    await tester.pump();
    _expectCrosshair(tester, const Offset(110, 100));
    await mouse.removePointer();
  });
}
