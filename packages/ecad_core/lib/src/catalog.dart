// SPDX-License-Identifier: GPL-3.0-or-later
import 'model.dart';

class PortDefinition {
  const PortDefinition({
    required this.id,
    required this.label,
    required this.position,
  });
  final String id;
  final String label;

  /// Offset from the symbol's center, before rotation.
  final Vec2 position;
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

  /// Generates a default designation without rewriting existing labels.
  /// Pass devices from every sheet, including uncommitted batch additions.
  /// Bare and dash-prefixed labels reserve the same generated number, and
  /// kinds sharing a prefix (such as contactors and coils) share the sequence.
  static String nextDesignation(Iterable<Device> devices, DeviceKind kind) {
    final prefix = definitionFor(kind).prefix.toUpperCase();
    final used =
        devices
            .map((device) => device.designation.trim().toUpperCase())
            .toSet();
    var number = 1;
    while (used.contains('$prefix$number') ||
        used.contains('-$prefix$number')) {
      number++;
    }
    return '-$prefix$number';
  }

  static Vec2 worldPortPosition(Device device, String portId) {
    final port = definitionFor(device.kind).portById(portId);
    if (port == null) {
      throw EcadException(
        'Unknown port "$portId" on ${device.kind.name}.',
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
