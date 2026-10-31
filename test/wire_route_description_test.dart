// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/wire_route_description.dart';
import 'wiring_fixtures.dart';

void main() {
  test(
    'automatic corner route names the real terminals and no serialized IDs',
    () {
      final p = wiringScene(withCorner: true),
          r = ProjectResolver(wiringScene(withCorner: true));
      final s = p.pages.single;
      for (final wire in r.wires(s)) {
        final info =
            resolveWireRouteHoverInfo(resolver: r, sheet: s, wireId: wire.id)!;
        expect(info.label, anyOf('-A:1 → -B:1', '-B:1 → -A:1'));
        expect(info.tooltip, isNot(contains('component_')));
        expect(info.tooltip, isNot(contains('@auto')));
      }
    },
  );

  test(
    'continuations traverse by link identity and branches are summarized',
    () {
      final base = wiringScene();
      final p = base.copyWith(
        continuationLinks: [
          const ContinuationLink(id: 'link', label: 'Řízení'),
        ],
        pages: [
          base.pages.single.copyWith(
            devices: [base.pages.single.devices.first],
            continuations: [
              const ContinuationMarker(
                id: 'one',
                linkId: 'link',
                position: Vec2(400, 300),
                direction: PortSide.right,
              ),
            ],
            wires: [
              Wire(
                id: 'w1',
                from: const TerminalRef(deviceId: 'a', portId: 'p'),
                to: const ContinuationRef(markerId: 'one'),
              ),
            ],
          ),
          Sheet(
            id: 'second',
            name: 'Druhý',
            number: '2',
            devices: [base.pages.single.devices.last],
            continuations: [
              const ContinuationMarker(
                id: 'two',
                linkId: 'link',
                position: Vec2(400, 300),
                direction: PortSide.bottom,
              ),
            ],
            wires: [
              Wire(
                id: 'w2',
                from: const ContinuationRef(markerId: 'two'),
                to: const TerminalRef(deviceId: 'b', portId: 'p'),
              ),
            ],
          ),
        ],
      );
      requireValidProject(p);
      final info =
          resolveWireRouteHoverInfo(
            resolver: ProjectResolver(p),
            sheet: p.pages.first,
            wireId: 'w1',
          )!;
      expect(info.label, '-A:1 → -B:1');
      expect(info.detail, contains('2 · Druhý'));
      final s = p.pages.last;
      final b = s.devices.single;
      final branched = p.copyWith(
        pages: [
          p.pages.first,
          s.copyWith(
            devices: [
              b,
              b.copyWith(
                id: 'other',
                componentId: 'branch',
                functionId: 'bf',
                symbol: PortBlockSpec(
                  width: 20,
                  height: 20,
                  ports: [
                    const BlockPort(
                      id: 'p',
                      terminalId: 'bt',
                      side: PortSide.left,
                      fraction: .5,
                    ),
                  ],
                ),
              ),
            ],
            wires: [
              ...s.wires,
              Wire(
                id: 'branch_wire',
                from: const ContinuationRef(markerId: 'two'),
                to: const TerminalRef(deviceId: 'other', portId: 'p'),
              ),
            ],
          ),
        ],
        components: [
          ...p.components,
          Component(
            id: 'branch',
            designation: '-C',
            electrical: ElectricalModel(
              terminals: [const ComponentTerminal(id: 'bt', designation: '2')],
              functions: [
                ComponentFunction(
                  id: 'bf',
                  name: 'Funkce',
                  terminalIds: ['bt'],
                ),
              ],
            ),
          ),
        ],
      );
      requireValidProject(branched);
      final branch =
          resolveWireRouteHoverInfo(
            resolver: ProjectResolver(branched),
            sheet: branched.pages.first,
            wireId: 'w1',
          )!;
      expect(branch.label, '-A:1 → -B:1, -C:2');
      expect(branch.detail, contains('Větev'));
    },
  );

  test('open corner and corner cycle terminate with a clear fallback', () {
    final base = wiringScene(withCorner: true),
        s = wiringScene(withCorner: true).pages.single;
    final p = base.copyWith(
      pages: [
        s.copyWith(devices: [s.devices.first]),
      ],
    );
    final wire = AutoConnect.wires(p.pages.single).single;
    final info =
        resolveWireRouteHoverInfo(
          resolver: ProjectResolver(p),
          sheet: p.pages.single,
          wireId: wire.id,
        )!;
    expect(info.label, contains('Spojovací roh ┌'));
    final cycleSheet = Sheet(
      id: 's',
      name: 'Cycle',
      number: '1',
      corners: const [
        ConnectionCorner(id: 'c1', position: Vec2(100, 100)),
        ConnectionCorner(
          id: 'c2',
          position: Vec2(200, 100),
          orientation: CornerOrientation.topRight,
        ),
        ConnectionCorner(
          id: 'c3',
          position: Vec2(200, 200),
          orientation: CornerOrientation.bottomRight,
        ),
        ConnectionCorner(
          id: 'c4',
          position: Vec2(100, 200),
          orientation: CornerOrientation.bottomLeft,
        ),
      ],
    );
    final cycle = EcadProject(id: 'cycle', name: 'Cycle', pages: [cycleSheet]);
    final edge = AutoConnect.wires(cycleSheet).first;
    final description =
        resolveWireRouteHoverInfo(
          resolver: ProjectResolver(cycle),
          sheet: cycleSheet,
          wireId: edge.id,
        )!;
    expect(description.label, contains('Spojovací roh'));
    expect(description.detail, contains('bez připojeného'));
  });
}
