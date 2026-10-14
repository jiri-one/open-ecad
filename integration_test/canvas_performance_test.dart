import 'dart:math' as math;
import 'dart:ui';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';

/// Native engine timings, deliberately separate from VM command-engine timings.
/// Run through scripts/run_canvas_benchmark.sh; debug-mode results are rejected.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'profile 1000 devices while panning and zooming',
    (tester) async {
      expect(
        kProfileMode,
        isTrue,
        reason: 'Rendering measurements require a native --profile build.',
      );
      final controller = SchematicViewportController();
      final sheet = _busySheet();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: SchematicCanvas(
            sheet: sheet,
            selectedIds: const {},
            mode: CanvasMode.pan,
            showGrid: true,
            palette: const CanvasPalette(
              background: Colors.white,
              paper: Colors.white,
              ink: Colors.black,
              muted: Colors.black,
              grid: Colors.black,
              selection: Colors.black,
              wire: Colors.black,
              sheetBorder: Colors.black,
              highContrast: true,
            ),
            controller: controller,
            onSelectionChanged: (_) {},
            onMoveDevices: (_) {},
            onPlaceDevice: (_, _) {},
            onConnect: (_, _) {},
            onDeleteWire: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final center = tester.getCenter(find.byType(SchematicCanvas));
      controller.reset();
      await tester.pumpAndSettle();

      // This policy honors real framework frame requests and does not inject
      // extra frames for WidgetTester.pump or animated test-pointer crosshairs.
      binding.framePolicy =
          LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
      final working = await _measure(tester, controller, center);

      controller.reset();
      for (var i = 0; i < 12; i++) {
        controller.zoomOut();
      }
      await SchedulerBinding.instance.endOfFrame;
      // Center the whole 1000-device field at the minimum zoom. This second
      // workload deliberately draws almost every primitive, exercising paint
      // costs in addition to the working view's spatial culling.
      final offsetToSceneCenter = Offset(
        (550 - 1650) * controller.zoom,
        (390 - 1800) * controller.zoom,
      );
      await tester.dragFrom(center, offsetToSceneCenter);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        controller.visiblePrimitiveCount,
        greaterThanOrEqualTo(1600),
        reason: 'The overview must draw most of the 1800 scene primitives.',
      );
      final overview = await _measure(tester, controller, center);

      binding.reportData = {
        'canvas_profile': {
          'capturedAtUtc': DateTime.now().toUtc().toIso8601String(),
          'buildMode': 'profile',
          'platform': defaultTargetPlatform.name,
          'environment': const String.fromEnvironment(
            'BENCHMARK_ENV',
            defaultValue: 'Native desktop; renderer not recorded',
          ),
          'deviceCount': sheet.devices.length,
          'wireCount': sheet.wires.length,
          'viewportLogicalPixels': {
            'width':
                tester.view.physicalSize.width / tester.view.devicePixelRatio,
            'height':
                tester.view.physicalSize.height / tester.view.devicePixelRatio,
          },
          'budgetMs': _budgetMs,
          'notes': [
            'Real engine FrameTiming samples from a native profile build.',
            'Build plus raster is a sum of CPU/GPU-stage durations, not throughput.',
            'totalSpan includes scheduling and pipeline waits; no refresh rate is inferred.',
            '16.7 ms is a comparison budget, not a claim about monitor refresh rate.',
            'The overview intentionally exposes most of the scene; see visible primitive counts.',
            'Canvas hides unreadable labels and tiny terminal dots below 45% zoom; all symbols and wires remain.',
            'Results depend on hardware, renderer, viewport, and competing processes.',
          ],
          'working_view': working,
          'overview': overview,
        },
      };
      expect(working['frameCount'], greaterThan(0));
      expect(overview['frameCount'], greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
    timeout: const Timeout(Duration(seconds: 55)),
  );
}

const _budgetMs = 16.7;

