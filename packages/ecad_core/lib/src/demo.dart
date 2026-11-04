// SPDX-License-Identifier: GPL-3.0-or-later
import 'model.dart';

abstract final class DemoProject {
  static EcadProject create() => EcadProject(
    id: 'project_demo',
    name: 'Ukázka · jeden kus, více zobrazení',
    description: 'Syntetická ukázka editace; nejde o realizační dokumentaci.',
    articles: const [
      Article(
        id: 'article_relay',
        name: 'Ukázkové relé',
        manufacturer: 'Demo Works',
        partNumber: 'DEMO-1',
        unit: QuantityUnit.piece,
        specification: 'Ukázková funkce',
        dimensionsMm: DimensionsMm(width: 48, height: 60, depth: 30),
      ),
      Article(
        id: 'article_material',
        name: 'Ukázkový metrážový materiál',
        unit: QuantityUnit.metre,
      ),
    ],
    components: [
      Component(
        id: 'component_relay',
        designation: '-K1',
        articleId: 'article_relay',
        electrical: ElectricalModel(
          terminals: const [
            ComponentTerminal(id: 'terminal_a1', designation: 'A1'),
            ComponentTerminal(id: 'terminal_a2', designation: 'A2'),
            ComponentTerminal(id: 'terminal_13', designation: '13'),
            ComponentTerminal(id: 'terminal_14', designation: '14'),
          ],
          functions: [
            ComponentFunction(
              id: 'function_coil',
              name: 'Cívka',
              terminalIds: ['terminal_a1', 'terminal_a2'],
            ),
            ComponentFunction(
              id: 'function_contact',
              name: 'Kontakt',
              terminalIds: ['terminal_13', 'terminal_14'],
            ),
          ],
        ),
      ),
      const Component(
        id: 'material_run',
        kind: ComponentKind.material,
        articleId: 'article_material',
        description: 'Souhrnná délka',
        quantity: Quantity.millimetres(2750),
      ),
      const Component(
        id: 'material_spare',
        kind: ComponentKind.material,
        articleId: 'article_material',
        quantity: Quantity.millimetres(500),
        usage: ComponentUsage.spare,
        procurement: Procurement(source: ProcurementSource.available),
      ),
      const Component(
        id: 'material_unknown',
        kind: ComponentKind.material,
        description: 'Dosud neurčený drobný materiál',
        quantity: Quantity.pieces(null),
      ),
    ],
    continuationLinks: const [
      ContinuationLink(id: 'link_signal', label: 'SIGNAL-A'),
      ContinuationLink(id: 'link_earth', label: 'PE'),
    ],
    mountingLayouts: [
      MountingLayout(
        id: 'layout_demo',
        name: 'Ukázková montážní plocha',
        widthMm: 240,
        heightMm: 160,
        placements: const [
          MountingPlacement(
            id: 'placement_relay',
            componentId: 'component_relay',
            centerMm: Vec2(65, 55),
          ),
        ],
      ),
    ],
    pages: [
      Sheet(
        id: 'sheet_control',
        name: 'Cívka',
        number: '01',
        devices: [
          Device(
            id: 'dev_coil',
            componentId: 'component_relay',
            functionId: 'function_coil',
            symbol: BuiltinSymbolSpec(
              kind: DeviceKind.coil,
              bindings: {'a1': 'terminal_a1', 'a2': 'terminal_a2'},
            ),
            position: const Vec2(300, 250),
          ),
        ],
        continuations: const [
          ContinuationMarker(
            id: 'marker_a',
            linkId: 'link_signal',
            position: Vec2(300, 130),
            direction: PortSide.bottom,
          ),
          ContinuationMarker(
            id: 'marker_pe',
            linkId: 'link_earth',
            position: Vec2(700, 430),
            glyph: ContinuationGlyph.earth,
            direction: PortSide.top,
          ),
        ],
        wires: [
          Wire(
            id: 'wire_coil',
            from: const ContinuationRef(markerId: 'marker_a'),
            to: const TerminalRef(deviceId: 'dev_coil', portId: 'a1'),
          ),
        ],
      ),
      Sheet(
        id: 'sheet_contact',
        name: 'Kontakt a opakovaný pohled',
        number: '02',
        devices: [
          Device(
            id: 'dev_contact',
            componentId: 'component_relay',
            functionId: 'function_contact',
            symbol: BuiltinSymbolSpec(
              kind: DeviceKind.contactNo,
              bindings: {'in': 'terminal_13', 'out': 'terminal_14'},
            ),
            position: const Vec2(300, 250),
          ),
          Device(
            id: 'dev_reference',
            componentId: 'component_relay',
            functionId: 'function_coil',
            mode: OccurrenceMode.reference,
            symbol: BuiltinSymbolSpec(
              kind: DeviceKind.coil,
              bindings: {'a1': 'terminal_a1', 'a2': 'terminal_a2'},
            ),
            position: const Vec2(600, 250),
          ),
        ],
        continuations: const [
          ContinuationMarker(
            id: 'marker_b',
            linkId: 'link_signal',
            position: Vec2(300, 130),
            direction: PortSide.bottom,
          ),
        ],
        wires: [
          Wire(
            id: 'wire_contact',
            from: const ContinuationRef(markerId: 'marker_b'),
            to: const TerminalRef(deviceId: 'dev_contact', portId: 'in'),
          ),
        ],
      ),
      Sheet(
        id: 'sheet_mounting',
        name: 'Výstavba',
        number: '03',
        type: SheetType.cabinetLayout,
        mountingView: const MountingView(
          layoutId: 'layout_demo',
          viewport: RectUnits(x: 80, y: 80, width: 900, height: 530),
          scaleDenominator: 2,
        ),
      ),
      Sheet(
        id: 'sheet_bom',
        name: 'Kusovník',
        number: 'B01',
        type: SheetType.billOfMaterials,
        report: const BomTableSpec(
          kind: BomReportKind.articles,
          title: 'Materiálový přehled',
        ),
      ),
      Sheet(
        id: 'sheet_components',
        name: 'Komponenty',
        number: 'C01',
        type: SheetType.billOfMaterials,
        report: const BomTableSpec(
          kind: BomReportKind.components,
          title: 'Seznam komponent',
        ),
      ),
    ],
  );
}
