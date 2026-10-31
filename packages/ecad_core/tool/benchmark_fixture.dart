// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';

EcadProject createBenchmarkProject({
  required int deviceCount,
  int devicesPerSheet = 80,
}) {
  if (deviceCount <= 0 ||
      deviceCount > ProjectLimits.maxDevices ||
      deviceCount % 5 != 0 ||
      devicesPerSheet < 5 ||
      devicesPerSheet > 80 ||
      devicesPerSheet % 5 != 0)
    throw ArgumentError(
      'Counts must be multiples of five within the fixture limits.',
    );
  final sheets = <Sheet>[];
  final components = <Component>[];
  for (var offset = 0; offset < deviceCount; offset += devicesPerSheet) {
    final devices = <Device>[];
    final wires = <Wire>[];
    for (var i = offset; i < deviceCount && i < offset + devicesPerSheet; i++) {
      final deviceId = 'device_$i',
          componentId = 'component_$i',
          functionId = 'function_$i';
      final ports = definitionFor(DeviceKind.breaker).ports;
      final terminals = [
        for (final p in ports)
          ComponentTerminal(id: 'terminal_${i}_${p.id}', designation: p.label),
      ];
      components.add(
        Component(
          id: componentId,
          designation: '-Q${i + 1}',
          electrical: ElectricalModel(
            terminals: terminals,
            functions: [
              ComponentFunction(
                id: functionId,
                name: 'Synthetic function',
                terminalIds: terminals.map((t) => t.id).toList(),
              ),
            ],
          ),
        ),
      );
      devices.add(
        Device(
          id: deviceId,
          componentId: componentId,
          functionId: functionId,
          symbol: BuiltinSymbolSpec(
            kind: DeviceKind.breaker,
            bindings: {
              for (var j = 0; j < ports.length; j++)
                ports[j].id: terminals[j].id,
            },
          ),
          position: Vec2(
            120 + ((i - offset) % 10) * 90,
            90 + ((i - offset) ~/ 10) * 80,
          ),
        ),
      );
      if (i > offset)
        wires.add(
          Wire(
            id: 'wire_$i',
            from: TerminalRef(deviceId: 'device_${i - 1}', portId: 'out'),
            to: TerminalRef(deviceId: deviceId, portId: 'in'),
          ),
        );
    }
    sheets.add(
      Sheet(
        id: 'sheet_${sheets.length}',
        name: 'Synthetic symbols ${sheets.length + 1}',
        number: '${sheets.length + 1}',
        devices: devices,
        wires: wires,
      ),
    );
  }
  return EcadProject(
    id: 'benchmark_$deviceCount',
    name: 'Synthetic benchmark',
    components: components,
    pages: sheets,
  );
}
