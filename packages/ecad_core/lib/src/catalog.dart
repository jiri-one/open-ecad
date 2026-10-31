// SPDX-License-Identifier: GPL-3.0-or-later
import 'model.dart';
import 'terminal_symbol_geometry.dart';

class PortDefinition {
  const PortDefinition({
    required this.id,
    required this.label,
    required this.position,
    this.direction,
  });
  final String id;
  final String label;

  /// Offset from the symbol's center, before rotation.
  final Vec2 position;
  final Vec2? direction;
}

class SymbolDefinition {
  const SymbolDefinition({
    required this.kind,
    required this.label,
    required this.prefix,
    required this.width,
    required this.height,
    required this.ports,
  });
  final DeviceKind kind;
  final String label;
  final String prefix;
  final double width;
  final double height;
  final List<PortDefinition> ports;

  PortDefinition? portById(String id) {
    for (final port in ports) {
      if (port.id == id) return port;
    }
    return null;
  }
}

/// Original, deliberately small symbol vocabulary for an illustrative editor.
/// These are generic symbols, without a claim of standards certification.
abstract final class SymbolCatalog {
  // Independent pole pairs on the 10-unit grid, so each pole can be wired
  // straight to single-pole symbols placed beside it.
  static const _threePolePorts = <PortDefinition>[
    PortDefinition(id: '1', label: '1', position: Vec2(-20, -32)),
    PortDefinition(id: '2', label: '2', position: Vec2(-20, 32)),
    PortDefinition(id: '3', label: '3', position: Vec2(0, -32)),
    PortDefinition(id: '4', label: '4', position: Vec2(0, 32)),
    PortDefinition(id: '5', label: '5', position: Vec2(20, -32)),
    PortDefinition(id: '6', label: '6', position: Vec2(20, 32)),
  ];

