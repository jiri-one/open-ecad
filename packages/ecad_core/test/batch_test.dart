// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

Matcher _error(String code) =>
    isA<EcadException>().having((error) => error.code, 'code', code);

Device _breaker(int index) => Device(
  id: 'q$index',
  kind: DeviceKind.breaker,
  designation: '-Q$index',
  position: Vec2(100.0 + index % 20 * 80, 100.0 + index ~/ 20 * 120),
);

/// Pairs of breakers joined by a wire with a manual bend beside the pair.
EcadProject _pairs(int count) {
  final devices = List.generate(count, _breaker);
  return EcadProject(
    id: 'batch_project',
    name: 'Dávky',
    pages: [
      Sheet(
        id: 'sheet',
        name: 'Rozváděč',
        number: '1',
        devices: devices,
        wires: [
          for (var i = 0; i + 1 < count; i += 2)
            Wire(
              id: 'wire_$i',
              from: TerminalRef(deviceId: 'q$i', portId: 'out'),
              to: TerminalRef(deviceId: 'q${i + 1}', portId: 'in'),
              waypoints: [devices[i].position + const Vec2(0, 50)],
            ),
        ],
      ),
    ],
  );
}

DrawingElement _mark(String id, double x) => DrawingElement(
  id: id,
  kind: DrawingKind.path,
  position: Vec2(x, 40),
  width: 20,
  height: 0,
  stroke: '#204060',
  path: [
    PathSegment(verb: PathVerb.moveTo, points: [Vec2.zero]),
    PathSegment(verb: PathVerb.lineTo, points: [const Vec2(20, 0)]),
  ],
);

Map<String, Device> _byId(Iterable<Device> devices) => {
  for (final device in devices) device.id: device,
};

Map<String, Object?> _withoutRevision(EcadProject project) =>
    project.toJson()..remove('revision');

