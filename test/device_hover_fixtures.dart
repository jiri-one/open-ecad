// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';

EcadProject deviceHoverProject() {
  Component component(String id, String designation) => Component(
    id: id,
    reference: ComponentReference(
      context: StructureContext(functionPath: ['TEST'], locationPath: ['BOX']),
      localDesignation: designation,
    ),
    description: 'Zkušební ochrana',
    articleId: 'opaque-article',
    mountingSizeOverrideMm: const DimensionsMm(width: 60),
    electrical: ElectricalModel(
      terminals: [
        ComponentTerminal(id: '$id-in', designation: '1'),
        ComponentTerminal(id: '$id-out', designation: '2'),
      ],
      functions: [
        ComponentFunction(
          id: '$id-function',
          name: 'Ochrana motoru',
          terminalIds: ['$id-in', '$id-out'],
        ),
      ],
    ),
  );
  Device device(String id, String componentId, Vec2 position) => Device(
    id: id,
    componentId: componentId,
    functionId: '$componentId-function',
    symbol: BuiltinSymbolSpec(
      kind: DeviceKind.breaker,
      bindings: {'in': '$componentId-in', 'out': '$componentId-out'},
    ),
    position: position,
  );
  return EcadProject(
    id: 'opaque-project',
    name: 'Synthetic hover fixture',
    components: [
      component('opaque-component', 'Q1'),
      component('opaque-target', 'Q2'),
    ],
    articles: const [
      Article(
        id: 'opaque-article',
        name: 'Zkušební jistič',
        unit: QuantityUnit.piece,
        manufacturer: 'Test výrobce',
        partNumber: 'TEST-42',
        dimensionsMm: DimensionsMm(width: 50, height: 80, depth: 30),
      ),
    ],
    mountingLayouts: [
      MountingLayout(
        id: 'opaque-layout',
        name: 'Zkušební skříň',
        widthMm: 300,
        heightMm: 200,
        placements: const [
          MountingPlacement(
            id: 'opaque-placement',
            componentId: 'opaque-component',
            centerMm: Vec2(150, 110),
          ),
        ],
      ),
    ],
    pages: [
      Sheet(
        id: 'schematic',
        name: 'Test schematic',
        number: '1',
        devices: [
          device('opaque-device', 'opaque-component', const Vec2(400, 300)),
          device('opaque-second', 'opaque-target', const Vec2(400, 520)),
        ],
        wires: [
          Wire(
            id: 'opaque-wire',
            from: const TerminalRef(deviceId: 'opaque-device', portId: 'out'),
            to: const TerminalRef(deviceId: 'opaque-second', portId: 'in'),
          ),
        ],
      ),
      Sheet(
        id: 'mounting',
        name: 'Test mounting',
        number: '2',
        type: SheetType.cabinetLayout,
        mountingView: const MountingView(
          layoutId: 'opaque-layout',
          viewport: RectUnits(x: 40, y: 80, width: 950, height: 600),
        ),
      ),
    ],
  );
}