Future<Map<String, Object?>> _measure(
  WidgetTester tester,
  SchematicViewportController controller,
  Offset center,
) async {
  // Engine timing callbacks may be batched by about a second. Flush preceding
  // frames before registering, then allow the final batch to arrive afterwards.
  await Future<void>.delayed(const Duration(seconds: 2));
  final timings = <FrameTiming>[];
  void record(List<FrameTiming> values) => timings.addAll(values);
  SchedulerBinding.instance.addTimingsCallback(record);
  final watch = Stopwatch()..start();
  var events = 0;
  var minVisible = controller.visiblePrimitiveCount;
  var maxVisible = minVisible;
  final initialZoom = controller.zoom;
  try {
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    for (var i = 0; i < 80 && watch.elapsedMilliseconds < 10000; i++) {
      final angle = i * math.pi * 2 / 79;
      await gesture.moveTo(
        center + Offset(math.sin(angle) * 140, (math.cos(angle) - 1) * 55),
      );
      await Future<void>.delayed(const Duration(milliseconds: 16));
      events++;
      minVisible = math.min(minVisible, controller.visiblePrimitiveCount);
      maxVisible = math.max(maxVisible, controller.visiblePrimitiveCount);
    }
    await gesture.up();
    for (var i = 0; i < 48 && watch.elapsedMilliseconds < 10000; i++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: center,
          scrollDelta: Offset(0, i < 24 ? -10 : 10),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 16));
      events++;
      minVisible = math.min(minVisible, controller.visiblePrimitiveCount);
      maxVisible = math.max(maxVisible, controller.visiblePrimitiveCount);
    }
    watch.stop();
    await Future<void>.delayed(const Duration(seconds: 2));
  } finally {
    SchedulerBinding.instance.removeTimingsCallback(record);
  }
  final build =
      timings.map((f) => f.buildDuration.inMicroseconds / 1000).toList();
  final raster =
      timings.map((f) => f.rasterDuration.inMicroseconds / 1000).toList();
  final combined =
      timings
          .map(
            (f) =>
                (f.buildDuration.inMicroseconds +
                    f.rasterDuration.inMicroseconds) /
                1000,
          )
          .toList();
  final total = timings.map((f) => f.totalSpan.inMicroseconds / 1000).toList();
  return {
    'frameCount': timings.length,
    'inputEvents': events,
    'interactionWallTimeMs': watch.elapsedMilliseconds,
    'stoppedAtTimeLimit': events < 128,
    'initialZoom': initialZoom,
    'visiblePrimitives': {
      'minimum': minVisible,
      'maximum': maxVisible,
      'total': controller.totalPrimitiveCount,
    },
    'buildMs': _distribution(build),
    'rasterMs': _distribution(raster),
    'buildPlusRasterMs': _distribution(combined),
    'totalSpanMs': _distribution(total),
    'overBudgetFrames': {
      'build': build.where((n) => n > _budgetMs).length,
      'raster': raster.where((n) => n > _budgetMs).length,
      'buildOrRaster':
          timings
              .where(
                (f) =>
                    f.buildDuration.inMicroseconds > _budgetMs * 1000 ||
                    f.rasterDuration.inMicroseconds > _budgetMs * 1000,
              )
              .length,
      'buildPlusRaster': combined.where((n) => n > _budgetMs).length,
      'totalSpan': total.where((n) => n > _budgetMs).length,
    },
    'rawFrameTimingsUs': [
      for (final frame in timings)
        {
          'build': frame.buildDuration.inMicroseconds,
          'raster': frame.rasterDuration.inMicroseconds,
          'totalSpan': frame.totalSpan.inMicroseconds,
          'vsyncOverhead': frame.vsyncOverhead.inMicroseconds,
        },
    ],
  };
}

Map<String, double?> _distribution(List<double> samples) {
  samples.sort();
  double? percentile(double fraction) =>
      samples.isEmpty
          ? null
          : samples[(samples.length * fraction).ceil().clamp(
                1,
                samples.length,
              ) -
              1];
  return {
    'p50': percentile(0.5),
    'p95': percentile(0.95),
    'worst': samples.isEmpty ? null : samples.last,
  };
}

Sheet _busySheet() {
  final devices = <Device>[];
  final wires = <Wire>[];
  const kinds = [
    DeviceKind.supply,
    DeviceKind.breaker,
    DeviceKind.contactor,
    DeviceKind.motor,
    DeviceKind.earth,
  ];
  for (var feeder = 0; feeder < 200; feeder++) {
    final column = feeder % 25;
    final row = feeder ~/ 25;
    for (var item = 0; item < kinds.length; item++) {
      final kind = kinds[item];
      devices.add(
        Device(
          id: 'f${feeder}_$item',
          kind: kind,
          designation:
              '-${SymbolCatalog.definitionFor(kind).prefix}${feeder + 1}',
          position: Vec2(90 + column * 130, 140 + row * 430 + item * 76),
          rating: item == 0 ? '3~ 400 V' : (item == 3 ? '2.2 kW' : ''),
        ),
      );
      if (item > 0) {
        wires.add(
          Wire(
            id: 'w${feeder}_$item',
            from: TerminalRef(
              deviceId: 'f${feeder}_${item - 1}',
              portId: item == 4 ? 'pe' : 'out',
            ),
            to: TerminalRef(deviceId: 'f${feeder}_$item', portId: 'in'),
          ),
        );
      }
    }
  }
  return Sheet(
    id: 'benchmark',
    name: 'Rendering workload · 200 motor feeders',
    number: '01',
    devices: devices,
    wires: wires,
  );
}
