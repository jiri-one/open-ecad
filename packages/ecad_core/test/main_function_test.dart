// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

EcadProject _project() {
  final seed = createBuiltinComponent(
    componentId: 'supply',
    deviceId: 'main',
    kind: DeviceKind.supply,
    designation: '-P1',
    position: const Vec2(300, 200),
  );
  return EcadProject(
    id: 'project',
    name: 'Synthetic functions',
    components: [seed.component],
    pages: [
      Sheet(id: 'first', number: '1', name: 'First', devices: [seed.device]),
      Sheet(
        id: 'second',
        number: '2',
        name: 'Second',
        devices: [
          seed.device.copyWith(
            id: 'aux',
            position: const Vec2(800, 500),
            mode: OccurrenceMode.reference,
          ),
          seed.device.copyWith(
            id: 'repeat',
            position: const Vec2(400, 350),
            mode: OccurrenceMode.reference,
          ),
        ],
      ),
    ],
  );
}

void main() {
  test(
    'main function is unique, serializable and changed in one undo step',
    () {
      final initial = _project();
      final engine = ProjectEngine(initial);
      expect(
        ProjectResolver(initial).mainOccurrence('supply')!.device.id,
        'main',
      );
      final command = EcadCommand.fromJson(
        const SetMainFunction('second', 'aux').toJson(),
      );
      engine.execute([command], label: 'Promote function');
      final resolver = ProjectResolver(engine.project);
      expect(resolver.mainOccurrence('supply')!.device.id, 'aux');
      expect(
        resolver
            .otherOccurrences(initial.pages.first.devices.single)
            .map((o) => o.device.id),
        ['aux', 'repeat'],
      );
      expect(buildBom(engine.project).components, hasLength(1));
      final reopened = EcadProject.fromJson(
        jsonDecode(jsonEncode(engine.project.toJson())),
      );
      expect(
        ProjectResolver(reopened).mainOccurrence('supply')!.device.id,
        'aux',
      );
      expect(
        engine.project.pages.last.devices.first.mode,
        OccurrenceMode.reference,
      );
      engine.undo();
      expect(
        ProjectResolver(engine.project).mainOccurrence('supply')!.device.id,
        'main',
      );
      expect(engine.canUndo, isFalse);
      engine.redo();
      expect(
        ProjectResolver(engine.project).mainOccurrence('supply')!.device.id,
        'aux',
      );
      engine.execute([const SetMainFunction('first', 'main')]);
      expect(engine.project.pages.last.devices.first.isMainFunction, isFalse);
    },
  );

  test(
    'deleting the main occurrence or its sheet resolves a remaining function',
    () {
      for (final removeSheet in [false, true]) {
        final engine = ProjectEngine(_project());
        engine.execute([const SetMainFunction('first', 'main')]);
        engine.execute([
          if (removeSheet)
            const DeleteSheet('first')
          else
            DeleteDevices('first', {'main'}),
        ]);
        expect(
          ProjectResolver(engine.project).mainOccurrence('supply')!.device.id,
          'aux',
        );
        engine.undo();
        expect(
          ProjectResolver(engine.project).mainOccurrence('supply')!.device.id,
          'main',
        );
      }
    },
  );

  test(
    'a transaction cannot introduce two main functions or an invalid target',
    () {
      final engine = ProjectEngine(_project());
      engine.execute([const SetMainFunction('first', 'main')]);
      final before = engine.project;
      expect(
        () => engine.execute([
          UpdateDevice(
            'second',
            before.pages.last.devices.first.copyWith(isMainFunction: true),
          ),
        ]),
        throwsA(isA<EcadException>()),
      );
      expect(engine.project, same(before));
      expect(
        () => engine.execute([const SetMainFunction('first', 'absent')]),
        throwsA(isA<EcadException>()),
      );
      expect(engine.project, same(before));
    },
  );
}
