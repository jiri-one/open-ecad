import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

void main() {
  final seed = createBuiltinComponent(
    componentId: 'device',
    deviceId: 'main',
    kind: DeviceKind.coil,
    designation: '-K1',
    position: const Vec2(200, 200),
  );
  EcadProject project(
    List<Device> devices, {
    SheetType type = SheetType.multiLine,
  }) => EcadProject(
    id: 'project',
    name: 'Navigation',
    components: [seed.component],
    pages: [
      Sheet(
        id: 'sheet',
        name: 'Schematic',
        number: '1',
        type: type,
        devices: devices,
      ),
    ],
  );

  test(
    'mounting resolves an explicit main instead of an earlier auxiliary',
    () {
      final auxiliary = seed.device.copyWith(id: 'auxiliary');
      final main = seed.device.copyWith(isMainFunction: true);
      final resolver = ProjectResolver(project([auxiliary, main]));
      expect(resolver.schematicOccurrence('device')!.device.id, 'main');
      expect(resolver.schematicOccurrence('missing'), isNull);
    },
  );
  test('an explicitly designated reference-mode main remains the main', () {
    final resolver = ProjectResolver(
      project([
        seed.device,
        seed.device.copyWith(
          id: 'designated',
          mode: OccurrenceMode.reference,
          isMainFunction: true,
        ),
      ]),
    );
    expect(resolver.schematicOccurrence('device')!.device.id, 'designated');
  });
  test('one wiring occurrence is safe without a main flag', () {
    final resolver = ProjectResolver(
      project([
        seed.device,
        seed.device.copyWith(id: 'reference', mode: OccurrenceMode.reference),
      ]),
    );
    expect(resolver.schematicOccurrence('device')!.device.id, 'main');
  });
  test('auxiliary-only choices and multiple explicit mains are declined', () {
    for (final devices in [
      [seed.device, seed.device.copyWith(id: 'auxiliary')],
      [seed.device.copyWith(mode: OccurrenceMode.reference)],
      [
        seed.device.copyWith(isMainFunction: true),
        seed.device.copyWith(id: 'other', isMainFunction: true),
      ],
    ]) {
      expect(
        ProjectResolver(project(devices)).schematicOccurrence('device'),
        isNull,
      );
    }
  });
  for (final type in [
    SheetType.form,
    SheetType.cabinetLayout,
    SheetType.billOfMaterials,
  ]) {
    test('a main on $type does not masquerade as a schematic destination', () {
      expect(
        ProjectResolver(
          project([seed.device.copyWith(isMainFunction: true)], type: type),
        ).schematicOccurrence('device'),
        isNull,
      );
    });
  }
  test(
    'terminal lookup uses exact component and electrical terminal identities',
    () {
      final first = createTerminalComponent(
        componentId: 'terminal-1',
        deviceId: 'first',
        stripId: 'strip',
        number: '1',
        position: const Vec2(100, 100),
      );
      final second = createTerminalComponent(
        componentId: 'terminal-2',
        deviceId: 'second',
        stripId: 'strip',
        number: '2',
        position: const Vec2(300, 100),
      );
      final resolver = ProjectResolver(
        EcadProject(
          id: 'project',
          name: 'Terminals',
          components: [first.component, second.component],
          terminalStrips: [
            TerminalStrip(
              id: 'strip',
              reference: ComponentReference(localDesignation: 'X1'),
            ),
          ],
          pages: [
            Sheet(
              id: 'first-sheet',
              name: 'First',
              number: '1',
              devices: [first.device],
            ),
            Sheet(
              id: 'second-sheet',
              name: 'Second',
              number: '2',
              devices: [second.device],
            ),
          ],
        ),
      );
      final pin = second.component.electrical!.terminals.single.id;
      final target =
          resolver.schematicOccurrence('terminal-2', terminalId: pin)!;
      expect(target.sheet.id, 'second-sheet');
      expect(target.device.id, 'second');
      expect(
        resolver.schematicOccurrence('terminal-1', terminalId: pin),
        isNull,
      );
      expect(
        resolver.schematicOccurrence('terminal-2', terminalId: 'missing'),
        isNull,
      );
      expect(resolver.schematicOccurrence('strip'), isNull);
    },
  );
}
