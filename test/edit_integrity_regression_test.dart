// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/services/assistant_service.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/widgets/occurrence_dialog.dart';

class _MemoryPersistence extends ProjectPersistence {
  @override
  Future<void> saveWorkingCopy(WorkingCopy copy) async {}
}

EditorController _controller(EcadProject project) {
  final app = EditorController(
    initialProject: project,
    persistence: _MemoryPersistence(),
  );
  addTearDown(app.dispose);
  return app;
}

EcadProject _assembly({bool childFirst = false}) {
  final parent = createBuiltinComponent(
    componentId: 'parent',
    deviceId: 'parent-symbol',
    kind: DeviceKind.coil,
    designation: '-K1',
    position: const Vec2(200, 200),
  );
  final child = createBuiltinComponent(
    componentId: 'child',
    deviceId: 'child-symbol',
    kind: DeviceKind.coil,
    designation: '-K2',
    position: const Vec2(400, 200),
  );
  return EcadProject(
    id: 'project',
    name: 'Synthetic assembly',
    components: [
      parent.component,
      child.component.copyWith(
        procurement: const Procurement(
          source: ProcurementSource.included,
          includedInComponentId: 'parent',
        ),
      ),
    ],
    pages: [
      Sheet(
        id: 'sheet',
        name: 'Assembly',
        number: '01',
        devices:
            childFirst
                ? [child.device, parent.device]
                : [parent.device, child.device],
      ),
    ],
  );
}

EcadProject _sharedTerminalProject() => EcadProject(
  id: 'project',
  name: 'Synthetic shared electrical terminal',
  components: [
    Component(
      id: 'component',
      designation: '-A1',
      electrical: ElectricalModel(
        terminals: const [
          ComponentTerminal(id: 'terminal', designation: 'OLD'),
        ],
        functions: [
          ComponentFunction(
            id: 'function',
            name: 'Block',
            terminalIds: ['terminal'],
          ),
        ],
      ),
    ),
  ],
  pages: [
    Sheet(
      id: 'sheet',
      name: 'Ports',
      number: '01',
      devices: [
        Device(
          id: 'device',
          componentId: 'component',
          functionId: 'function',
          position: const Vec2(200, 200),
          symbol: PortBlockSpec(
            width: 80,
            height: 60,
            ports: const [
              BlockPort(
                id: 'left',
                terminalId: 'terminal',
                side: PortSide.left,
                fraction: .5,
              ),
              BlockPort(
                id: 'right',
                terminalId: 'terminal',
                side: PortSide.right,
                fraction: .5,
              ),
            ],
          ),
        ),
      ],
      continuations: const [
        ContinuationMarker(
          id: 'marker',
          linkId: 'link',
          position: Vec2(40, 200),
        ),
      ],
      wires: [
        Wire(
          id: 'wire',
          from: const ContinuationRef(markerId: 'marker'),
          to: const TerminalRef(deviceId: 'device', portId: 'left'),
        ),
      ],
    ),
  ],
  continuationLinks: const [ContinuationLink(id: 'link', label: 'SIGNAL')],
);

Finder _field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);

