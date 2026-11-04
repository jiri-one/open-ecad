import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

EcadProject structuredProject() {
  final a = StructureContext(
    functionPath: ['F'],
    locationPath: ['L/1'],
    productPath: ['A'],
  );
  final b = StructureContext(
    functionPath: ['F'],
    locationPath: ['L/2'],
    productPath: ['A'],
  );
  return EcadProject(
    id: 'project',
    name: 'Synthetic',
    pages: [
      Sheet(id: 'a', name: 'A', number: '01', structure: a),
      Sheet(id: 'b', name: 'B', number: '01', structure: b),
    ],
    components: [
      Component(
        id: 'ca',
        reference: ComponentReference(context: a, localDesignation: 'K1'),
      ),
      Component(
        id: 'cb',
        reference: ComponentReference(context: b, localDesignation: 'K1'),
      ),
    ],
  );
}

void main() {
  test(
    'explicit paths and local names survive JSON and have full scoped uniqueness',
    () {
      final project = structuredProject();
      requireValidProject(project);
      final resolver = ProjectResolver(project);
      expect(resolver.fullDesignation(project.components.first), '=F+L/1-A-K1');
      expect(
        resolver.relativeDesignation(
          project.components.first,
          project.pages.first.structure,
        ),
        '-K1',
      );
      expect(
        resolver.relativeDesignation(
          project.components.first,
          project.pages.last.structure,
        ),
        '=F+L/1-A-K1',
      );
      expect(
        fullPageDesignation(project.pages.first.copyWith(documentCode: 'DOC')),
        '=F+L/1-A&DOC/01',
      );
      final reopened = EcadProject.fromJson(project.toJson());
      expect(reopened.pages.first.structure.locationPath, ['L/1']);
      expect(
        reopened.components.first.toJson().containsKey('designation'),
        isFalse,
      );
      expect(
        nextLocalDesignation(project, project.pages.last.structure, 'K'),
        'K2',
      );
      expect(
        nextLocalDesignation(
          project,
          StructureContext(locationPath: ['OTHER']),
          'K',
        ),
        'K1',
      );
      final engine = ProjectEngine(project);
      expect(
        () => engine.execute([
          UpdateComponent(
            project.components.last.copyWith(
              reference: project.components.first.reference,
            ),
          ),
        ]),
        throwsA(isA<EcadException>()),
      );
      expect(
        engine.project.components.last.reference!.context,
        project.pages.last.structure,
      );
      expect(
        () => engine.execute([
          UpdateSheet(
            project.pages.last.copyWith(
              structure: project.pages.first.structure,
            ),
          ),
        ]),
        throwsA(isA<EcadException>()),
      );
    },
  );

  test('old v4 designation is opaque and no structure is inferred', () {
    final project = EcadProject(
      id: 'legacy',
      name: 'Legacy',
      pages: [Sheet(id: 'page', name: 'Page', number: '01')],
      components: const [Component(id: 'old', designation: '=+OPAQUE-K1.1')],
    );
    final json = project.toJson()..['formatVersion'] = 4;
    final reopened = EcadProject.fromJson(json);
    expect(reopened.components.single.reference, isNull);
    expect(reopened.components.single.designation, '=+OPAQUE-K1.1');
    expect(reopened.pages.single.structure.isEmpty, isTrue);
    expect(reopened.toJson()['formatVersion'], EcadProject.formatVersion);
  });

  test(
    'page changes preserve physical references and branch edits undo atomically',
    () {
      final project = structuredProject();
      final engine = ProjectEngine(project);
      final original = project.components.first;
      engine.execute([
        UpdateSheet(
          project.pages.first.copyWith(
            structure: StructureContext(locationPath: ['NEW']),
          ),
        ),
      ]);
      expect(engine.project.components.first, same(original));
      engine.undo();
      expect(
        engine.project.pages.first.structure,
        project.pages.first.structure,
      );
      final next = replaceStructurePrefix(
        original.reference!.context,
        StructureAspect.location,
        ['L/1'],
        ['NEW/1'],
      );
      engine.execute([
        UpdateComponent(
          original.copyWith(
            reference: ComponentReference(
              context: next,
              localDesignation: 'K1',
            ),
          ),
        ),
      ]);
      expect(engine.project.components.first.id, original.id);
      engine.undo();
      expect(
        engine.project.components.first.reference!.context,
        original.reference!.context,
      );
    },
  );

  test(
    'all 15 terminal variants use one physical piece and one conductive node',
    () {
      final strip = TerminalStrip(
        id: 'strip',
        reference: ComponentReference(
          context: StructureContext(locationPath: ['CAB']),
          localDesignation: 'X1',
        ),
      );
      for (var mask = 1; mask < 16; mask++) {
        final sides = {
          for (var i = 0; i < 4; i++)
            if (mask & (1 << i) != 0) PortSide.values[i],
        };
        final seed = createTerminalComponent(
          componentId: 'terminal',
          deviceId: 'symbol',
          stripId: strip.id,
          number: '7',
          position: const Vec2(100, 100),
          sides: sides,
        );
        final project = EcadProject(
          id: 'p',
          name: 'Terminal',
          terminalStrips: [strip],
          components: [seed.component],
          pages: [
            Sheet(id: 's', name: 'S', number: '01', devices: [seed.device]),
          ],
        );
        requireValidProject(project);
        final reopened = EcadProject.fromJson(project.toJson());
        final resolver = ProjectResolver(reopened);
        final ports = resolver.ports(reopened.pages.single.devices.single);
        expect(ports, hasLength(sides.length));
        expect(ports.map((p) => p.node).toSet(), hasLength(1));
        expect(ports.map((p) => p.label).toSet(), hasLength(sides.length));
        expect(resolver.fullDesignation(seed.component), '+CAB-X1:7');
        expect(
          buildBom(reopened).articles.single.requiredTotal.knownBaseUnits,
          1,
        );
      }
    },
  );

  test(
    'through terminal joins external wires, preserves rotated port IDs and rejects deleting wired sides',
    () {
      final strip = TerminalStrip(
        id: 'strip',
        reference: ComponentReference(localDesignation: 'X1'),
      );
      final a = createTerminalComponent(
        componentId: 'a',
        deviceId: 'da',
        stripId: 'strip',
        number: '1',
        position: const Vec2(100, 100),
        sides: PortSide.values.toSet(),
      );
      final b = createTerminalComponent(
        componentId: 'b',
        deviceId: 'db',
        stripId: 'strip',
        number: '2',
        position: const Vec2(300, 200),
      );
      final project = EcadProject(
        id: 'p',
        name: 'Wired',
        terminalStrips: [strip],
        components: [a.component, b.component],
        continuationLinks: const [
          ContinuationLink(id: 'input', label: 'IN'),
          ContinuationLink(id: 'output', label: 'OUT'),
        ],
        pages: [
          Sheet(
            id: 's',
            name: 'S',
            number: '01',
            devices: [a.device, b.device],
            continuations: const [
              ContinuationMarker(
                id: 'in',
                linkId: 'input',
                position: Vec2(100, 40),
              ),
              ContinuationMarker(
                id: 'out',
                linkId: 'output',
                position: Vec2(160, 100),
              ),
            ],
            wires: [
              Wire(
                id: 'w1',
                from: const ContinuationRef(markerId: 'in'),
                to: const TerminalRef(deviceId: 'da', portId: 'top'),
              ),
              Wire(
                id: 'w2',
                from: const TerminalRef(deviceId: 'da', portId: 'right'),
                to: const ContinuationRef(markerId: 'out'),
              ),
            ],
          ),
        ],
      );
      final resolver = ProjectResolver(project);
      final connectivity = ConnectivityIndex.build(project);
      expect(
        connectivity.connected(
          const ElectricalNode.link('input'),
          const ElectricalNode.link('output'),
        ),
        isTrue,
      );
      expect(
        connectivity.connected(
          resolver.ports(a.device).first.node,
          resolver.ports(b.device).first.node,
        ),
        isFalse,
      );
      final engine = ProjectEngine(project);
      engine.execute([UpdateDevice('s', a.device.copyWith(rotation: 90))]);
      expect(
        engine.project.pages.single.wires.first.to,
        const TerminalRef(deviceId: 'da', portId: 'top'),
      );
      final rotated = engine.project.pages.single.devices.first;
      expect(WireRouter.terminal(rotated, 'top')!.point, const Vec2(110, 100));
      expect(
        () => engine.execute([
          UpdateDevice(
            's',
            rotated.copyWith(
              symbol: (rotated.symbol as TerminalSymbolSpec).copyWith(
                sides: {PortSide.bottom},
              ),
            ),
          ),
        ]),
        throwsA(isA<EcadException>()),
      );
      expect(
        ConnectivityIndex.build(
          EcadProject.fromJson(engine.project.toJson()),
        ).connected(
          const ElectricalNode.link('input'),
          const ElectricalNode.link('output'),
        ),
        isTrue,
      );
      engine.undo();
      expect(engine.project.pages.single.devices.first.rotation, 0);
    },
  );

  test(
    'all four autoconnections join through one terminal and removal cannot silently disconnect them',
    () {
      final strip = TerminalStrip(
        id: 'strip',
        reference: ComponentReference(localDesignation: 'X1'),
      );
      final seed = createTerminalComponent(
        componentId: 'piece',
        deviceId: 'symbol',
        stripId: strip.id,
        position: const Vec2(300, 300),
        sides: PortSide.values.toSet(),
      );
      final links = [
        for (final side in PortSide.values)
          ContinuationLink(id: side.name, label: side.name),
      ];
      final markers = [
        const ContinuationMarker(
          id: 'mt',
          linkId: 'top',
          position: Vec2(300, 200),
          direction: PortSide.bottom,
        ),
        const ContinuationMarker(
          id: 'mb',
          linkId: 'bottom',
          position: Vec2(300, 400),
          direction: PortSide.top,
        ),
        const ContinuationMarker(
          id: 'ml',
          linkId: 'left',
          position: Vec2(200, 300),
          direction: PortSide.right,
        ),
        const ContinuationMarker(
          id: 'mr',
          linkId: 'right',
          position: Vec2(400, 300),
          direction: PortSide.left,
        ),
      ];
      final project = EcadProject(
        id: 'p',
        name: 'Auto terminal',
        terminalStrips: [strip],
        components: [seed.component],
        continuationLinks: links,
        pages: [
          Sheet(
            id: 's',
            name: 'Auto',
            number: '01',
            devices: [seed.device],
            continuations: markers,
          ),
        ],
      );
      requireValidProject(project);
      expect(AutoConnect.automaticWires(project.pages.single), hasLength(4));
      final topology = ConnectivityIndex.build(project);
      for (final a in links) {
        for (final b in links) {
          expect(
            topology.connected(
              ElectricalNode.link(a.id),
              ElectricalNode.link(b.id),
            ),
            isTrue,
          );
        }
      }
      final engine = ProjectEngine(project);
      expect(
        () => engine.execute([
          UpdateDevice(
            's',
            seed.device.copyWith(
              symbol: (seed.device.symbol as TerminalSymbolSpec).copyWith(
                sides: {PortSide.top},
              ),
            ),
          ),
        ]),
        throwsA(
          isA<EcadException>().having(
            (e) => e.code,
            'code',
            'connected_terminal_port',
          ),
        ),
      );
      expect(
        AutoConnect.automaticWires(engine.project.pages.single),
        hasLength(4),
      );
      expect(
        () => engine.execute([
          UpdateComponent(
            seed.component.copyWith(
              electrical: seed.component.electrical!.copyWith(
                terminals: [
                  ...seed.component.electrical!.terminals,
                  const ComponentTerminal(id: 'extra-pole', designation: '2'),
                ],
              ),
            ),
          ),
        ]),
        throwsA(isA<EcadException>()),
      );
    },
  );
}
