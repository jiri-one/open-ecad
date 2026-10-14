// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

Matcher errorCode(String code) =>
    isA<EcadException>().having((e) => e.code, 'code', code);

void main() {
  group('immutable model and serialization', () {
    test('demo round-trips the complete versioned document', () {
      final project = DemoProject.create();
      final data = jsonDecode(jsonEncode(project.toJson()));
      final restored = EcadProject.fromJson(data);
      expect(restored.toJson(), project.toJson());
      expect(restored.pages, hasLength(2));
      expect(
        validateProject(
          restored,
        ).where((d) => d.severity == DiagnosticSeverity.error),
        isEmpty,
      );
      expect(restored.description, contains('jednopólové'));
    });

    test('collection ownership cannot be mutated through a source list', () {
      final devices = <Device>[];
      final wires = <Wire>[];
      final points = <Vec2>[const Vec2(1, 2)];
      final sheet = Sheet(
        id: 'sheet',
        name: 'Page',
        number: '01',
        devices: devices,
        wires: wires,
      );
      final pages = <Sheet>[sheet];
      final project = EcadProject(id: 'project', name: 'Test', pages: pages);
      final wire = Wire(
        id: 'wire',
        from: const TerminalRef(deviceId: 'a', portId: 'in'),
        to: const TerminalRef(deviceId: 'b', portId: 'out'),
        waypoints: points,
      );
      pages.clear();
      devices.add(DemoProject.create().pages.first.devices.first);
      points.clear();
      expect(project.pages, hasLength(1));
      expect(sheet.devices, isEmpty);
      expect(wire.waypoints, hasLength(1));
      expect(project.pages.clear, throwsUnsupportedError);
      expect(sheet.wires.clear, throwsUnsupportedError);
      expect(wire.waypoints.clear, throwsUnsupportedError);
    });

    test('rejects unknown format versions and fields', () {
      final json = DemoProject.create().toJson();
      expect(
        () => EcadProject.fromJson({
          ...json,
          'formatVersion': EcadProject.formatVersion + 1,
        }),
        throwsA(errorCode('unsupported_format')),
      );
      expect(
        () => EcadProject.fromJson({...json, 'formatVersion': 1.0}),
        throwsA(errorCode('unsupported_format')),
      );
      expect(
        () => EcadProject.fromJson({...json, 'execute': 'untrusted'}),
        throwsA(errorCode('invalid_schema')),
      );
      expect(
        () => EcadProject.fromJson({...json, 'revision': '1'}),
        throwsA(errorCode('invalid_schema')),
      );
    });

    test('rejects unknown kinds and unsafe geometry at parse time', () {
      final device = DemoProject.create().pages.first.devices.first.toJson();
      expect(
        () => Device.fromJson({...device, 'kind': 'shell'}),
        throwsA(errorCode('invalid_schema')),
      );
      for (final x in [
        double.nan,
        double.infinity,
        ProjectLimits.maxCoordinate + 1,
      ]) {
        expect(
          () => Device.fromJson({
            ...device,
            'position': {'x': x, 'y': 0},
          }),
          throwsA(errorCode('invalid_geometry')),
        );
      }
      expect(
        () => Device.fromJson({
          ...device,
          'position': {'x': 1},
        }),
        throwsA(errorCode('invalid_geometry')),
      );
      expect(
        () => Device.fromJson({
          ...device,
          'position': {'x': 1, 'y': 2, 'z': 3},
        }),
        throwsA(errorCode('invalid_schema')),
      );
    });

    test(
      'rejects null optional fields rather than silently discarding data',
      () {
        final project = DemoProject.create().toJson();
        expect(
          () => EcadProject.fromJson({...project, 'description': null}),
          throwsA(errorCode('invalid_schema')),
        );
        final wire = DemoProject.create().pages.first.wires.first.toJson();
        expect(
          () => Wire.fromJson({...wire, 'waypoints': null}),
          throwsA(errorCode('limit_exceeded')),
        );
      },
    );

    test('rejects oversized collections and text', () {
      final project = DemoProject.create().toJson();
      expect(
        () => EcadProject.fromJson({
          ...project,
          'pages': List<Object?>.filled(ProjectLimits.maxPages + 1, null),
        }),
        throwsA(errorCode('limit_exceeded')),
      );
      expect(
        () => EcadProject.fromJson({...project, 'name': 'x' * 201}),
        throwsA(errorCode('invalid_schema')),
      );
      expect(
        () => EcadProject.fromJson({...project, 'name': 'bad\u0000name'}),
        throwsA(errorCode('invalid_schema')),
      );
    });

    test('IDs are opaque and distinct', () {
      final ids = List.generate(1000, (_) => newId('device'));
      expect(ids.toSet(), hasLength(1000));
      expect(ids.every((id) => id.startsWith('device_')), isTrue);
      expect(() => newId('../escape'), throwsA(isA<EcadException>()));
    });
  });

  group('atomic engine', () {
    late ProjectEngine engine;
    setUp(() => engine = ProjectEngine(DemoProject.create()));

    test('multiple commands commit as one revision and undo step', () {
      final before = engine.project;
      engine.execute(
        [
          const RenameProject('Changed'),
          MoveDevices('sheet_power', {'dev_motor': const Vec2(480, 550)}),
        ],
        label: 'Arrange motor',
        expectedRevision: 0,
      );
      expect(engine.project.name, 'Changed');
      expect(engine.project.revision, 1);
      expect(
        engine.project.pages.first.deviceById('dev_motor')!.position,
        const Vec2(480, 550),
      );
      expect(engine.undoLabel, 'Arrange motor');
      expect(engine.undo(), isTrue);
      expect(engine.project.toJson(), before.copyWith(revision: 2).toJson());
      expect(engine.canUndo, isFalse);
      expect(engine.canRedo, isTrue);
    });

    test('a command failure rolls back earlier commands and history', () {
      final before = engine.project;
      expect(
        () => engine.execute([
          const RenameProject('Must roll back'),
          MoveDevices('sheet_power', {'missing_device': const Vec2(10, 20)}),
        ]),
        throwsA(errorCode('missing_device')),
      );
      expect(identical(engine.project, before), isTrue);
      expect(engine.canUndo, isFalse);
      expect(engine.canRedo, isFalse);
    });

    test(
      'final graph failure is atomic and preserves an existing redo stack',
      () {
        engine.execute([const RenameProject('Changed')]);
        engine.undo();
        final before = engine.project;
        final original = before.pages.first.devices.first;
        expect(
          () => engine.execute([
            const RenameProject('Must roll back'),
            AddDevice('sheet_control', original),
          ]),
          throwsA(errorCode('duplicate_id')),
        );
        expect(identical(engine.project, before), isTrue);
        expect(engine.canRedo, isTrue);
        expect(engine.redo(), isTrue);
        expect(engine.project.name, 'Changed');
      },
    );

    test('rejects stale edits before touching the project', () {
      engine.execute([const RenameProject('Changed')], expectedRevision: 0);
      final before = engine.project;
      expect(
        () =>
            engine.execute([const RenameProject('Stale')], expectedRevision: 0),
        throwsA(errorCode('stale_revision')),
      );
      expect(identical(engine.project, before), isTrue);
      expect(engine.undo(), isTrue);
      expect(engine.project.revision, 2);
      expect(
        () => engine.execute([
          const RenameProject('Old proposal'),
        ], expectedRevision: 0),
        throwsA(errorCode('stale_revision')),
      );
    });

    test('undo and redo revisions increase monotonically', () {
      engine.execute([const RenameProject('A')]);
      engine.execute([const RenameProject('B')]);
      expect(engine.project.revision, 2);
      expect(engine.undo(), isTrue);
      expect(engine.project.name, 'A');
      expect(engine.project.revision, 3);
      expect(engine.undo(), isTrue);
      expect(engine.project.revision, 4);
      expect(engine.undo(), isFalse);
      expect(engine.redo(), isTrue);
      expect(engine.project.name, 'A');
      expect(engine.project.revision, 5);
      expect(engine.redo(), isTrue);
      expect(engine.project.name, 'B');
      expect(engine.project.revision, 6);
      expect(engine.redo(), isFalse);
    });

    test('a new branch discards redo but preserves undo', () {
      engine.execute([const RenameProject('A')]);
      engine.undo();
      engine.execute([const RenameProject('B')]);
      expect(engine.canRedo, isFalse);
      expect(engine.project.revision, 3);
      expect(engine.undo(), isTrue);
      expect(engine.project.name, DemoProject.create().name);
    });

    test('history cap discards only the oldest undo snapshots', () {
      final limited = ProjectEngine(DemoProject.create(), historyLimit: 2);
      for (final name in ['A', 'B', 'C']) {
        limited.execute([RenameProject(name)]);
      }
      expect(limited.undo(), isTrue);
      expect(limited.undo(), isTrue);
      expect(limited.project.name, 'A');
      expect(limited.undo(), isFalse);
      expect(limited.redo(), isTrue);
      expect(limited.redo(), isTrue);
      expect(limited.project.name, 'C');
    });

    test('revision overflow is rejected without consuming history', () {
      final limited = ProjectEngine(
        DemoProject.create().copyWith(revision: ProjectLimits.maxRevision - 1),
      );
      limited.execute([const RenameProject('Last change')]);
      expect(limited.undo, throwsA(errorCode('limit_exceeded')));
      expect(limited.canUndo, isTrue);
      expect(limited.project.name, 'Last change');
    });

    test(
      'deleting a device deletes its attached wires and undo restores all',
      () {
        final sheet = engine.project.pages.first;
        final attached =
            sheet.wires
                .where(
                  (w) =>
                      w.from.deviceId == 'dev_motor' ||
                      w.to.deviceId == 'dev_motor',
                )
                .map((w) => w.id)
                .toSet();
        engine.execute([
          DeleteDevices(sheet.id, {'dev_motor'}),
        ]);
        expect(engine.project.pages.first.deviceById('dev_motor'), isNull);
        expect(
          engine.project.pages.first.wires.any(
            (wire) => attached.contains(wire.id),
          ),
          isFalse,
        );
        expect(
          validateProject(
            engine.project,
          ).where((d) => d.severity == DiagnosticSeverity.error),
          isEmpty,
        );
        engine.undo();
        expect(engine.project.pages.first.toJson(), sheet.toJson());
      },
    );

    test('moving and rotating devices preserves terminal references', () {
      final original = engine.project.pages.first.deviceById('dev_breaker')!;
      final wires =
          engine.project.pages.first.wires.map((w) => w.toJson()).toList();
      final oldPort = worldPortPosition(original, 'in');
      engine.execute([
        UpdateDevice(
          'sheet_power',
          original.copyWith(position: const Vec2(500, 300), rotation: 90),
        ),
      ]);
      final updated = engine.project.pages.first.deviceById(original.id)!;
      expect(worldPortPosition(updated, 'in'), isNot(oldPort));
      expect(
        engine.project.pages.first.wires.map((w) => w.toJson()).toList(),
        wires,
      );
    });

    test('changing kind rejects obsolete connected port references', () {
      final motor = engine.project.pages.first.deviceById('dev_motor')!;
      expect(
        () => engine.execute([
          UpdateDevice('sheet_power', motor.copyWith(kind: DeviceKind.lamp)),
        ]),
        throwsA(errorCode('invalid_port')),
      );
      expect(
        engine.project.pages.first.deviceById(motor.id)!.kind,
        DeviceKind.motor,
      );
    });

    test(
      'batch may add a wire before its new device, if final graph is valid',
      () {
        const lamp = Device(
          id: 'new_lamp',
          kind: DeviceKind.lamp,
          designation: '-H2',
          position: Vec2(800, 300),
        );
        final wire = Wire(
          id: 'new_wire',
          from: const TerminalRef(deviceId: 'dev_supply', portId: 'out'),
          to: const TerminalRef(deviceId: 'new_lamp', portId: 'in'),
        );
        engine.execute([
          AddWire('sheet_power', wire),
          const AddDevice('sheet_power', lamp),
        ]);
        expect(engine.project.pages.first.deviceById('new_lamp'), isNotNull);
        expect(engine.project.revision, 1);
      },
    );

    test(
      'rejects invalid routes, invalid metadata, and empty transactions',
      () {
        final wire = engine.project.pages.first.wires.first.copyWith(
          id: 'unsafe_wire',
          waypoints: [const Vec2(double.nan, 0)],
        );
        expect(
          () => engine.execute([AddWire('sheet_power', wire)]),
          throwsA(errorCode('invalid_geometry')),
        );
        expect(
          () => engine.execute([const RenameProject(' ')]),
          throwsA(errorCode('invalid_metadata')),
        );
        expect(() => engine.execute([]), throwsA(errorCode('invalid_command')));
        expect(engine.project.revision, 0);
      },
    );
  });

  group('document and connectivity validation', () {
    test(
      'reports duplicate designations and unconnected ports as warnings',
      () {
        final demo = DemoProject.create();
        final duplicate = demo.pages.first.devices.first.copyWith(
          id: 'another_supply',
        );
        final engine = ProjectEngine(demo);
        engine.execute([AddDevice('sheet_power', duplicate)]);
        final diagnostics = validateProject(engine.project);
        expect(
          diagnostics.any(
            (d) =>
                d.code == 'duplicate_designation' &&
                d.severity == DiagnosticSeverity.warning,
          ),
          isTrue,
        );
        expect(
          diagnostics.any(
            (d) => d.code == 'unconnected_port' && d.deviceId == duplicate.id,
          ),
          isTrue,
        );
        expect(
          diagnostics.where((d) => d.severity == DiagnosticSeverity.error),
          isEmpty,
        );
      },
    );

    test('rejects cross-sheet endpoints even when device exists elsewhere', () {
      final engine = ProjectEngine(DemoProject.create());
      final wire = Wire(
        id: 'cross_sheet',
        from: const TerminalRef(deviceId: 'dev_supply', portId: 'out'),
        to: const TerminalRef(deviceId: 'dev_coil', portId: 'a1'),
      );
      expect(
        () => engine.execute([AddWire('sheet_power', wire)]),
        throwsA(errorCode('missing_device')),
      );
    });

    test('rejects a self endpoint and unknown port', () {
      final engine = ProjectEngine(DemoProject.create());
      const from = TerminalRef(deviceId: 'dev_supply', portId: 'out');
      expect(
        () => engine.execute([
          AddWire('sheet_power', Wire(id: 'self', from: from, to: from)),
        ]),
        throwsA(errorCode('same_endpoint')),
      );
      expect(
        () => engine.execute([
          AddWire(
            'sheet_power',
            Wire(
              id: 'bad_port',
              from: from,
              to: const TerminalRef(deviceId: 'dev_motor', portId: 'unmodeled'),
            ),
          ),
        ]),
        throwsA(errorCode('invalid_port')),
      );
    });

    test('engine rejects an initially corrupted document', () {
      final demo = DemoProject.create();
      expect(
        () => ProjectEngine(demo.copyWith(pages: [])),
        throwsA(errorCode('invalid_page_count')),
      );
      expect(
        () => ProjectEngine(demo.copyWith(id: '../bad')),
        throwsA(errorCode('invalid_id')),
      );
      expect(
        () => ProjectEngine(
          demo.copyWith(pages: [demo.pages.first, demo.pages.first]),
        ),
        throwsA(errorCode('duplicate_id')),
      );
    });

    test('duplicate connections are warnings regardless of direction', () {
      final engine = ProjectEngine(DemoProject.create());
      final first = engine.project.pages.first.wires.first;
      engine.execute([
        AddWire(
          'sheet_power',
          first.copyWith(id: 'reverse', from: first.to, to: first.from),
        ),
      ]);
      expect(
        validateProject(
          engine.project,
        ).any((d) => d.code == 'duplicate_connection'),
        isTrue,
      );
    });
  });

  group('symbol geometry', () {
    test('default terminal designation reserves names on every demo sheet', () {
      final devices = DemoProject.create().pages.expand(
        (sheet) => sheet.devices,
      );
      expect(
        SymbolCatalog.nextDesignation(devices, DeviceKind.terminal),
        '-X3',
      );
    });

    test(
      'default names reserve bare and dash-prefixed labels case-insensitively',
      () {
        final sample = DemoProject.create().pages.first.devices.first;
        final devices = [
          sample.copyWith(id: 'bare', designation: 'x1'),
          sample.copyWith(id: 'prefixed', designation: ' -X2 '),
          sample.copyWith(id: 'custom', designation: 'customer-label'),
        ];
        expect(
          SymbolCatalog.nextDesignation(devices, DeviceKind.terminal),
          '-X3',
        );
        expect(devices.map((device) => device.designation), [
          'x1',
          ' -X2 ',
          'customer-label',
        ]);
      },
    );

    test('contactor and coil defaults share their K prefix across sheets', () {
      final devices =
          DemoProject.create().pages.expand((sheet) => sheet.devices).toList();
      expect(SymbolCatalog.nextDesignation(devices, DeviceKind.coil), '-K3');
      devices.add(
        const Device(
          id: 'provisional',
          kind: DeviceKind.coil,
          designation: 'k3',
          position: Vec2.zero,
        ),
      );
      expect(
        SymbolCatalog.nextDesignation(devices, DeviceKind.contactor),
        '-K4',
      );
    });

    test('all kinds have bounded, unique, nonempty port definitions', () {
      expect(
        SymbolCatalog.definitions.map((d) => d.kind).toSet(),
        DeviceKind.values.toSet(),
      );
      for (final definition in SymbolCatalog.definitions) {
        expect(definition.ports, isNotEmpty);
        expect(
          definition.ports.map((p) => p.id).toSet(),
          hasLength(definition.ports.length),
        );
        for (final port in definition.ports) {
          expect(
            port.position.x.abs(),
            lessThanOrEqualTo(definition.width / 2),
          );
          expect(
            port.position.y.abs(),
            lessThanOrEqualTo(definition.height / 2),
          );
        }
      }
    });

    test('port rotates around device center clockwise on screen', () {
      const device = Device(
        id: 'test',
        kind: DeviceKind.breaker,
        designation: 'Q',
        position: Vec2(100, 200),
        rotation: 90,
      );
      final position = worldPortPosition(device, 'in');
      expect(position.x, closeTo(132, 1e-9));
      expect(position.y, closeTo(200, 1e-9));
      final flipped = worldPortPosition(device.copyWith(rotation: 180), 'in');
      expect(flipped.x, closeTo(100, 1e-9));
      expect(flipped.y, closeTo(232, 1e-9));
      expect(
        () => worldPortPosition(device, 'missing'),
        throwsA(errorCode('invalid_port')),
      );
    });

    test('vector operations and grid snapping preserve geometry', () {
      expect(const Vec2(3, 4).length, 5);
      expect(const Vec2(3, 4).distanceTo(Vec2.zero), 5);
      expect(const Vec2(3, 4) + const Vec2(1, 2), const Vec2(4, 6));
      expect(const Vec2(3, 4) * 2, const Vec2(6, 8));
      expect(const Vec2(19, 31).snapped(10), const Vec2(20, 30));
      expect(() => Vec2.zero.snapped(0), throwsA(isA<EcadException>()));
    });
  });

  group('agent command codec', () {
    test('all command types round-trip without losing information', () {
      final demo = DemoProject.create();
      final commands = <EcadCommand>[
        AddDevice('sheet_power', demo.pages.first.devices.first),
        MoveDevices('sheet_power', {'dev_motor': const Vec2(10, 20)}),
        UpdateDevice('sheet_power', demo.pages.first.devices.first),
        DeleteDevices('sheet_power', {'dev_motor'}),
        AddWire('sheet_power', demo.pages.first.wires.first),
        const DeleteWire('sheet_power', 'wire_p1'),
        AddSheet(demo.pages.last),
        const RenameSheet('sheet_power', 'Power'),
        const RenameProject('New name'),
      ];
      final data = jsonDecode(
        jsonEncode(commands.map((c) => c.toJson()).toList()),
      );
      expect(
        decodeCommands(data).map((c) => c.toJson()).toList(),
        commands.map((c) => c.toJson()).toList(),
      );
    });

    test(
      'strict decoding rejects unknown fields and unsupported operations',
      () {
        expect(
          () => EcadCommand.fromJson({
            'type': 'renameProject',
            'name': 'Test',
            'shell': 'ls',
          }),
          throwsA(errorCode('invalid_schema')),
        );
        expect(
          () => EcadCommand.fromJson({'type': 'execute', 'command': 'ls'}),
          throwsA(errorCode('invalid_command')),
        );
        expect(() => decodeCommands([]), throwsA(errorCode('limit_exceeded')));
        expect(
          () => EcadCommand.fromJson({
            'type': 'deleteDevices',
            'sheetId': 'sheet_power',
            'ids': ['a', 'a'],
          }),
          throwsA(errorCode('invalid_command')),
        );
        expect(
          () => EcadCommand.fromJson({
            'type': 'moveDevices',
            'sheetId': 'sheet_power',
            'positions': <String, Object?>{},
          }),
          throwsA(errorCode('limit_exceeded')),
        );
      },
    );

    test('move map keys obey the same string limits as other device IDs', () {
      for (final id in ['x' * 129, 'bad\u0000id']) {
        expect(
          () => EcadCommand.fromJson({
            'type': 'moveDevices',
            'sheetId': 'sheet_power',
            'positions': {
              id: {'x': 10, 'y': 20},
            },
          }),
          throwsA(errorCode('invalid_schema')),
        );
      }
    });

    test('command maps and sets are copied before they can change', () {
      final positions = <String, Vec2>{'a': Vec2.zero};
      final ids = <String>{'a'};
      final move = MoveDevices('s', positions);
      final delete = DeleteDevices('s', ids);
      positions.clear();
      ids.clear();
      expect(move.positions, hasLength(1));
      expect(delete.ids, hasLength(1));
      expect(move.positions.clear, throwsUnsupportedError);
      expect(delete.ids.clear, throwsUnsupportedError);
    });
  });
}
