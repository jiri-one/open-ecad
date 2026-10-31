import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'allocators reserve printed references without interpreting legacy names',
    () {
      final context = StructureContext(functionPath: ['TEST']);
      final strip = TerminalStrip(
        id: 'strip',
        reference: ComponentReference(context: context, localDesignation: 'X1'),
      );
      final project = EcadProject(
        id: 'project',
        name: 'Synthetic',
        terminalStrips: [strip],
        components: const [
          Component(id: 'old-coil', designation: ' =test-k1 '),
          Component(id: 'old-terminal', designation: '=TEST-X1:1'),
        ],
        pages: [
          Sheet(id: 'sheet', name: 'Sheet', number: '01', structure: context),
        ],
      );
      requireValidProject(project);
      expect(nextLocalDesignation(project, context, 'K'), 'K2');
      expect(nextTerminalNumber(project, strip), '2');
      expect(nextLocalDesignation(project, context, 'X'), 'X2');
      expect(project.components.first.reference, isNull);
      expect(project.components.first.designation, ' =test-k1 ');
    },
  );

  test(
    'page allocation checks printed references and preserves slash segments',
    () {
      final context = StructureContext(locationPath: ['TEST/01']);
      final project = EcadProject(
        id: 'project',
        name: 'Synthetic',
        pages: [
          Sheet(id: 'sheet', name: 'Sheet', number: '03', structure: context),
          Sheet(
            id: 'other',
            name: 'Other',
            number: '01/01',
            structure: StructureContext(locationPath: ['TEST']),
          ),
        ],
      );
      requireValidProject(project);
      expect(nextPageNumber(project, project.pages.first), '02');
      expect(project.pages.first.structure.locationPath, ['TEST/01']);
    },
  );

  test('a shared terminal node warns only for a second wiring occurrence', () {
    final strip = TerminalStrip(
      id: 'strip',
      reference: ComponentReference(localDesignation: 'X1'),
    );
    for (var mask = 1; mask < 16; mask++) {
      final seed = createTerminalComponent(
        componentId: 'piece',
        deviceId: 'symbol',
        stripId: strip.id,
        number: '1',
        position: const Vec2(100, 100),
        sides: {
          for (var i = 0; i < 4; i++)
            if (mask & (1 << i) != 0) PortSide.values[i],
        },
      );
      final project = EcadProject(
        id: 'project',
        name: 'Synthetic',
        terminalStrips: [strip],
        components: [seed.component],
        pages: [
          Sheet(
            id: 'sheet',
            name: 'Sheet',
            number: '01',
            devices: [seed.device],
          ),
        ],
      );
      final warnings = validateProject(project);
      expect(
        warnings.where((d) => d.code == 'repeated_wiring_terminal'),
        isEmpty,
        reason: 'mask $mask',
      );
      expect(warnings.where((d) => d.code == 'unconnected_port'), hasLength(1));
      final repeated = project.copyWith(
        pages: [
          project.pages.single.copyWith(
            devices: [
              seed.device,
              seed.device.copyWith(
                id: 'second',
                position: const Vec2(300, 300),
              ),
            ],
          ),
        ],
      );
      expect(
        validateProject(
          repeated,
        ).where((d) => d.code == 'repeated_wiring_terminal'),
        hasLength(1),
        reason: 'mask $mask',
      );
    }
  });

  test('branch command renames large branches atomically and roundtrips', () {
    final context = StructureContext(locationPath: ['CAB', 'DIN']);
    final project = EcadProject(
      id: 'project',
      name: 'Synthetic',
      terminalStrips: [
        TerminalStrip(
          id: 'strip',
          reference: ComponentReference(
            context: context,
            localDesignation: 'X1',
          ),
        ),
      ],
      components: [
        for (var i = 0; i < 1000; i++)
          Component(
            id: 'c$i',
            reference: ComponentReference(
              context: context,
              localDesignation: 'K$i',
            ),
          ),
        const Component(id: 'opaque', designation: '+CAB-K1000'),
      ],
      pages: [
        Sheet(id: 'sheet', name: 'Sheet', number: '01', structure: context),
      ],
    );
    final engine = ProjectEngine(project);
    final command = RenameStructureBranch(
      StructureAspect.location,
      ['CAB'],
      ['NEW'],
    );
    final parsed = EcadCommand.fromJson(
      jsonDecode(jsonEncode(command.toJson())),
    );
    expect(parsed.toJson(), command.toJson());
    engine.execute([parsed]);
    expect(engine.project.pages.single.structure.locationPath, ['NEW', 'DIN']);
    expect(
      engine.project.components
          .take(1000)
          .every(
            (c) => c.reference!.context.locationPath.join('/') == 'NEW/DIN',
          ),
      isTrue,
    );
    expect(engine.project.terminalStrips.single.reference.full, '+NEW+DIN-X1');
    expect(engine.project.components.last.designation, '+CAB-K1000');
    expect(
      engine.project.components.map((c) => c.id),
      project.components.map((c) => c.id),
    );
    expect(engine.undo(), isTrue);
    expect(engine.canUndo, isFalse);
    expect(engine.project.pages.single.structure, context);
    expect(engine.project.terminalStrips.single.reference.full, '+CAB+DIN-X1');
    expect(engine.redo(), isTrue);
    expect(engine.project.pages.single.structure.locationPath, ['NEW', 'DIN']);
  });

  test('branch collisions roll back the whole edit without history', () {
    final context = StructureContext(locationPath: ['CAB']);
    final project = EcadProject(
      id: 'project',
      name: 'Synthetic',
      terminalStrips: [
        TerminalStrip(
          id: 'strip',
          reference: ComponentReference(
            context: context,
            localDesignation: 'X1',
          ),
        ),
      ],
      components: [
        Component(
          id: 'moving',
          reference: ComponentReference(
            context: context,
            localDesignation: 'K1',
          ),
        ),
        const Component(id: 'opaque', designation: '+NEW-K1'),
      ],
      pages: [
        Sheet(id: 'sheet', name: 'Sheet', number: '01', structure: context),
      ],
    );
    final engine = ProjectEngine(project);
    expect(
      () => engine.execute([
        RenameStructureBranch(StructureAspect.location, ['CAB'], ['NEW']),
      ]),
      throwsA(isA<EcadException>()),
    );
    expect(engine.project, same(project));
    expect(engine.canUndo, isFalse);
    expect(
      () => engine.execute([
        RenameStructureBranch(StructureAspect.location, ['CAB'], ['bad+code']),
      ]),
      throwsA(isA<EcadException>()),
    );
    expect(engine.project, same(project));
    expect(
      () => EcadCommand.fromJson({
        'type': 'renameStructureBranch',
        'aspect': 'unknown',
        'prefix': <String>[],
        'replacement': <String>[],
      }),
      throwsA(isA<EcadException>()),
    );
  });
}
