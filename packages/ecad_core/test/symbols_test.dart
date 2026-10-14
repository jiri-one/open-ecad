// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

List<Device> _oneOfEach({String suffix = '', double rotation = 0}) => [
  for (final (index, kind) in DeviceKind.values.indexed)
    Device(
      id: 'device_${kind.name}$suffix',
      kind: kind,
      designation: '-${definitionFor(kind).prefix}${index + 1}$suffix',
      position: Vec2(100.0 + index % 5 * 200, 120.0 + index ~/ 5 * 150),
      rotation: rotation,
    ),
];

Matcher _near(double x, double y) => isA<Vec2>()
    .having((p) => p.x, 'x', closeTo(x, 1e-9))
    .having((p) => p.y, 'y', closeTo(y, 1e-9));

void main() {
  test('saved files keep the established kind names', () {
    // Projects store these names; renaming one would orphan saved devices.
    expect(DeviceKind.values.map((kind) => kind.name).toSet(), {
      'supply',
      'breaker',
      'threePoleBreaker',
      'fuse',
      'disconnector',
      'threePoleDisconnector',
      'contactor',
      'motor',
      'transformer',
      'currentTransformer',
      'terminal',
      'earth',
      'contactNo',
      'contactNc',
      'pushbuttonNo',
      'coil',
      'lamp',
      'ammeter',
      'voltmeter',
    });
  });

  test('every kind round-trips through files, commands and the engine', () {
    final project = EcadProject(
      id: 'library_project',
      name: 'Knihovna symbolů',
      pages: [
        Sheet(
          id: 'library_sheet',
          name: 'Všechny symboly',
          number: '1',
          devices: [..._oneOfEach(), ..._oneOfEach(suffix: 'r', rotation: 270)],
        ),
      ],
    );
    final restored = EcadProject.fromJson(
      jsonDecode(jsonEncode(project.toJson())),
    );
    expect(restored.toJson(), project.toJson());
    expect(
      restored.pages.single.devices.map((device) => device.kind).toSet(),
      DeviceKind.values.toSet(),
    );

    final engine = ProjectEngine(restored);
    final commands = decodeCommands(
      jsonDecode(
        jsonEncode([
          for (final device in _oneOfEach(suffix: 'c'))
            AddDevice('library_sheet', device).toJson(),
        ]),
      ),
    );
    engine.execute(commands, expectedRevision: 0);
    expect(
      engine.project.pages.single.devices,
      hasLength(DeviceKind.values.length * 3),
    );
    expect(
      validateProject(
        engine.project,
      ).where((d) => d.severity == DiagnosticSeverity.error),
      isEmpty,
    );
  });

  test('terminals sit on the symbol outline and on grid lines', () {
    for (final definition in SymbolCatalog.definitions) {
      final name = definition.kind.name;
      expect(definition.label.trim(), isNotEmpty, reason: name);
      expect(
        definition.ports.map((port) => port.label).toSet(),
        hasLength(definition.ports.length),
        reason: name,
      );
      for (final port in definition.ports) {
        final position = port.position;
        final onTopOrBottom = position.y.abs() == definition.height / 2;
        final onSide = position.x.abs() == definition.width / 2;
        expect(onTopOrBottom || onSide, isTrue, reason: '$name:${port.id}');
        // Devices snap to a 10-unit grid; this keeps wires between them
        // straight instead of producing a dogleg next to the terminal.
        if (onTopOrBottom) expect(position.x % 10, 0, reason: '$name:x');
        if (onSide) expect(position.y % 10, 0, reason: '$name:y');
      }
    }
  });

  test('three-pole devices wire each pole independently', () {
    for (final kind in [
      DeviceKind.threePoleBreaker,
      DeviceKind.threePoleDisconnector,
    ]) {
      final definition = definitionFor(kind);
      expect(definition.ports.map((port) => port.id), [
        '1',
        '2',
        '3',
        '4',
        '5',
        '6',
      ]);
      final columns = <double>{};
      for (final (line, load) in [('1', '2'), ('3', '4'), ('5', '6')]) {
        final top = definition.portById(line)!.position;
        final bottom = definition.portById(load)!.position;
        expect(bottom.x, top.x, reason: '${kind.name} $line-$load');
        expect(top.y, -definition.height / 2);
        expect(bottom.y, definition.height / 2);
        columns.add(top.x);
      }
      expect(columns, hasLength(3), reason: kind.name);
    }

    const breaker = Device(
      id: 'q1',
      kind: DeviceKind.threePoleBreaker,
      designation: '-Q1',
      position: Vec2(200, 200),
    );
    const fuse = Device(
      id: 'f1',
      kind: DeviceKind.fuse,
      designation: '-F1',
      position: Vec2(200, 320),
    );
    expect(
      worldPortPosition(breaker, '4').x,
      worldPortPosition(fuse, 'in').x,
      reason: 'The middle pole lines up with a fuse on the same grid column.',
    );
    final project = EcadProject(
      id: 'pole_project',
      name: 'Póly',
      pages: [
        Sheet(
          id: 'pole_sheet',
          name: 'Silový obvod',
          number: '1',
          devices: const [breaker, fuse],
          wires: [
            Wire(
              id: 'pole_wire',
              from: const TerminalRef(deviceId: 'q1', portId: '4'),
              to: const TerminalRef(deviceId: 'f1', portId: 'in'),
            ),
          ],
        ),
      ],
    );
    final open =
        validateProject(project)
            .where((d) => d.code == 'unconnected_port' && d.deviceId == 'q1')
            .map((d) => d.message)
            .toList();
    expect(open, hasLength(5));
    expect(open.where((message) => message.contains('terminal 4 ')), isEmpty);
  });

  test('multi-terminal ports rotate with their device', () {
    const transformer = Device(
      id: 't1',
      kind: DeviceKind.transformer,
      designation: '-T1',
      position: Vec2(300, 200),
      rotation: 90,
    );
    expect(worldPortPosition(transformer, '1u1'), _near(340, 190));
    expect(worldPortPosition(transformer, '2u2'), _near(260, 210));
    final currentTransformer = transformer.copyWith(
      kind: DeviceKind.currentTransformer,
      rotation: 180,
    );
    expect(worldPortPosition(currentTransformer, 's1'), _near(320, 210));
    expect(worldPortPosition(currentTransformer, 'p2'), _near(300, 170));
    expect(
      () => worldPortPosition(currentTransformer, '1u1'),
      throwsA(isA<EcadException>()),
    );
  });

  test('new kinds continue their letter-code sequences', () {
    final devices = <Device>[];
    String place(DeviceKind kind) {
      final designation = SymbolCatalog.nextDesignation(devices, kind);
      devices.add(
        Device(
          id: 'device_${devices.length}',
          kind: kind,
          designation: designation,
          position: Vec2.zero,
        ),
      );
      return designation;
    }

    expect(place(DeviceKind.breaker), '-Q1');
    expect(place(DeviceKind.threePoleBreaker), '-Q2');
    expect(place(DeviceKind.disconnector), '-Q3');
    expect(place(DeviceKind.threePoleDisconnector), '-Q4');
    expect(place(DeviceKind.fuse), '-F1');
    expect(place(DeviceKind.transformer), '-T1');
    expect(place(DeviceKind.currentTransformer), '-T2');
    expect(place(DeviceKind.ammeter), '-P1');
    expect(place(DeviceKind.voltmeter), '-P2');
    expect(place(DeviceKind.earth), '-PE1');
    expect(place(DeviceKind.contactNo), '-S1');
    expect(place(DeviceKind.contactNc), '-S2');
    expect(place(DeviceKind.pushbuttonNo), '-S3');
  });
}
