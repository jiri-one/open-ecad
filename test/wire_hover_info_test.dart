// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/wire_hover_info.dart';

const _sheetId = 'synthetic-sheet';
const _wireId = 'opaque-wire';
const _from = TerminalRef(deviceId: 'opaque-source-symbol', portId: 'out');
const _to = TerminalRef(deviceId: 'opaque-target-symbol', portId: 'in');

EcadProject _project() {
  Component component(String id, String designation, List<String> labels) =>
      Component(
        id: id,
        designation: designation,
        electrical: ElectricalModel(
          terminals: [
            for (var i = 0; i < labels.length; i++)
              ComponentTerminal(
                id: '$id-terminal-$i',
                designation: labels[i],
                signal: i == 1 ? 'TEST-SIGNAL' : '',
              ),
          ],
          functions: [
            ComponentFunction(
              id: '$id-function',
              name: 'Zkušební funkce',
              terminalIds: [
                for (var i = 0; i < labels.length; i++) '$id-terminal-$i',
              ],
            ),
          ],
        ),
      );
  Device device(String id, String componentId, Vec2 position) => Device(
    id: id,
    componentId: componentId,
    functionId: '$componentId-function',
    symbol: BuiltinSymbolSpec(
      kind: DeviceKind.contactNo,
      bindings: {
        'in': '$componentId-terminal-0',
        'out': '$componentId-terminal-1',
      },
    ),
    position: position,
  );
  return EcadProject(
    id: 'synthetic-project',
    name: 'Syntetický hover test',
    components: [
      component('opaque-component-a', '-K71', ['13', '14']),
      component('opaque-component-b', '-X82', ['3', '4']),
    ],
    pages: [
      Sheet(
        id: _sheetId,
        name: 'Zkušební list',
        number: '01',
        devices: [
          device(_from.deviceId, 'opaque-component-a', const Vec2(180, 180)),
          device(_to.deviceId, 'opaque-component-b', const Vec2(180, 400)),
        ],
        wires: [Wire(id: _wireId, from: _from, to: _to)],
      ),
    ],
  );
}

WireHoverInfo _info(EcadProject project) =>
    resolveWireHoverInfo(
      resolver: ProjectResolver(project),
      sheetId: _sheetId,
      wireId: _wireId,
    )!;

EcadProject _withContinuation({
  bool withLink = true,
  String label = 'TEST-LINK',
  bool withTargets = true,
}) {
  final project = _project();
  return project.copyWith(
    continuationLinks: [
      if (withLink) ContinuationLink(id: 'opaque-link', label: label),
    ],
    pages: [
      project.pages.single.copyWith(
        continuations: const [
          ContinuationMarker(
            id: 'opaque-marker-source',
            linkId: 'opaque-link',
            position: Vec2(250, 220),
          ),
        ],
        wires: [
          Wire(
            id: _wireId,
            from: _from,
            to: const ContinuationRef(markerId: 'opaque-marker-source'),
          ),
        ],
      ),
      if (withTargets) ...[
        Sheet(
          id: 'opaque-sheet-a',
          number: '02',
          name: 'Zkušební cíl A',
          continuations: const [
            ContinuationMarker(
              id: 'opaque-marker-a',
              linkId: 'opaque-link',
              position: Vec2(180, 120),
            ),
            ContinuationMarker(
              id: 'opaque-marker-a2',
              linkId: 'opaque-link',
              position: Vec2(280, 120),
            ),
          ],
        ),
        Sheet(
          id: 'opaque-sheet-b',
          number: '03',
          name: 'Zkušební cíl B',
          continuations: const [
            ContinuationMarker(
              id: 'opaque-marker-b',
              linkId: 'opaque-link',
              position: Vec2(180, 120),
            ),
          ],
        ),
      ],
    ],
  );
}