Future<void> _openPorts(WidgetTester tester, EditorController app) async {
  tester.view.physicalSize = const Size(1500, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder:
              (context) => TextButton(
                onPressed:
                    () => editPorts(context, app, app.sheet.devices.first),
                child: const Text('Open'),
              ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.text('Uložit'));
  await tester.pumpAndSettle();
  expect(find.text('Funkce a skutečné vývody'), findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final childFirst in [false, true]) {
    test(
      'each duplicated assembly retains its own parent, child first: $childFirst',
      () {
        final project = _assembly(childFirst: childFirst);
        final proposal = AssistantService().propose(
          'duplicate 2 times',
          project: project,
          sheetId: 'sheet',
          selectedDeviceIds: {'parent-symbol', 'child-symbol'},
        );
        expect(proposal.canApply, isTrue, reason: proposal.message);
        final engine = ProjectEngine(project);
        engine.execute(proposal.commands);
        final added =
            engine.project.components
                .where((c) => c.id != 'parent' && c.id != 'child')
                .toList();
        final parents =
            added
                .where(
                  (c) => c.procurement.source != ProcurementSource.included,
                )
                .toList();
        final children =
            added
                .where(
                  (c) => c.procurement.source == ProcurementSource.included,
                )
                .toList();
        expect(parents, hasLength(2));
        expect(
          children.map((c) => c.procurement.includedInComponentId).toSet(),
          parents.map((c) => c.id).toSet(),
        );
        for (final child in children) {
          final parent = parents.singleWhere(
            (c) => c.id == child.procurement.includedInComponentId,
          );
          final symbols = engine.project.pages.single.devices;
          final parentSymbol = symbols.singleWhere(
            (d) => d.componentId == parent.id,
          );
          final childSymbol = symbols.singleWhere(
            (d) => d.componentId == child.id,
          );
          expect(childSymbol.position.x - parentSymbol.position.x, 200);
          expect(
            buildBom(engine.project).components
                .singleWhere((r) => r.component.id == child.id)
                .includedInDesignation,
            ProjectResolver(engine.project).fullDesignation(parent),
          );
        }
        expect(engine.undo(), isTrue);
        expect(engine.project.components.map((c) => c.id).toSet(), {
          'parent',
          'child',
        });
        expect(engine.redo(), isTrue);
        expect(engine.project.components, hasLength(6));
      },
    );
  }

  test('duplicating a child alone preserves its external parent', () {
    final project = _assembly();
    final engine = ProjectEngine(project);
    engine.execute(
      AssistantService().duplicateCommands(
        project: project,
        sheetId: 'sheet',
        deviceIds: {'child-symbol'},
        graphicIds: {},
      ),
    );
    expect(
      engine.project.components.last.procurement.includedInComponentId,
      'parent',
    );
  });

  for (final suffixOccupied in [false, true]) {
    test(
      'new function reserves terminal names case insensitively, suffix occupied: $suffixOccupied',
      () {
        final seed = createBuiltinComponent(
          componentId: 'component',
          deviceId: 'device',
          kind: DeviceKind.coil,
          designation: '-K1',
          position: const Vec2(200, 200),
        );
        final component = seed.component.copyWith(
          electrical: seed.component.electrical!.copyWith(
            terminals: [
              for (final t in seed.component.electrical!.terminals)
                t.copyWith(designation: t.designation.toLowerCase()),
              if (suffixOccupied) ...const [
                ComponentTerminal(id: 'extra-a1', designation: 'a1.2'),
                ComponentTerminal(id: 'extra-a2', designation: 'a2.2'),
              ],
            ],
          ),
        );
        final app = _controller(
          EcadProject(
            id: 'project',
            name: 'Synthetic functions',
            components: [component],
            pages: [
              Sheet(
                id: 'sheet',
                name: 'Functions',
                number: '01',
                devices: [seed.device],
              ),
            ],
          ),
        );
        expect(
          app.addOccurrence(
            component,
            kind: DeviceKind.coil,
            position: const Vec2(500, 200),
          ),
          isTrue,
          reason: app.status,
        );
        final electrical = app.project.components.single.electrical!;
        expect(
          electrical.terminals.map((t) => t.designation),
          containsAll(suffixOccupied ? ['A1.3', 'A2.3'] : ['A1.2', 'A2.2']),
        );
        expect(electrical.functions, hasLength(2));
        expect(app.bom.articles.single.requiredTotal.knownBaseUnits, 1);
        app.undo();
        expect(
          app.project.components.single.electrical!.functions,
          hasLength(1),
        );
        expect(app.sheet.devices, hasLength(1));
      },
    );
  }

  for (final alias in [0, 1]) {
    testWidgets(
      'editing alias $alias updates one electrical terminal and preserves its wire',
      (tester) async {
        final app = _controller(_sharedTerminalProject());
        final originalWire = app.sheet.wires.single;
        await _openPorts(tester, app);
        await tester.enterText(_field('Vývod').at(alias), 'NEW');
        await tester.enterText(_field('Signál').at(alias), '24V');
        for (var index = 0; index < 2; index++) {
          expect(
            tester
                .widget<TextField>(_field('Vývod').at(index))
                .controller!
                .text,
            'NEW',
          );
          expect(
            tester
                .widget<TextField>(_field('Signál').at(index))
                .controller!
                .text,
            '24V',
          );
        }
        await _save(tester);
        final terminal =
            app.project.components.single.electrical!.terminals.single;
        expect(terminal.id, 'terminal');
        expect(terminal.designation, 'NEW');
        expect(terminal.signal, '24V');
        expect(
          app.resolver
              .ports(app.sheet.devices.single)
              .map((p) => p.node)
              .toSet(),
          hasLength(1),
        );
        expect(app.sheet.wires.single, same(originalWire));
        app.undo();
        expect(
          app
              .project
              .components
              .single
              .electrical!
              .terminals
              .single
              .designation,
          'OLD',
        );
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }

  testWidgets(
    'a port rebound to a shared identity adopts its pending metadata',
    (tester) async {
      final project = _sharedTerminalProject();
      final old = project.components.single;
      final device = project.pages.single.devices.single;
      final block = device.symbol as PortBlockSpec;
      final app = _controller(
        project.copyWith(
          components: [
            old.copyWith(
              electrical: old.electrical!.copyWith(
                terminals: [
                  ...old.electrical!.terminals,
                  const ComponentTerminal(id: 'other', designation: 'OTHER'),
                ],
                functions: [
                  old.electrical!.functions.single.copyWith(
                    terminalIds: ['terminal', 'other'],
                  ),
                ],
              ),
            ),
          ],
          pages: [
            project.pages.single.copyWith(
              devices: [
                device.copyWith(
                  symbol: block.copyWith(
                    ports: [
                      block.ports.first,
                      block.ports.last.copyWith(terminalId: 'other'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      );
      await _openPorts(tester, app);
      await tester.enterText(_field('Vývod').first, 'NEW');
      await tester.enterText(_field('Signál').first, '24V');
      final binding =
          find
              .byWidgetPredicate((w) => w is DropdownButtonFormField<String>)
              .last;
      await tester.tap(binding);
      await tester.pumpAndSettle();
      await tester.tap(find.text('OLD').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_field('Vývod').last).controller!.text,
        'NEW',
      );
      expect(
        tester.widget<TextField>(_field('Signál').last).controller!.text,
        '24V',
      );
      await _save(tester);
      final electrical = app.project.components.single.electrical!;
      expect(electrical.terminalById('terminal')!.designation, 'NEW');
      expect(electrical.terminalById('other')!.designation, 'OTHER');
      expect(
        app.resolver.ports(app.sheet.devices.single).map((p) => p.node).toSet(),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'terminal connection point names remain independent on a common node',
    (tester) async {
      final seed = createTerminalComponent(
        componentId: 'component',
        deviceId: 'device',
        stripId: 'strip',
        position: const Vec2(200, 200),
      );
      final app = _controller(
        EcadProject(
          id: 'project',
          name: 'Synthetic through terminal',
          terminalStrips: [
            TerminalStrip(
              id: 'strip',
              reference: ComponentReference(localDesignation: 'X1'),
            ),
          ],
          components: [seed.component],
          pages: [
            Sheet(
              id: 'sheet',
              name: 'Terminals',
              number: '01',
              devices: [seed.device],
            ),
          ],
        ),
      );
      await _openPorts(tester, app);
      final fields = _field('Vývod');
      expect(fields, findsNWidgets(2));
      final unchanged = tester.widget<TextField>(fields.last).controller!.text;
      await tester.enterText(fields.first, 'IN');
      expect(tester.widget<TextField>(fields.last).controller!.text, unchanged);
      await tester.enterText(fields.last, 'OUT');
      await tester.enterText(_field('Signál uzlu'), '24V');
      await _save(tester);
      final component = app.project.components.single;
      expect(
        component.terminal!.connectionPoints.values,
        containsAll(['IN', 'OUT']),
      );
      expect(component.electrical!.terminals, hasLength(1));
      expect(
        app.resolver
            .ports(app.sheet.devices.single)
            .map((p) => p.signal)
            .toSet(),
        {'24V'},
      );
      expect(
        app.resolver.ports(app.sheet.devices.single).map((p) => p.node).toSet(),
        hasLength(1),
      );
    },
  );
}
