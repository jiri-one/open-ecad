// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/editor/wire_hover_overlay.dart';
import 'package:open_ecad/services/wire_hover_info.dart';

const _contextIdentity = Object();
const _delay = Duration(milliseconds: 350);

WireHoverInfo _info({
  EcadProject? project,
  String sheetId = 'synthetic-sheet',
  String wireId = 'synthetic-wire',
  String from = '-K71:14',
  String to = '-X82:3',
  String? detail,
}) => WireHoverInfo(
  project:
      project ??
      EcadProject(id: 'synthetic-project', name: 'Syntetický hover', pages: []),
  sheetId: sheetId,
  wireId: wireId,
  from: WireHoverEndpointInfo(label: from, detail: detail),
  to: WireHoverEndpointInfo(label: to),
);

Future<void> _show(
  WidgetTester tester, {
  required WireHoverInfo? info,
  Object contextIdentity = _contextIdentity,
  Offset? position = const Offset(160, 120),
  Size size = const Size(640, 480),
  bool active = true,
  bool suppressed = false,
  Duration delay = _delay,
  double textScale = 1,
  Rect? avoidRect,
  Widget? child,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: WireHoverOverlay(
              info: info,
              contextIdentity: contextIdentity,
              localPosition: position,
              active: active,
              suppressed: suppressed,
              delay: delay,
              avoidRect: avoidRect,
              child: child ?? const ColoredBox(color: Colors.white),
            ),
          ),
        ),
      ),
    ),
  ),
);

Rect _bubbleRect(WidgetTester tester, WireHoverInfo info) => tester.getRect(
  find.ancestor(
    of: find.text(info.tooltip),
    matching: find.byType(DecoratedBox),
  ),
);

class _EqualIdentity {
  @override
  bool operator ==(Object other) => other is _EqualIdentity;

  @override
  int get hashCode => 0;
}