  static const definitions = <SymbolDefinition>[
    SymbolDefinition(
      kind: DeviceKind.supply,
      label: 'Napájecí zdroj',
      prefix: 'G',
      width: 64,
      height: 52,
      ports: [PortDefinition(id: 'out', label: 'L / +', position: Vec2(0, 26))],
    ),
    SymbolDefinition(
      kind: DeviceKind.breaker,
      label: 'Jistič',
      prefix: 'Q',
      width: 46,
      height: 64,
      ports: [
        PortDefinition(id: 'in', label: '1', position: Vec2(0, -32)),
        PortDefinition(id: 'out', label: '2', position: Vec2(0, 32)),
      ],
    ),
    SymbolDefinition(
      kind: DeviceKind.threePoleBreaker,
      label: 'Třípólový jistič',
      prefix: 'Q',
      width: 72,
      height: 64,
      ports: _threePolePorts,
    ),
    SymbolDefinition(
      kind: DeviceKind.fuse,
      label: 'Pojistka',
      prefix: 'F',
      width: 28,
      height: 60,
      ports: [
        PortDefinition(id: 'in', label: '1', position: Vec2(0, -30)),
        PortDefinition(id: 'out', label: '2', position: Vec2(0, 30)),
      ],
    ),
    SymbolDefinition(
      kind: DeviceKind.disconnector,
      label: 'Odpojovač',
      prefix: 'Q',
      width: 40,
      height: 64,
      ports: [
        PortDefinition(id: 'in', label: '1', position: Vec2(0, -32)),
        PortDefinition(id: 'out', label: '2', position: Vec2(0, 32)),
      ],
    ),
    SymbolDefinition(
      kind: DeviceKind.threePoleDisconnector,
      label: 'Třípólový odpojovač',
      prefix: 'Q',
      width: 72,
      height: 64,
      ports: _threePolePorts,
    ),
    SymbolDefinition(
      kind: DeviceKind.contactor,
      label: 'Stykač',
      prefix: 'K',
      width: 46,
      height: 64,
      ports: [
        PortDefinition(id: 'in', label: '1', position: Vec2(0, -32)),
        PortDefinition(id: 'out', label: '2', position: Vec2(0, 32)),
      ],
    ),
    SymbolDefinition(
      kind: DeviceKind.motor,
      label: 'Motor',
      prefix: 'M',
      width: 66,
      height: 66,
      ports: [
        PortDefinition(id: 'in', label: 'U / V / W', position: Vec2(0, -33)),
        PortDefinition(id: 'pe', label: 'PE', position: Vec2(33, 0)),
      ],
    ),
    SymbolDefinition(
      kind: DeviceKind.transformer,
      label: 'Transformátor',
      prefix: 'T',
      width: 40,
      height: 80,
      ports: [
        PortDefinition(id: '1u1', label: '1U1', position: Vec2(-10, -40)),
        PortDefinition(id: '1u2', label: '1U2', position: Vec2(10, -40)),
        PortDefinition(id: '2u1', label: '2U1', position: Vec2(-10, 40)),
        PortDefinition(id: '2u2', label: '2U2', position: Vec2(10, 40)),
      ],
    ),
    SymbolDefinition(
      kind: DeviceKind.currentTransformer,
      label: 'Transformátor proudu',
      prefix: 'T',
      width: 40,
      height: 60,
      ports: [
        PortDefinition(id: 'p1', label: 'P1', position: Vec2(0, -30)),
        PortDefinition(id: 'p2', label: 'P2', position: Vec2(0, 30)),
        // Secondary leads face left, away from the designation text.
        PortDefinition(id: 's1', label: 'S1', position: Vec2(-20, -10)),
        PortDefinition(id: 's2', label: 'S2', position: Vec2(-20, 10)),
      ],
    ),
    SymbolDefinition(
      kind: DeviceKind.terminal,
      label: 'Svorka',
      prefix: 'X',
      width: 28,
      height: 32,
      ports: [
        PortDefinition(id: 'in', label: '1', position: Vec2(0, -16)),
        PortDefinition(id: 'out', label: '2', position: Vec2(0, 16)),
      ],
    ),
    SymbolDefinition(
      kind: DeviceKind.earth,
      label: 'Ochranné uzemnění',
      prefix: 'PE',
      width: 42,
      height: 36,
      ports: [PortDefinition(id: 'in', label: 'PE', position: Vec2(0, -18))],
    ),
    SymbolDefinition(
      kind: DeviceKind.contactNo,
      label: 'Spínací kontakt',
      prefix: 'S',
      width: 42,
      height: 60,
      ports: [
        PortDefinition(id: 'in', label: '13', position: Vec2(0, -30)),
        PortDefinition(id: 'out', label: '14', position: Vec2(0, 30)),
      ],
    ),
    SymbolDefinition(
      kind: DeviceKind.contactNc,
      label: 'Rozpínací kontakt',
      prefix: 'S',
      width: 42,
      height: 60,
      ports: [
        PortDefinition(id: 'in', label: '11', position: Vec2(0, -30)),
        PortDefinition(id: 'out', label: '12', position: Vec2(0, 30)),
      ],
    ),
    SymbolDefinition(
      kind: DeviceKind.pushbuttonNo,
      label: 'Spínací tlačítko',
      prefix: 'S',
      width: 42,
      height: 60,
      ports: [
        PortDefinition(id: 'in', label: '13', position: Vec2(0, -30)),
        PortDefinition(id: 'out', label: '14', position: Vec2(0, 30)),
      ],
    ),
    SymbolDefinition(
      kind: DeviceKind.coil,
      label: 'Cívka relé',
      prefix: 'K',
      width: 54,
      height: 54,
      ports: [
        PortDefinition(id: 'a1', label: 'A1', position: Vec2(0, -27)),
        PortDefinition(id: 'a2', label: 'A2', position: Vec2(0, 27)),
      ],
    ),
    SymbolDefinition(
      kind: DeviceKind.lamp,
      label: 'Signálka',
      prefix: 'H',
      width: 48,
      height: 56,
      ports: [
        PortDefinition(id: 'in', label: 'X1', position: Vec2(0, -28)),
        PortDefinition(id: 'out', label: 'X2', position: Vec2(0, 28)),
      ],
    ),
    SymbolDefinition(
      kind: DeviceKind.ammeter,
      label: 'Ampérmetr',
      prefix: 'P',
      width: 40,
      height: 60,
      ports: [
        PortDefinition(id: 'in', label: '1', position: Vec2(0, -30)),
        PortDefinition(id: 'out', label: '2', position: Vec2(0, 30)),
      ],
    ),
    SymbolDefinition(
      kind: DeviceKind.voltmeter,
      label: 'Voltmetr',
      prefix: 'P',
      width: 40,
      height: 60,
      ports: [
        PortDefinition(id: 'in', label: '1', position: Vec2(0, -30)),
        PortDefinition(id: 'out', label: '2', position: Vec2(0, 30)),
      ],
    ),
  ];

  static SymbolDefinition definitionFor(DeviceKind kind) =>
      definitions.firstWhere((definition) => definition.kind == kind);

  /// Bare and dash-prefixed labels reserve the same generated number.
  static String nextDesignation(
    Iterable<Component> components,
    DeviceKind kind,
  ) {
    final prefix = definitionFor(kind).prefix.toUpperCase();
    final used =
        components
            .map((device) => (device.designation ?? '').trim().toUpperCase())
            .toSet();
    var number = 1;
    while (used.contains('$prefix$number') ||
        used.contains('-$prefix$number')) {
      number++;
    }
    return '-$prefix$number';
  }

  static Vec2 worldPortPosition(Device device, String portId) {
    final port = geometryFor(device).portById(portId);
    if (port == null) {
      throw EcadException(
        'Unknown port "$portId" on ${device.id}.',
        code: 'invalid_port',
      );
    }
    return device.position + port.position.rotated(device.rotation);
  }
}

SymbolDefinition definitionFor(DeviceKind kind) =>
    SymbolCatalog.definitionFor(kind);
