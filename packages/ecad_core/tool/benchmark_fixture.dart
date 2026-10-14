// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';

/// Deterministic, original benchmark data. Nothing is read from a user project.
///
/// Each illustrative feeder has a source, breaker, contactor, motor, and PE
/// reference; four terminal-based wires connect all its ports. A sheet contains
/// at most 16 feeders (80 devices), arranged in a 4 by 4 grid. This models a
/// large multi-sheet document, not a construction-ready electrical design.
EcadProject createBenchmarkProject({
  required int deviceCount,
  int devicesPerSheet = 80,
}) {
  if (deviceCount <= 0 ||
      deviceCount > ProjectLimits.maxDevices ||
      deviceCount % 5 != 0) {
    throw ArgumentError.value(
      deviceCount,
      'deviceCount',
      'Must be a multiple of 5 within the core device limit.',
    );
  }
  if (devicesPerSheet < 5 || devicesPerSheet > 80 || devicesPerSheet % 5 != 0) {
    throw ArgumentError.value(
      devicesPerSheet,
      'devicesPerSheet',
      'Must be a multiple of 5 between 5 and 80.',
    );
  }
  final sheetCount = (deviceCount / devicesPerSheet).ceil();
  if (sheetCount > ProjectLimits.maxPages) {
    throw ArgumentError(
      'Fixture would exceed the ${ProjectLimits.maxPages}-sheet limit.',
    );
  }
  final sheets = <Sheet>[];
  var feederIndex = 0;
  var remaining = deviceCount;
  for (var sheetIndex = 0; sheetIndex < sheetCount; sheetIndex++) {
    final feedersOnSheet =
        (remaining < devicesPerSheet ? remaining : devicesPerSheet) ~/ 5;
    final devices = <Device>[];
    final wires = <Wire>[];
    for (var slot = 0; slot < feedersOnSheet; slot++) {
      final suffix = (++feederIndex).toString().padLeft(5, '0');
      final x = 120.0 + (slot % 4) * 400;
      final y = 80.0 + (slot ~/ 4) * 420;
      final supply = Device(
        id: 'g_$suffix',
        kind: DeviceKind.supply,
        designation: '-G$suffix',
        position: Vec2(x, y),
        description: 'Ilustrační třífázový přívod',
        rating: '3~ 400 V',
      );
      final breaker = Device(
        id: 'q_$suffix',
        kind: DeviceKind.breaker,
        designation: '-Q$suffix',
        position: Vec2(x, y + 80),
        description: 'Jistič vývodu',
        rating: '3P · 10 A',
      );
      final contactor = Device(
        id: 'k_$suffix',
        kind: DeviceKind.contactor,
        designation: '-K$suffix',
        position: Vec2(x, y + 170),
        description: 'Stykač motoru',
        rating: '3P · AC-3',
      );
      final motor = Device(
        id: 'm_$suffix',
        kind: DeviceKind.motor,
        designation: '-M$suffix',
        position: Vec2(x, y + 260),
        description: 'Ilustrační pohon',
        rating: '3~ · 2,2 kW',
      );
      final earth = Device(
        id: 'pe_$suffix',
        kind: DeviceKind.earth,
        designation: '-PE$suffix',
        position: Vec2(x + 120, y + 340),
        description: 'Ochranné uzemnění',
      );
      devices.addAll([supply, breaker, contactor, motor, earth]);
      Wire link(
        String name,
        Device from,
        String fromPort,
        Device to,
        String toPort, [
        List<Vec2> route = const [],
      ]) => Wire(
        id: '${name}_$suffix',
        from: TerminalRef(deviceId: from.id, portId: fromPort),
        to: TerminalRef(deviceId: to.id, portId: toPort),
        waypoints: route,
      );
      wires.addAll([
        link('w1', supply, 'out', breaker, 'in'),
        link('w2', breaker, 'out', contactor, 'in'),
        link('w3', contactor, 'out', motor, 'in'),
        link('w4', motor, 'pe', earth, 'in', [Vec2(x + 120, y + 260)]),
      ]);
    }
    sheets.add(
      Sheet(
        id: 'sheet_${sheetIndex + 1}',
        name: 'Ilustrační vývody ${sheetIndex + 1}',
        number: (sheetIndex + 1).toString().padLeft(3, '0'),
        devices: devices,
        wires: wires,
      ),
    );
    remaining -= devices.length;
  }
  return EcadProject(
    id: 'benchmark_$deviceCount',
    name: 'Deterministický benchmark · $deviceCount přístrojů',
    description:
        'Syntetický více-listový projekt pro měření datového jádra. '
        'Ilustrační jednopólové vývody; nejde o elektrotechnický návrh.',
    pages: sheets,
  );
}