void main() {
  testWidgets('waits 350 ms and keeps waiting while moving on the same wire', (
    tester,
  ) async {
    final info = _info();
    await _show(tester, info: info);
    expect(find.text(info.tooltip), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    await _show(
      tester,
      info: _info(project: info.project),
      position: const Offset(180, 125),
    );
    await tester.pump(const Duration(milliseconds: 149));
    expect(find.text(info.tooltip), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text(info.tooltip), findsOneWidget);
    final oldRect = _bubbleRect(tester, info);
    await _show(tester, info: info, position: const Offset(200, 145));
    expect(find.text(info.tooltip), findsOneWidget);
    expect(
      _bubbleRect(tester, info).topLeft - oldRect.topLeft,
      const Offset(20, 20),
    );
  });

  testWidgets(
    'switching wires restarts the delay and cancels the previous timer',
    (tester) async {
      final first = _info();
      final second = _info(
        project: first.project,
        wireId: 'other-wire',
        to: '-X83:2',
      );
      await _show(tester, info: first);
      await tester.pump(const Duration(milliseconds: 300));
      await _show(tester, info: second);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(first.tooltip), findsNothing);
      expect(find.text(second.tooltip), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(second.tooltip), findsOneWidget);
      await _show(tester, info: first);
      expect(find.text(second.tooltip), findsNothing);
      expect(find.text(first.tooltip), findsNothing);
      await tester.pump(_delay);
      expect(find.text(first.tooltip), findsOneWidget);
    },
  );

  testWidgets(
    'another document with equal IDs cannot retain the visible bubble',
    (tester) async {
      final first = _info();
      final second = _info(from: '-K72:24');
      expect(second.project.id, first.project.id);
      expect(second.project.revision, first.project.revision);
      await _show(tester, info: first);
      await tester.pump(_delay);
      expect(find.text(first.tooltip), findsOneWidget);
      await _show(tester, info: second);
      expect(find.text(first.tooltip), findsNothing);
      expect(find.text(second.tooltip), findsNothing);
      await tester.pump(_delay);
      expect(find.text(second.tooltip), findsOneWidget);
    },
  );

  testWidgets('new snapshot cancels a pending bubble even when labels match', (
    tester,
  ) async {
    final first = _info();
    final second = _info();
    expect(first.tooltip, second.tooltip);
    await _show(tester, info: first);
    await tester.pump(const Duration(milliseconds: 300));
    await _show(tester, info: second);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(second.tooltip), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(second.tooltip), findsOneWidget);
  });

  testWidgets('document identity uses object identity even for equal objects', (
    tester,
  ) async {
    final first = _EqualIdentity();
    final second = _EqualIdentity();
    final info = _info();
    expect(first, second);
    await _show(tester, info: info, contextIdentity: first);
    await tester.pump(_delay);
    expect(find.text(info.tooltip), findsOneWidget);
    await _show(tester, info: info, contextIdentity: second);
    expect(find.text(info.tooltip), findsNothing);
    await tester.pump(_delay);
    expect(find.text(info.tooltip), findsOneWidget);
  });

  testWidgets('sheet switch with equal wire IDs hides the old bubble', (
    tester,
  ) async {
    final first = _info();
    final second = _info(project: first.project, sheetId: 'other-sheet');
    await _show(tester, info: first);
    await tester.pump(_delay);
    await _show(tester, info: second);
    expect(find.text(first.tooltip), findsNothing);
    await tester.pump(_delay);
    expect(find.text(second.tooltip), findsOneWidget);
  });

  testWidgets(
    'changed adapter text on the same target also restarts the delay',
    (tester) async {
      final first = _info();
      final second = _info(
        project: first.project,
        detail: 'Přes spojovací roh',
      );
      await _show(tester, info: first);
      await tester.pump(_delay);
      await _show(tester, info: second);
      expect(find.text(first.tooltip), findsNothing);
      expect(find.text(second.tooltip), findsNothing);
      await tester.pump(_delay);
      expect(find.text(second.tooltip), findsOneWidget);
    },
  );

  testWidgets('exit, no hit and a missing pointer hide immediately', (
    tester,
  ) async {
    final info = _info();
    for (final reason in ['exit', 'no hit', 'no pointer']) {
      await _show(tester, info: info);
      await tester.pump(_delay);
      expect(find.text(info.tooltip), findsOneWidget);
      await _show(
        tester,
        info: reason == 'no hit' ? null : info,
        position: reason == 'no pointer' ? null : const Offset(160, 120),
        active: reason != 'exit',
      );
      expect(find.text(info.tooltip), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(info.tooltip), findsNothing);
      await _show(tester, info: info);
      await tester.pump(const Duration(milliseconds: 349));
      expect(find.text(info.tooltip), findsNothing);
    }
  });

  testWidgets(
    'exit cancels a pending timer and dispose leaves no delayed work',
    (tester) async {
      final info = _info();
      await _show(tester, info: info);
      await tester.pump(const Duration(milliseconds: 300));
      await _show(tester, info: info, active: false);
      await tester.pump(_delay);
      expect(find.text(info.tooltip), findsNothing);
      await _show(tester, info: info);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(find.text(info.tooltip), findsNothing);
    },
  );

  testWidgets('pan, drag or drawing suppression hides and restarts the wait', (
    tester,
  ) async {
    final info = _info();
    await _show(tester, info: info);
    await tester.pump(_delay);
    await _show(tester, info: info, suppressed: true);
    expect(find.text(info.tooltip), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(info.tooltip), findsNothing);
    await _show(tester, info: info);
    await tester.pump(const Duration(milliseconds: 300));
    await _show(tester, info: info, suppressed: true);
    await tester.pump(_delay);
    expect(find.text(info.tooltip), findsNothing);
    await _show(tester, info: info);
    await tester.pump(const Duration(milliseconds: 349));
    expect(find.text(info.tooltip), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text(info.tooltip), findsOneWidget);
  });

  testWidgets('bubble stays inside each edge and leaves space at the pointer', (
    tester,
  ) async {
    final info = _info(detail: 'Signál: TEST-SIGNAL');
    const size = Size(400, 240);
    for (final position in [
      const Offset(1, 1),
      const Offset(399, 1),
      const Offset(1, 239),
      const Offset(399, 239),
      const Offset(200, 1),
      const Offset(200, 239),
    ]) {
      await _show(tester, info: info, position: position, size: size);
      await tester.pump(_delay);
      final rect = _bubbleRect(tester, info);
      expect(rect.left, greaterThanOrEqualTo(8));
      expect(rect.top, greaterThanOrEqualTo(8));
      expect(rect.right, lessThanOrEqualTo(size.width - 8));
      expect(rect.bottom, lessThanOrEqualTo(size.height - 8));
      expect(rect.contains(position), isFalse);
      expect(
        rect.overlaps(Rect.fromCircle(center: position, radius: 10)),
        isFalse,
      );
    }
  });

  testWidgets('bubble avoids a supplied important terminal rectangle', (
    tester,
  ) async {
    final info = _info();
    const avoidRect = Rect.fromLTWH(175, 135, 180, 50);
    await _show(tester, info: info, avoidRect: avoidRect);
    await tester.pump(_delay);
    expect(_bubbleRect(tester, info).overlaps(avoidRect.inflate(4)), isFalse);
  });

  testWidgets(
    'long text and larger text scale fit a narrow canvas after resize',
    (tester) async {
      final info = _info(
        from: 'Přístroj bez označení:vývod bez označení',
        to: 'Pokračování zkušebního signálu s dlouhým názvem',
        detail: List.filled(12, 'Cílový list: Zkušební list').join(', '),
      );
      await _show(tester, info: info);
      await tester.pump(_delay);
      await _show(
        tester,
        info: info,
        size: const Size(180, 130),
        position: const Offset(179, 129),
        textScale: 2,
      );
      final rect = _bubbleRect(tester, info);
      expect(rect.left, greaterThanOrEqualTo(8));
      expect(rect.top, greaterThanOrEqualTo(8));
      expect(rect.right, lessThanOrEqualTo(172));
      expect(rect.bottom, lessThanOrEqualTo(122));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tiny canvas and positions outside the canvas do not paint', (
    tester,
  ) async {
    final info = _info();
    await _show(
      tester,
      info: info,
      size: const Size(60, 40),
      position: Offset.zero,
    );
    await tester.pump(_delay);
    expect(find.text(info.tooltip), findsNothing);
    for (final position in [
      const Offset(-1, 100),
      const Offset(700, 100),
      const Offset(100, 500),
      const Offset(double.nan, 100),
    ]) {
      await _show(tester, info: info, position: position);
      await tester.pump(_delay);
      expect(find.text(info.tooltip), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'click, drag, hover and scroll reach the child through the bubble',
    (tester) async {
      final info = _info();
      var taps = 0;
      var drags = 0;
      var hovers = 0;
      var scrolls = 0;
      final child = Listener(
        behavior: HitTestBehavior.opaque,
        onPointerHover: (_) => hovers++,
        onPointerSignal: (_) => scrolls++,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => taps++,
          onPanUpdate: (_) => drags++,
          child: const ColoredBox(color: Colors.white),
        ),
      );
      await _show(tester, info: info, child: child);
      await tester.pump(_delay);
      final target = _bubbleRect(tester, info).center;
      await tester.tapAt(target);
      expect(taps, 1);
      await tester.dragFrom(target, const Offset(50, 0));
      expect(drags, greaterThan(0));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(target);
      expect(hovers, greaterThan(0));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: target, scrollDelta: const Offset(0, 20)),
      );
      expect(scrolls, 1);
      await mouse.removePointer();
    },
  );

  testWidgets('keeps a child cursor overlay and its mouse cursor', (
    tester,
  ) async {
    final info = _info();
    const cursorKey = ValueKey('synthetic-drawing-cursor');
    await _show(
      tester,
      info: info,
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        child: Stack(
          fit: StackFit.expand,
          children: const [
            ColoredBox(color: Colors.white),
            Positioned(
              left: 158,
              top: 118,
              child: IgnorePointer(
                child: SizedBox(key: cursorKey, width: 4, height: 4),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump(_delay);
    expect(find.byKey(cursorKey), findsOneWidget);
    expect(
      _bubbleRect(tester, info).overlaps(tester.getRect(find.byKey(cursorKey))),
      isFalse,
    );
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 17,
    );
    await mouse.addPointer(location: const Offset(160, 120));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.precise,
    );
    await mouse.moveTo(_bubbleRect(tester, info).center);
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.precise,
    );
    await mouse.removePointer();
  });

  testWidgets(
    'exposes a full Czech semantics label even when text is ellipsized',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final info = _info(
          detail: List.filled(10, 'Přes spojovací roh').join(', '),
        );
        await _show(tester, info: info);
        await tester.pump(_delay);
        expect(find.bySemanticsLabel(info.semanticsLabel), findsOneWidget);
        final node = tester.getSemantics(
          find.bySemanticsLabel(info.semanticsLabel),
        );
        expect(node.label, contains('Spoj z -K71:14 do -X82:3.'));
        expect(node.label, contains(info.from.detail!));
        await _show(tester, info: info, suppressed: true);
        expect(find.bySemanticsLabel(info.semanticsLabel), findsNothing);
      } finally {
        semantics.dispose();
      }
    },
  );
}