void main() {
  test(
    'uses physical terminal designations instead of symbol ports or IDs',
    () {
      final project = _project();
      final info = _info(project);
      expect(info.label, '-K71:14 → -X82:3');
      expect(info.from.detail, contains('Funkce: Zkušební funkce'));
      expect(info.from.detail, contains('Signál: TEST-SIGNAL'));
      expect(info.tooltip, isNot(contains('opaque')));
      expect(info.tooltip, isNot(contains(':out')));
      expect(info.semanticsLabel, startsWith('Spoj z -K71:14 do -X82:3.'));
      expect(identical(info.project, project), isTrue);
    },
  );

  test(
    'rename, terminal edits, undo and redo resolve the current snapshot',
    () {
      final engine = ProjectEngine(_project());
      final original = _info(engine.project);
      final component = engine.project.components.first;
      engine.execute([
        UpdateComponent(
          component.copyWith(
            designation: '-K72',
            electrical: component.electrical!.copyWith(
              terminals: [
                component.electrical!.terminals.first,
                component.electrical!.terminals.last.copyWith(
                  designation: '24',
                  signal: 'TEST-NEW',
                ),
              ],
            ),
          ),
        ),
      ]);
      final edited = _info(engine.project);
      expect(edited.label, '-K72:24 → -X82:3');
      expect(edited.detail, contains('TEST-NEW'));
      expect(original.label, '-K71:14 → -X82:3');
      expect(identical(edited.project, original.project), isFalse);
      expect(engine.undo(), isTrue);
      final undone = _info(engine.project);
      expect(undone.label, original.label);
      expect(undone.detail, original.detail);
      expect(identical(undone.project, edited.project), isFalse);
      expect(engine.redo(), isTrue);
      expect(_info(engine.project).label, edited.label);
    },
  );

  test(
    'same document IDs and revision do not reuse data from another snapshot',
    () {
      final a = _project();
      final b = a.copyWith(
        components: [
          a.components.first.copyWith(designation: '-K99'),
          a.components.last,
        ],
      );
      expect(b.id, a.id);
      expect(b.revision, a.revision);
      expect(_info(a).from.label, '-K71:14');
      expect(_info(b).from.label, '-K99:14');
      expect(_info(a).from.label, '-K71:14');
    },
  );

  test('rebinding a symbol port reads the newly mapped real terminal', () {
    final project = _project();
    final sheet = project.pages.single;
    final rebound = project.copyWith(
      pages: [
        sheet.copyWith(
          devices: [
            sheet.devices.first.copyWith(
              symbol: BuiltinSymbolSpec(
                kind: DeviceKind.contactNo,
                bindings: {'out': 'opaque-component-a-terminal-0'},
              ),
            ),
            sheet.devices.last,
          ],
        ),
      ],
    );
    expect(_info(rebound).from.label, '-K71:13');
  });

  test(
    'continuation has its name and distinct target sheet names and numbers',
    () {
      final info = _info(_withContinuation());
      expect(info.to.label, 'Pokračování TEST-LINK');
      expect(
        info.to.detail,
        'Cílové listy: 02 — Zkušební cíl A, 03 — Zkušební cíl B',
      );
      expect(info.tooltip, isNot(contains('opaque')));
      expect(info.tooltip, isNot(contains('unknown')));
    },
  );

  test('continuation missing link, title or target is described honestly', () {
    final missing = _info(
      _withContinuation(withLink: false, withTargets: false),
    );
    expect(missing.to.label, 'Pokračování bez názvu');
    expect(missing.to.detail, contains('Definice pokračování chybí'));
    expect(missing.to.detail, contains('Cílový list není určen'));
    final unnamed = _info(_withContinuation(label: ' \n ', withTargets: false));
    expect(unnamed.to.label, 'Pokračování bez názvu');
    expect(unnamed.to.detail, 'Cílový list není určen');
    final oneTarget = _withContinuation();
    expect(
      _info(
        oneTarget.copyWith(pages: oneTarget.pages.take(2).toList()),
      ).to.detail,
      'Cílový list: 02 — Zkušební cíl A',
    );
  });

  test('missing sheet name and number never expose the sheet ID', () {
    final project = _withContinuation();
    final info = _info(
      project.copyWith(
        pages: [
          project.pages.first,
          project.pages[1].copyWith(number: ' ', name: ''),
        ],
      ),
    );
    expect(info.to.detail, 'Cílový list: bez čísla — bez názvu');
    expect(info.tooltip, isNot(contains('opaque')));
  });

  test('missing designation and terminal label have readable fallbacks', () {
    final project = _project();
    final component = project.components.first;
    final info = _info(
      project.copyWith(
        components: [
          component.copyWith(
            designation: ' \t ',
            description: 'Zkušební\nkontakt',
            electrical: component.electrical!.copyWith(
              terminals: [
                component.electrical!.terminals.first,
                component.electrical!.terminals.last.copyWith(designation: ''),
              ],
            ),
          ),
          project.components.last,
        ],
      ),
    );
    expect(info.from.label, 'Přístroj bez označení:vývod bez označení');
    expect(info.from.detail, contains('Popis: Zkušební kontakt'));
    expect(info.tooltip, isNot(contains('opaque')));
  });

  test('dangling device, component, terminal and marker are not ID labels', () {
    final project = _project();
    final sheet = project.pages.single;
    WireHoverEndpointInfo describe(
      EcadProject project,
      WireEndpoint endpoint,
    ) => describeWireHoverEndpoint(
      resolver: ProjectResolver(project),
      sheet: project.pages.single,
      endpoint: endpoint,
    );
    expect(
      describe(
        project,
        const TerminalRef(deviceId: 'missing', portId: 'in'),
      ).label,
      'Chybějící přístroj',
    );
    expect(
      describe(project.copyWith(components: []), _from).label,
      'Chybějící komponenta',
    );
    expect(
      describe(
        project,
        TerminalRef(deviceId: _from.deviceId, portId: 'missing'),
      ).label,
      '-K71:vývod nenalezen',
    );
    expect(
      describe(project, const ContinuationRef(markerId: 'missing')).label,
      'Chybějící pokračování',
    );
    final unbound = project.copyWith(
      pages: [
        sheet.copyWith(
          devices: [
            sheet.devices.first.copyWith(
              symbol: BuiltinSymbolSpec(kind: DeviceKind.contactNo),
            ),
            sheet.devices.last,
          ],
        ),
      ],
    );
    expect(_info(unbound).from.label, '-K71:vývod nenalezen');
  });

  test('a reference occurrence does not claim an electrical connection', () {
    final project = _project();
    final sheet = project.pages.single;
    final reference = project.copyWith(
      pages: [
        sheet.copyWith(
          devices: [
            sheet.devices.first.copyWith(mode: OccurrenceMode.reference),
            sheet.devices.last,
          ],
        ),
      ],
    );
    expect(_info(reference).from.label, '-K71:14');
    expect(
      _info(reference).from.detail,
      contains('bez elektrického připojení'),
    );
  });

  test('removed wire or sheet returns no stale information', () {
    final project = _project();
    expect(
      resolveWireHoverInfo(
        resolver: ProjectResolver(project),
        sheetId: _sheetId,
        wireId: 'missing',
      ),
      isNull,
    );
    expect(
      resolveWireHoverInfo(
        resolver: ProjectResolver(project),
        sheetId: 'missing',
        wireId: _wireId,
      ),
      isNull,
    );
  });

  test(
    'endpoint adapter receives current topology and can delegate a chain end',
    () {
      final project = _project();
      final resolver = ProjectResolver(project);
      final seen = <WireEndpoint>[];
      final info =
          resolveWireHoverInfo(
            resolver: resolver,
            sheetId: _sheetId,
            wireId: _wireId,
            endpointResolver: ({
              required resolver,
              required sheet,
              required wire,
              required endpoint,
            }) {
              expect(identical(resolver.project, project), isTrue);
              expect(identical(sheet, project.pages.single), isTrue);
              expect(identical(wire, sheet.wires.single), isTrue);
              seen.add(endpoint);
              if (endpoint == _to) return null;
              final end = describeWireHoverEndpoint(
                resolver: resolver,
                sheet: sheet,
                endpoint: _to,
              );
              return WireHoverEndpointInfo(
                label: end.label,
                detail: 'Přes spojovací roh',
              );
            },
          )!;
      expect(seen, [_from, _to]);
      expect(info.from.label, '-X82:3');
      expect(info.from.detail, 'Přes spojovací roh');
      expect(info.to.label, '-X82:3');
      expect(info.to.detail, contains('Zkušební funkce'));
    },
  );

  test(
    'derived wire adapter uses the current snapshot without owning autoconnect',
    () {
      final original = _project();
      final project = original.copyWith(
        pages: [original.pages.single.copyWith(wires: [])],
      );
      final resolver = ProjectResolver(project);
      final derived = Wire(id: 'derived-wire', from: _from, to: _to);
      var endpointCalls = 0;
      final info =
          resolveWireHoverInfo(
            resolver: resolver,
            sheetId: _sheetId,
            wireId: derived.id,
            wireResolver: ({
              required resolver,
              required sheet,
              required wireId,
            }) {
              expect(identical(resolver.project, project), isTrue);
              expect(identical(sheet, project.pages.single), isTrue);
              expect(wireId, derived.id);
              return derived;
            },
            endpointResolver: ({
              required resolver,
              required sheet,
              required wire,
              required endpoint,
            }) {
              expect(identical(wire, derived), isTrue);
              endpointCalls++;
              return null;
            },
          )!;
      expect(info.label, '-K71:14 → -X82:3');
      expect(info.wireId, derived.id);
      expect(endpointCalls, 2);
      expect(
        resolveWireHoverInfo(
          resolver: resolver,
          sheetId: _sheetId,
          wireId: derived.id,
        ),
        isNull,
      );
      expect(
        resolveWireHoverInfo(
          resolver: resolver,
          sheetId: _sheetId,
          wireId: 'other-id',
          wireResolver:
              ({required resolver, required sheet, required wireId}) => derived,
        ),
        isNull,
      );
    },
  );
}
