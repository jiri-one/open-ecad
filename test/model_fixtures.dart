import 'package:ecad_core/ecad_core.dart';

final _components = <String, Component>{};

Device testBuiltin({
  required String id,
  required DeviceKind kind,
  required String designation,
  required Vec2 position,
  String rating = '',
  String description = '',
  double rotation = 0,
}) {
  final cid = 'component_$id';
  final definition = SymbolCatalog.definitionFor(kind);
  final terminals = [
    for (final p in definition.ports)
      ComponentTerminal(id: '${cid}_${p.id}', designation: p.label),
  ];
  final function = ComponentFunction(
    id: '${cid}_function',
    name: definition.label,
    terminalIds: terminals.map((t) => t.id).toList(),
  );
  _components[cid] = Component(
    id: cid,
    designation: designation,
    description: [description, rating].where((v) => v.isNotEmpty).join(' · '),
    electrical: ElectricalModel(terminals: terminals, functions: [function]),
  );
  return Device(
    id: id,
    componentId: cid,
    functionId: function.id,
    symbol: BuiltinSymbolSpec(
      kind: kind,
      bindings: {for (final p in definition.ports) p.id: '${cid}_${p.id}'},
    ),
    position: position,
    rotation: rotation,
  );
}

List<Component> fixtureComponents(Iterable<Device> devices) =>
    devices.map((d) => _components[d.componentId]!).toList();
EcadProject testProject({
  required String id,
  required String name,
  required List<Sheet> pages,
  int revision = 0,
}) => EcadProject(
  id: id,
  name: name,
  revision: revision,
  pages: pages,
  components: fixtureComponents(pages.expand((p) => p.devices)),
);

EcadProject testDemoProject() {
  final power = [
    testBuiltin(
      id: 'dev_supply',
      kind: DeviceKind.supply,
      designation: '-G1',
      position: const Vec2(400, 150),
    ),
    testBuiltin(
      id: 'dev_breaker',
      kind: DeviceKind.breaker,
      designation: '-Q1',
      position: const Vec2(400, 270),
    ),
    testBuiltin(
      id: 'dev_contactor',
      kind: DeviceKind.contactor,
      designation: '-K1',
      position: const Vec2(400, 390),
    ),
    testBuiltin(
      id: 'dev_motor',
      kind: DeviceKind.motor,
      designation: '-M1',
      position: const Vec2(400, 550),
    ),
    testBuiltin(
      id: 'dev_pe_terminal',
      kind: DeviceKind.terminal,
      designation: '-X1',
      position: const Vec2(710, 460),
    ),
  ];
  final control = [
    testBuiltin(
      id: 'dev_control_supply',
      kind: DeviceKind.supply,
      designation: '-G2',
      position: const Vec2(370, 150),
    ),
    testBuiltin(
      id: 'dev_enable',
      kind: DeviceKind.contactNo,
      designation: '-S1',
      position: const Vec2(370, 280),
    ),
    testBuiltin(
      id: 'dev_coil',
      kind: DeviceKind.coil,
      designation: '-K2',
      position: const Vec2(370, 440),
    ),
    testBuiltin(
      id: 'dev_lamp',
      kind: DeviceKind.lamp,
      designation: '-H1',
      position: const Vec2(700, 440),
    ),
    testBuiltin(
      id: 'dev_return',
      kind: DeviceKind.terminal,
      designation: '-X2',
      position: const Vec2(370, 585),
    ),
  ];
  Wire w(String id, String a, String ap, String b, String bp) => Wire(
    id: id,
    from: TerminalRef(deviceId: a, portId: ap),
    to: TerminalRef(deviceId: b, portId: bp),
  );
  return EcadProject(
    id: 'fixture_demo',
    name: 'Syntetické schéma',
    components: fixtureComponents([...power, ...control]),
    pages: [
      Sheet(
        id: 'sheet_power',
        name: 'Silový obvod',
        number: '01',
        type: SheetType.singleLine,
        devices: power,
        wires: [
          w('wire_p1', 'dev_supply', 'out', 'dev_breaker', 'in'),
          w('wire_p2', 'dev_breaker', 'out', 'dev_contactor', 'in'),
          w('wire_p3', 'dev_contactor', 'out', 'dev_motor', 'in'),
          w('wire_pe1', 'dev_motor', 'pe', 'dev_pe_terminal', 'in').copyWith(
            waypoints: const [Vec2(600, 550), Vec2(600, 420), Vec2(710, 420)],
          ),
        ],
      ),
      Sheet(
        id: 'sheet_control',
        name: 'Pomocný obvod',
        number: '02',
        devices: control,
        wires: [
          w('wire_c1', 'dev_control_supply', 'out', 'dev_enable', 'in'),
          w('wire_c2', 'dev_enable', 'out', 'dev_coil', 'a1'),
          w('wire_c3', 'dev_enable', 'out', 'dev_lamp', 'in'),
          w('wire_c4', 'dev_coil', 'a2', 'dev_return', 'in'),
          w('wire_c5', 'dev_lamp', 'out', 'dev_return', 'in'),
        ],
      ),
    ],
  );
}
