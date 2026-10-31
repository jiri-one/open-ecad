// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';
import 'support.dart';

void main() {
  test('every physical built-in round-trips and wires its declared ports', () {
    final devices = [
      for (final kind in DeviceKind.values)
        if (kind != DeviceKind.earth)
          syntheticDevice(
            id: 'd_${kind.name}',
            kind: kind,
            position: const Vec2(200, 200),
          ),
    ];
    final original = syntheticProject(
      id: 'p',
      name: 'Symbols',
      pages: [Sheet(id: 's', name: 'S', number: '1', devices: devices)],
    );
    final restored = EcadProject.fromJson(
      jsonDecode(jsonEncode(original.toJson())),
    );
    requireValidProject(restored);
    expect(restored.toJson(), original.toJson());
    final resolver = ProjectResolver(restored);
    for (final d in devices) {
      for (final p in resolver.ports(d)) {
        expect(p.node.componentId, d.componentId);
        expect(p.label, p.ref.portId);
        expect(p.geometry.point, worldPortPosition(d, p.ref.portId));
      }
    }
  });

  test('block edge normal does not depend on offset from symbol centre', () {
    final device = Device(
      id: 'block',
      componentId: 'c',
      functionId: 'f',
      position: const Vec2(100, 100),
      symbol: PortBlockSpec(
        width: 50,
        height: 300,
        ports: const [
          BlockPort(
            id: 'p',
            terminalId: 't',
            side: PortSide.left,
            fraction: .05,
          ),
        ],
      ),
    );
    final terminal = WireRouter.terminal(device, 'p')!;
    expect(terminal.direction, const Vec2(-1, 0));
    expect(terminal.point, const Vec2(75, -35));
    final rotated = WireRouter.terminal(device.copyWith(rotation: 90), 'p')!;
    expect(rotated.direction, const Vec2(0, -1));
    final route = WireRouter.route(
      terminal,
      const WireTerminal(Vec2(300, 100)),
    );
    expect(route[1].x, lessThan(route.first.x));
    for (var i = 1; i < route.length; i++) {
      expect(terminal.body!.crosses(route[i - 1], route[i]), isFalse);
    }
  });

  test('catalog seed creates new physical identity and stable bindings', () {
    final seed = createBuiltinComponent(
      componentId: 'c',
      deviceId: 'd',
      kind: DeviceKind.coil,
      designation: '-K1',
      position: Vec2.zero,
    );
    final p = EcadProject(
      id: 'p',
      name: 'P',
      components: [seed.component],
      pages: [
        Sheet(id: 's', name: 'S', number: '1', devices: [seed.device]),
      ],
    );
    requireValidProject(p);
    expect(buildBom(p).articles.single.installed.knownBaseUnits, 1);
    expect(
      SymbolCatalog.nextDesignation([seed.component], DeviceKind.coil),
      '-K2',
    );
    expect(
      () => createBuiltinComponent(
        componentId: 'c',
        deviceId: 'd',
        kind: DeviceKind.earth,
        designation: 'PE',
        position: Vec2.zero,
      ),
      throwsA(isA<EcadException>()),
    );
  });
}
