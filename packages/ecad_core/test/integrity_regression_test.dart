// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

void main() {
  for (final oldMarker in [false, true]) {
    for (final newMarker in [false, true]) {
      test('rewiring in one batch follows the new owner and survives deletion '
          '(markers: $oldMarker -> $newMarker)', () {
        final parts = [
          for (final (id, x) in [('a', 100.0), ('b', 300.0), ('c', 500.0)])
            createBuiltinComponent(
              componentId: 'component_$id',
              deviceId: id,
              kind: DeviceKind.coil,
              designation: '-$id',
              position: Vec2(x, 200),
            ),
        ];
        final markers = [
          for (final (id, x) in [('ma', 100.0), ('mc', 500.0)])
            ContinuationMarker(
              id: id,
              linkId: 'link_$id',
              position: Vec2(x, 170),
              direction: PortSide.top,
            ),
        ];
        final wire = Wire(
          id: 'wire',
          from:
              oldMarker
                  ? const ContinuationRef(markerId: 'ma')
                  : const TerminalRef(deviceId: 'a', portId: 'a1'),
          to: const TerminalRef(deviceId: 'b', portId: 'a1'),
        );
        final project = EcadProject(
          id: 'project',
          name: 'Synthetic connections',
          components: parts.map((p) => p.component).toList(),
          continuationLinks: [
            for (final m in markers)
              ContinuationLink(id: m.linkId, label: m.id),
          ],
          pages: [
            Sheet(
              id: 'sheet',
              name: 'Sheet',
              number: '01',
              devices: parts.map((p) => p.device).toList(),
              continuations: markers,
              wires: [wire],
            ),
          ],
        );
        final rewired = wire.copyWith(
          from:
              newMarker
                  ? const ContinuationRef(markerId: 'mc')
                  : const TerminalRef(deviceId: 'c', portId: 'a1'),
          waypoints: [const Vec2(500, 100), const Vec2(300, 100)],
        );
        final commands = <EcadCommand>[
          if (oldMarker)
            UpdateContinuationMarker(
              'sheet',
              markers.first.copyWith(position: const Vec2(110, 170)),
            )
          else
            MoveDevices('sheet', {'a': const Vec2(110, 200)}),
          UpdateWire('sheet', rewired),
          if (newMarker)
            UpdateContinuationMarker(
              'sheet',
              markers.last.copyWith(position: const Vec2(540, 170)),
            )
          else
            MoveDevices('sheet', {'c': const Vec2(540, 200)}),
          if (oldMarker)
            const DeleteContinuationMarker('sheet', 'ma')
          else
            DeleteDevices('sheet', {'a'}),
        ];
        final engine = ProjectEngine(project)..execute(commands);
        final savedSheet = engine.project.pages.single;
        expect(savedSheet.wires, hasLength(1));
        final connected = savedSheet.wires.single;
        expect(connected.from, rewired.from);
        expect(connected.to, rewired.to);
        expect(connected.waypoints, isNot(rewired.waypoints));
        final sequential = ProjectEngine(project);
        for (final command in commands) {
          sequential.execute([command]);
        }
        expect(savedSheet.toJson(), sequential.project.pages.single.toJson());
        expect(engine.project.revision, 1);
        expect(engine.undo(), isTrue);
        expect(
          engine.project.pages.single.toJson(),
          project.pages.single.toJson(),
        );
        expect(engine.canUndo, isFalse);
        expect(engine.redo(), isTrue);
        expect(engine.project.pages.single.toJson(), savedSheet.toJson());
        engine.execute([
          if (newMarker)
            const DeleteContinuationMarker('sheet', 'mc')
          else
            DeleteDevices('sheet', {'c'}),
        ]);
        expect(engine.project.pages.single.wires, isEmpty);
      });
    }
  }

  test(
    'article report identifies each unassigned component without extra stock',
    () {
      final sheet = Sheet(
        id: 'bom',
        name: 'BOM',
        number: 'B1',
        type: SheetType.billOfMaterials,
        report: const BomTableSpec(kind: BomReportKind.articles),
      );
      final project = EcadProject(
        id: 'report',
        name: 'Synthetic BOM',
        pages: [sheet],
        components: [
          const Component(id: 'k1', designation: '-K1'),
          const Component(id: 'k2', designation: '-K2'),
          const Component(id: 'k3', designation: '-K3', description: 'Relay'),
          const Component(id: 'material', kind: ComponentKind.material),
        ],
      );
      final report = buildReport(project, sheet);
      expect(report.rows, hasLength(4));
      final names = {
        for (final row in report.rows) row.componentIds.single: row.cells[2],
      };
      expect(names, {
        'k1': '-K1',
        'k2': '-K2',
        'k3': '-K3 · Relay',
        'material': 'material',
      });
      for (final row in report.rows) {
        expect(row.cells.take(2), ['', '']);
        expect(row.cells.skip(3), ['ks', '1', '0', '0', '0', '1']);
      }
      expect(project.articles, isEmpty);
      expect(
        buildBom(project).articles.every((r) => r.article == null),
        isTrue,
      );
    },
  );
}