void main() {
  group('bulk device updates', () {
    test('rotate more than 1000 devices in one revision and undo step', () {
      final engine = ProjectEngine(_pairs(1200));
      final before = engine.project;
      final rotated = [
        for (final device in before.pages.single.devices)
          device.copyWith(rotation: 90),
      ];
      final command = UpdateDevices('sheet', rotated);
      rotated.clear();
      expect(command.devices, hasLength(1200));
      expect(command.devices.clear, throwsUnsupportedError);

      engine.execute([command], label: 'Otočit výběr', expectedRevision: 0);
      final sheet = engine.project.pages.single;
      expect(engine.project.revision, 1);
      expect(sheet.devices.every((device) => device.rotation == 90), isTrue);
      expect(sheet.devices.map((device) => device.id), [
        for (final device in before.pages.single.devices) device.id,
      ]);
      // Both ends turn together, as one MoveDevices moves several devices.
      final old = _byId(before.pages.single.devices);
      final now = _byId(sheet.devices);
      for (final (index, wire) in before.pages.single.wires.indexed) {
        expect(
          sheet.wires[index].toJson(),
          WireRouter.follow(wire, old, now).toJson(),
        );
      }
      expect(engine.undoLabel, 'Otočit výběr');
      expect(engine.undo(), isTrue);
      expect(engine.canUndo, isFalse);
      expect(_withoutRevision(engine.project), _withoutRevision(before));
      expect(engine.redo(), isTrue);
      expect(engine.project.pages.single.toJson(), sheet.toJson());
    });

    test('moves bends exactly like MoveDevices with the same positions', () {
      final project = _pairs(40);
      final targets = {
        for (final device in project.pages.single.devices.take(25))
          device.id: device.position + const Vec2(30, -20),
      };
      final moved = ProjectEngine(project)
        ..execute([MoveDevices('sheet', targets)]);
      final updated = ProjectEngine(project)..execute([
        UpdateDevices('sheet', [
          for (final device in project.pages.single.devices)
            if (targets[device.id] case final target?)
              device.copyWith(position: target),
        ]),
      ]);
      expect(updated.project.toJson(), moved.project.toJson());
      expect(
        updated.project.pages.single.wires.map((wire) => wire.toJson()),
        isNot(project.pages.single.wires.map((wire) => wire.toJson())),
      );
    });

    test('rejects empty, repeated and unknown devices atomically', () {
      final engine = ProjectEngine(_pairs(4));
      engine.execute([const RenameProject('Změna')]);
      engine.undo();
      final before = engine.project;
      final first = before.pages.single.devices.first;
      for (final (command, code) in <(EcadCommand, String)>[
        (UpdateDevices('sheet', const []), 'invalid_command'),
        (UpdateDevices('sheet', [first, first]), 'invalid_command'),
        (
          UpdateDevices('sheet', [first, first.copyWith(id: 'missing')]),
          'missing_device',
        ),
        (UpdateDevices('missing_sheet', [first]), 'missing_sheet'),
        // The breaker's wired ports do not exist on a coil.
        (
          UpdateDevices('sheet', [first.copyWith(kind: DeviceKind.coil)]),
          'invalid_port',
        ),
      ]) {
        expect(
          () => engine.execute([const RenameProject('Nepoužito'), command]),
          throwsA(_error(code)),
        );
        expect(identical(engine.project, before), isTrue);
        expect(engine.canUndo, isFalse);
        expect(engine.canRedo, isTrue);
      }
    });

    test('codec round-trips and rejects malformed device lists', () {
      final devices = [_breaker(1), _breaker(2).copyWith(rotation: 270)];
      final command = UpdateDevices('sheet', devices);
      expect(command.toJson()['type'], 'updateDevices');
      final decoded = decodeCommands(
        jsonDecode(jsonEncode([command.toJson()])),
      );
      expect(decoded.single, isA<UpdateDevices>());
      expect(decoded.single.toJson(), command.toJson());

      final device = devices.first.toJson();
      for (final (invalid, code) in <(Map<String, Object?>, String)>[
        (
          {'type': 'updateDevices', 'sheetId': 's', 'devices': []},
          'invalid_command',
        ),
        (
          {
            'type': 'updateDevices',
            'sheetId': 's',
            'devices': [device, device],
          },
          'invalid_command',
        ),
        ({'type': 'updateDevices', 'sheetId': 's'}, 'limit_exceeded'),
        (
          {
            'type': 'updateDevices',
            'sheetId': 's',
            'devices': List.filled(ProjectLimits.maxDevices + 1, device),
          },
          'limit_exceeded',
        ),
        (
          {
            'type': 'updateDevices',
            'sheetId': 's',
            'devices': [device],
            'device': device,
          },
          'invalid_schema',
        ),
      ]) {
        expect(
          () => EcadCommand.fromJson(invalid),
          throwsA(_error(code)),
          reason: invalid.keys.join(', '),
        );
      }
    });
  });

  group('command batches', () {
    test('commit the same document as their commands one at a time', () {
      final random = math.Random(20261014);
      for (var trial = 0; trial < 12; trial++) {
        final start = _pairs(30).copyWith(
          pages: [
            _pairs(30).pages.single.copyWith(
              graphics: [for (var i = 0; i < 12; i++) _mark('mark_$i', i * 30)],
            ),
          ],
        );
        final stepwise = ProjectEngine(start, historyLimit: 1000);
        final commands = <EcadCommand>[];
        var serial = 0;
        while (commands.length < 150) {
          final command = _randomCommand(
            random,
            stepwise.project.pages.single,
            () => serial++,
          );
          try {
            stepwise.execute([command]);
            commands.add(command);
          } on EcadException {
            // Only edits that are valid on their own form the batch.
          }
        }
        final batch = ProjectEngine(start)
          ..execute(commands, label: 'Dávka', expectedRevision: 0);
        expect(
          _withoutRevision(batch.project),
          _withoutRevision(stepwise.project),
          reason: 'trial $trial',
        );
        expect(batch.project.revision, 1);
        expect(batch.undo(), isTrue);
        expect(_withoutRevision(batch.project), _withoutRevision(start));
      }
    });

    test('later commands see earlier ones in the same batch', () {
      final engine = ProjectEngine(_pairs(4));
      final sheet = engine.project.pages.single;
      final replacement = _breaker(0).copyWith(designation: '-Q100');
      engine.execute([
        AddGraphics('sheet', [_mark('mark', 10)]),
        MoveGraphics('sheet', {'mark': const Vec2(70, 80)}),
        UpdateGraphic('sheet', _mark('mark', 0).copyWith(strokeWidth: 3)),
        DeleteGraphics('sheet', {'mark'}),
        AddGraphics('sheet', [_mark('mark', 500)]),
        DeleteDevices('sheet', {'q0'}),
        AddDevice('sheet', replacement),
        AddWire('sheet', sheet.wires.first),
        MoveDevices('sheet', {'q0': const Vec2(900, 900)}),
        const RenameSheet('sheet', 'První název'),
        const SetSheetType('sheet', SheetType.form),
        const RenameSheet('sheet', 'Konečný název'),
      ]);
      final after = engine.project.pages.single;
      expect((after.name, after.type), ('Konečný název', SheetType.form));
      expect(after.graphics.single.position, const Vec2(500, 40));
      expect(after.graphics.single.strokeWidth, 1);
      expect(after.devices.last.designation, '-Q100');
      expect(after.devices.last.position, const Vec2(900, 900));
      expect(after.devices.map((device) => device.id), [
        'q1',
        'q2',
        'q3',
        'q0',
      ]);
      // The re-added wire is attached to the new device and followed it.
      expect(after.wires.map((wire) => wire.id), ['wire_2', 'wire_0']);
      final q1 = sheet.deviceById('q1')!;
      final followed = WireRouter.follow(
        sheet.wires.first,
        {'q0': replacement, 'q1': q1},
        {'q0': after.deviceById('q0')!, 'q1': q1},
      );
      expect(followed.waypoints, isNot(sheet.wires.first.waypoints));
      expect(after.wires.last.toJson(), followed.toJson());
    });

    test('repeated IDs from an added sheet or wire are all deleted', () {
      final engine = ProjectEngine(_pairs(4));
      final wire = engine.project.pages.single.wires.first;
      // A copy under an existing ID is removed together with the original,
      // also when an earlier command already looked the wires up.
      for (final lookup in [false, true]) {
        final before = engine.project;
        engine.execute([
          if (lookup) const DeleteWire('sheet', 'wire_2'),
          AddWire('sheet', wire.copyWith(waypoints: const [])),
          const DeleteWire('sheet', 'wire_0'),
        ]);
        expect(engine.project.pages.single.wires.map((wire) => wire.id), [
          if (!lookup) 'wire_2',
        ]);
        engine.undo();
        expect(_withoutRevision(engine.project), _withoutRevision(before));
      }
      // Commands address the first sheet when an added one repeats its ID.
      expect(
        () => engine.execute([
          AddSheet(Sheet(id: 'sheet', name: 'Kopie', number: '9')),
          AddDevice('sheet', _breaker(0)),
        ]),
        throwsA(
          isA<EcadException>().having(
            (error) => error.message,
            'message',
            'Device q0 already exists.',
          ),
        ),
      );

      final twin = _breaker(7);
      Sheet repeated() => Sheet(
        id: 'sheet_added',
        name: 'Přidaný',
        number: '2',
        devices: [twin, twin.copyWith(position: const Vec2(600, 600))],
        wires: [
          Wire(
            id: 'wire_twin',
            from: const TerminalRef(deviceId: 'q7', portId: 'out'),
            to: const TerminalRef(deviceId: 'q8', portId: 'in'),
            waypoints: const [Vec2(700, 300)],
          ),
        ],
        graphics: [_mark('mark_twin', 0), _mark('mark_twin', 50)],
      );
      expect(
        () => engine.execute([AddSheet(repeated())]),
        throwsA(_error('duplicate_id')),
      );
      engine.execute([
        AddSheet(repeated()),
        AddDevice('sheet_added', _breaker(8)),
        MoveDevices('sheet_added', {'q7': const Vec2(300, 300)}),
        MoveGraphics('sheet_added', {'mark_twin': const Vec2(5, 5)}),
        DeleteDevices('sheet_added', {'q7'}),
        DeleteGraphics('sheet_added', {'mark_twin'}),
      ]);
      final added = engine.project.pages.last;
      expect(added.devices.map((device) => device.id), ['q8']);
      expect(added.wires, isEmpty);
      expect(added.graphics, isEmpty);
    });

    test('removals free capacity for additions in the same batch', () {
      final engine = ProjectEngine(
        EcadProject(
          id: 'full_project',
          name: 'Plný list',
          pages: [
            Sheet(
              id: 'sheet',
              name: 'Plný',
              number: '1',
              graphics: List.generate(
                ProjectLimits.maxGraphics,
                (index) => _mark('g$index', 0),
              ),
            ),
          ],
        ),
      );
      expect(
        () => engine.execute([
          AddGraphics('sheet', [_mark('extra', 0)]),
        ]),
        throwsA(_error('invalid_command')),
      );
      engine.execute([
        DeleteGraphics('sheet', {'g0', 'g1'}),
        AddGraphics('sheet', [_mark('extra', 0), _mark('more', 0)]),
      ]);
      final graphics = engine.project.pages.single.graphics;
      expect(graphics, hasLength(ProjectLimits.maxGraphics));
      expect(graphics.first.id, 'g2');
      expect(graphics.last.id, 'more');
    });

    test('duplicate and missing IDs are named in command order', () {
      final engine = ProjectEngine(_pairs(2));
      expect(
        () => engine.execute([
          AddGraphics('sheet', [_mark('a', 0), _mark('b', 0), _mark('a', 5)]),
        ]),
        throwsA(
          isA<EcadException>()
              .having((error) => error.code, 'code', 'duplicate_id')
              .having(
                (error) => error.message,
                'message',
                'Drawing element a already exists.',
              ),
        ),
      );
      expect(
        () => engine.execute([
          MoveDevices('sheet', {
            for (final id in [
              'q0',
              'x1',
              'x2',
              'q1',
              'x3',
              'x4',
              'x5',
              'x6',
              'x7',
            ])
              id: Vec2.zero,
          }),
        ]),
        throwsA(
          isA<EcadException>().having(
            (error) => error.message,
            'message',
            'Unknown devices: x1, x2, x3, x4, x5, x6.',
          ),
        ),
      );
    });
  });
}

