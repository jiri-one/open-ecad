// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/editor/canvas_hover_overlay.dart';
import 'package:open_ecad/services/device_hover_info.dart';

import 'device_hover_fixtures.dart';

const _identity = Object();
const _delay = Duration(milliseconds: 350);

DeviceHoverInfo _info(EcadProject project) =>
    resolveDeviceHoverInfo(
      resolver: ProjectResolver(project),
      sheetId: 'schematic',
      deviceId: 'opaque-device',
    )!;

Future<void> _show(
  WidgetTester tester,
  DeviceHoverInfo info, {
  Offset position = const Offset(100, 100),
  Object identity = _identity,
  Size size = const Size(640, 480),
  double textScale = 1,
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
            child: CanvasHoverOverlay(
              info: info,
              contextIdentity: identity,
              localPosition: position,
              maxWidth: 360,
              maxLines: 12,
              child: child ?? const ColoredBox(color: Colors.white),
            ),
          ),
        ),
      ),
    ),
  ),
);

class _EqualIdentity {
  @override
  bool operator ==(Object other) => other is _EqualIdentity;
  @override
  int get hashCode => 0;
}

void main() {
  testWidgets(
    'stationary content and equal document identities restart the dwell',
    (tester) async {
      final project = deviceHoverProject();
      final first = _info(project);
      final identity = _EqualIdentity();
      await _show(tester, first, identity: identity);
      await tester.pump(_delay);
      expect(find.text(first.tooltip), findsOneWidget);
      final edited = _info(
        project.copyWith(
          components: [
            project.components.first.copyWith(
              description: 'Nový stacionární popis',
            ),
            project.components.last,
          ],
        ),
      );
      await _show(tester, edited, identity: identity);
      expect(find.text(first.tooltip), findsNothing);
      expect(find.text(edited.tooltip), findsNothing);
      await tester.pump(_delay);
      expect(find.text(edited.tooltip), findsOneWidget);
      final secondIdentity = _EqualIdentity();
      expect(secondIdentity, identity);
      await _show(tester, edited, identity: secondIdentity);
      expect(find.text(edited.tooltip), findsNothing);
      await tester.pump(_delay);
      expect(find.text(edited.tooltip), findsOneWidget);
    },
  );

  testWidgets('all device rows fit at viewport edges with full semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final info = _info(deviceHoverProject());
      for (final size in [const Size(640, 480), const Size(240, 210)]) {
        for (final point in [
          Offset.zero,
          Offset(size.width - 1, 0),
          Offset(0, size.height - 1),
          Offset(size.width - 1, size.height - 1),
        ]) {
          await _show(
            tester,
            info,
            size: size,
            position: point,
            textScale: size.width < 300 ? 2 : 1,
          );
          await tester.pump(_delay);
          expect(find.bySemanticsLabel(info.semanticsLabel), findsOneWidget);
          final bubble = tester.getRect(
            find.ancestor(
              of: find.text(info.tooltip),
              matching: find.byType(DecoratedBox),
            ),
          );
          expect((Offset.zero & size).contains(bubble.topLeft), isTrue);
          expect((Offset.zero & size).contains(bubble.bottomRight), isTrue);
          expect(tester.takeException(), isNull);
        }
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('device bubble ignores mouse hover, click, drag and scroll', (
    tester,
  ) async {
    var taps = 0, drags = 0, hovers = 0, scrolls = 0;
    final info = _info(deviceHoverProject());
    await _show(
      tester,
      info,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerHover: (_) => hovers++,
        onPointerSignal: (_) => scrolls++,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => taps++,
          onPanUpdate: (_) => drags++,
          child: const ColoredBox(color: Colors.white),
        ),
      ),
    );
    await tester.pump(_delay);
    final position = tester.getCenter(find.text(info.tooltip));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(position);
    await tester.tapAt(position);
    await tester.dragFrom(position, const Offset(30, 0));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: position, scrollDelta: const Offset(0, 20)),
    );
    expect(taps, 1);
    expect(drags, greaterThan(0));
    expect(hovers, greaterThan(0));
    expect(scrolls, 1);
    await mouse.removePointer();
  });
}
