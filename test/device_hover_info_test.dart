// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/device_hover_info.dart';

import 'device_hover_fixtures.dart';

DeviceHoverInfo? schematicInfo(EcadProject project) => resolveDeviceHoverInfo(
  resolver: ProjectResolver(project),
  sheetId: 'schematic',
  deviceId: 'opaque-device',
);

DeviceHoverInfo? mountingInfo(EcadProject project) => resolveMountingHoverInfo(
  resolver: ProjectResolver(project),
  sheetId: 'mounting',
  placementId: 'opaque-placement',
);

void main() {
  test(
    'full designation, function, article and resolved physical dimensions',
    () {
      final project = deviceHoverProject();
      final info = schematicInfo(project)!;
      expect(info.label, '=TEST+BOX-Q1');
      expect(
        info.detail,
        'Popis: Zkušební ochrana\nSymbol: Jistič\nFunkce: Ochrana motoru\n'
        'Artikl: Zkušební jistič\nVýrobce: Test výrobce\nModel: TEST-42\n'
        'Rozměry: š 60 × v 80 × h 30 mm',
      );
      expect(info.tooltip, isNot(contains('opaque')));
      expect(info.semanticsLabel, startsWith('Přístroj =TEST+BOX-Q1'));
      expect(identical(info.project, project), isTrue);
      final mounting = mountingInfo(project)!;
      expect(mounting.label, info.label);
      expect(mounting.detail, contains('Funkce: Ochrana motoru'));
      expect(mounting.detail, contains('Rozměry: š 60 × v 80 × h 30 mm'));
      expect(mounting.detail, isNot(contains('Symbol:')));
    },
  );

  test(
    'missing, blank and partial metadata never emits blank labels or IDs',
    () {
      final project = deviceHoverProject();
      final component = project.components.first.copyWith(
        reference: null,
        designation: ' \t ',
        description: '  ',
        electrical: null,
        articleId: 'opaque-missing',
        mountingSizeOverrideMm: const DimensionsMm(depth: 21.5),
      );
      final missing = project.copyWith(
        components: [component, project.components.last],
      );
      expect(
        schematicInfo(missing)!.tooltip,
        'Přístroj bez označení\nSymbol: Jistič\nRozměry: h 21.5 mm',
      );
      expect(
        mountingInfo(missing)!.tooltip,
        'Přístroj bez označení\nRozměry: h 21.5 mm',
      );
      final blank = missing.copyWith(
        articles: [
          const Article(
            id: 'opaque-missing',
            name: ' ',
            manufacturer: '\n',
            partNumber: '\t',
            unit: QuantityUnit.piece,
          ),
        ],
      );
      expect(schematicInfo(blank)!.tooltip, schematicInfo(missing)!.tooltip);
    },
  );

  test(
    'terminal designation follows the strip and reference occurrences are honest',
    () {
      final project = deviceHoverProject();
      final sheet = project.pages.first;
      final terminal = project.copyWith(
        terminalStrips: [
          TerminalStrip(
            id: 'opaque-strip',
            reference: ComponentReference(
              context: StructureContext(locationPath: ['CAB']),
              localDesignation: 'X5',
            ),
          ),
        ],
        components: [
          project.components.first.copyWith(
            terminal: TerminalAssignment(stripId: 'opaque-strip', number: '7'),
          ),
          project.components.last,
        ],
        pages: [
          sheet.copyWith(
            devices: [
              sheet.devices.first.copyWith(
                mode: OccurrenceMode.reference,
                symbol: TerminalSymbolSpec(terminalId: 'opaque-component-in'),
              ),
            ],
          ),
          project.pages.last,
        ],
      );
      final info = schematicInfo(terminal)!;
      expect(info.label, '+CAB-X5:7');
      expect(info.detail, contains('Symbol: Svorka'));
      expect(info.detail, contains('bez elektrického připojení'));
      expect(info.tooltip, isNot(contains('opaque')));
    },
  );

  test(
    'current snapshot and undo redo resolve fresh data for the same IDs',
    () {
      final project = deviceHoverProject();
      final engine = ProjectEngine(project);
      final before = schematicInfo(project)!;
      engine.execute([
        UpdateComponent(
          project.components.first.copyWith(description: 'Nový popis'),
        ),
      ]);
      expect(schematicInfo(engine.project)!.detail, contains('Nový popis'));
      expect(mountingInfo(engine.project)!.detail, contains('Nový popis'));
      expect(engine.undo(), isTrue);
      expect(schematicInfo(engine.project)!.tooltip, before.tooltip);
      expect(engine.redo(), isTrue);
      expect(schematicInfo(engine.project)!.detail, contains('Nový popis'));
      expect(schematicInfo(project)!.tooltip, before.tooltip);
    },
  );

  test('removed objects and unresolved component never return stale info', () {
    final project = deviceHoverProject();
    expect(schematicInfo(project.copyWith(components: [])), isNull);
    expect(mountingInfo(project.copyWith(components: [])), isNull);
    expect(schematicInfo(project.copyWith(pages: [])), isNull);
    expect(mountingInfo(project.copyWith(mountingLayouts: [])), isNull);
    expect(
      resolveDeviceHoverInfo(
        resolver: ProjectResolver(project),
        sheetId: 'schematic',
        deviceId: 'opaque-missing',
      ),
      isNull,
    );
    expect(
      resolveMountingHoverInfo(
        resolver: ProjectResolver(project),
        sheetId: 'mounting',
        placementId: 'opaque-missing',
      ),
      isNull,
    );
  });
}