/// An edit of [sheet]; it may be invalid and is then left out by the caller.
EcadCommand _randomCommand(
  math.Random random,
  Sheet sheet,
  int Function() serial,
) {
  T pick<T>(List<T> items) => items[random.nextInt(items.length)];
  Vec2 point() =>
      Vec2(random.nextInt(150) * 10.0 + 60, random.nextInt(100) * 10.0 + 60);
  final devices = sheet.devices;
  final graphics = sheet.graphics;
  switch (random.nextInt(13)) {
    case 0 when devices.isNotEmpty:
      return MoveDevices(sheet.id, {
        for (var i = 0; i < 1 + random.nextInt(3); i++)
          pick(devices).id: point(),
      });
    case 1 when devices.isNotEmpty:
      final device = pick(devices);
      return UpdateDevice(
        sheet.id,
        device.copyWith(rotation: (device.rotation + 90) % 360),
      );
    case 2 when devices.isNotEmpty:
      final chosen = {for (var i = 0; i < 3; i++) pick(devices)};
      return UpdateDevices(sheet.id, [
        for (final device in chosen)
          device.copyWith(
            rotation: (device.rotation + 270) % 360,
            position: point(),
          ),
      ]);
    case 3:
      final kind = pick(DeviceKind.values);
      // A deleted ID may come back as a different device.
      final id = random.nextBool() ? 'q${random.nextInt(40)}' : 'n${serial()}';
      return AddDevice(
        sheet.id,
        Device(id: id, kind: kind, designation: '-N$id', position: point()),
      );
    case 4 when devices.isNotEmpty:
      return DeleteDevices(sheet.id, {pick(devices).id});
    case 5 when devices.length > 1:
      final a = pick(devices);
      final b = pick(devices);
      return AddWire(
        sheet.id,
        Wire(
          id: 'w${serial()}',
          from: TerminalRef(
            deviceId: a.id,
            portId: pick(definitionFor(a.kind).ports).id,
          ),
          to: TerminalRef(
            deviceId: b.id,
            portId: pick(definitionFor(b.kind).ports).id,
          ),
          waypoints: [
            if (random.nextBool()) point(),
            if (random.nextBool()) point(),
          ],
        ),
      );
    case 6 when sheet.wires.isNotEmpty:
      return DeleteWire(sheet.id, pick(sheet.wires).id);
    case 7:
      return AddGraphics(sheet.id, [
        for (var i = 0; i < 1 + random.nextInt(3); i++)
          _mark('m${serial()}', point().x),
      ]);
    case 8 when graphics.isNotEmpty:
      return UpdateGraphic(
        sheet.id,
        pick(graphics).copyWith(rotation: random.nextInt(4) * 90.0),
      );
    case 9 when graphics.isNotEmpty:
      final chosen = {for (var i = 0; i < 3; i++) pick(graphics)};
      return UpdateGraphics(sheet.id, [
        for (final graphic in chosen) graphic.copyWith(opacity: 0.5),
      ]);
    case 10 when graphics.isNotEmpty:
      return MoveGraphics(sheet.id, {pick(graphics).id: point()});
    case 11 when graphics.isNotEmpty:
      return DeleteGraphics(sheet.id, {pick(graphics).id});
    default:
      return random.nextBool()
          ? RenameSheet(sheet.id, 'List ${serial()}')
          : SetSheetType(sheet.id, pick(SheetType.values));
  }
}