Vec2 worldPortPosition(Device device, String portId) =>
    SymbolCatalog.worldPortPosition(device, portId);

class SymbolGeometry {
  SymbolGeometry({
    required this.width,
    required this.height,
    required List<PortDefinition> ports,
  }) : ports = List.unmodifiable(ports);
  final double width;
  final double height;
  final List<PortDefinition> ports;
  PortDefinition? portById(String id) => findById(ports, id, (p) => p.id);
}

Vec2 sideDirection(PortSide side) => switch (side) {
  PortSide.left => const Vec2(-1, 0),
  PortSide.right => const Vec2(1, 0),
  PortSide.top => const Vec2(0, -1),
  PortSide.bottom => const Vec2(0, 1),
};

SymbolGeometry geometryFor(Device device) {
  switch (device.symbol) {
    case TerminalSymbolSpec(:final sides):
      final geometry = TerminalSymbolGeometry(sides: sides);
      return SymbolGeometry(
        width: geometry.portDistance * 2,
        height: geometry.portDistance * 2,
        ports: [
          for (final port in geometry.ports)
            PortDefinition(
              id: port.key,
              label: '',
              position: port.position,
              direction: port.normal,
            ),
        ],
      );
    case BuiltinSymbolSpec(:final kind):
      final definition = definitionFor(kind);
      return SymbolGeometry(
        width: definition.width,
        height: definition.height,
        ports: definition.ports,
      );
    case PortBlockSpec(:final width, :final height, :final ports):
      return SymbolGeometry(
        width: width,
        height: height,
        ports: [
          for (final port in ports)
            PortDefinition(
              id: port.id,
              label: '',
              direction: sideDirection(port.side),
              position: switch (port.side) {
                PortSide.left => Vec2(
                  -width / 2,
                  height * (port.fraction - .5),
                ),
                PortSide.right => Vec2(
                  width / 2,
                  height * (port.fraction - .5),
                ),
                PortSide.top => Vec2(width * (port.fraction - .5), -height / 2),
                PortSide.bottom => Vec2(
                  width * (port.fraction - .5),
                  height / 2,
                ),
              },
            ),
        ],
      );
  }
}

String? terminalIdFor(Device device, String portId) => switch (device.symbol) {
  TerminalSymbolSpec(:final sides, :final terminalId) =>
    sides.any((s) => s.name == portId) ? terminalId : null,
  BuiltinSymbolSpec(:final bindings) => bindings[portId],
  PortBlockSpec(:final ports) =>
    findById(ports, portId, (p) => p.id)?.terminalId,
};

({Component component, Device device}) createTerminalComponent({
  required String componentId,
  required String deviceId,
  required String stripId,
  required Vec2 position,
  String number = '1',
  Set<PortSide> sides = const {PortSide.top, PortSide.bottom},
  String? articleId,
  String description = '',
  OccurrenceMode mode = OccurrenceMode.wiring,
}) {
  final terminal = ComponentTerminal(
    id: newId('terminal'),
    designation: 'through',
  );
  final function = ComponentFunction(
    id: newId('function'),
    name: 'Průchozí svorka',
    terminalIds: [terminal.id],
  );
  return (
    component: Component(
      id: componentId,
      terminal: TerminalAssignment(stripId: stripId, number: number),
      articleId: articleId,
      description: description,
      electrical: ElectricalModel(terminals: [terminal], functions: [function]),
    ),
    device: Device(
      id: deviceId,
      componentId: componentId,
      functionId: function.id,
      position: position,
      mode: mode,
      symbol: TerminalSymbolSpec(terminalId: terminal.id, sides: sides),
    ),
  );
}

({Component component, Device device}) createBuiltinComponent({
  required String componentId,
  required String deviceId,
  required DeviceKind kind,
  required String designation,
  required Vec2 position,
  String? articleId,
  String description = '',
  OccurrenceMode mode = OccurrenceMode.wiring,
}) {
  if (kind == DeviceKind.earth)
    throw const EcadException(
      'Use a continuation marker for a logical earth.',
      code: 'logical_symbol',
    );
  final definition = definitionFor(kind);
  final terminals = [
    for (final port in definition.ports)
      ComponentTerminal(id: newId('terminal'), designation: port.label),
  ];
  final function = ComponentFunction(
    id: newId('function'),
    name: definition.label,
    terminalIds: terminals.map((t) => t.id).toList(),
  );
  return (
    component: Component(
      id: componentId,
      designation: designation,
      articleId: articleId,
      description: description,
      electrical: ElectricalModel(terminals: terminals, functions: [function]),
    ),
    device: Device(
      id: deviceId,
      componentId: componentId,
      functionId: function.id,
      position: position,
      mode: mode,
      symbol: BuiltinSymbolSpec(
        kind: kind,
        bindings: {
          for (var i = 0; i < terminals.length; i++)
            definition.ports[i].id: terminals[i].id,
        },
      ),
    ),
  );
}
