import 'dart:convert';
import 'dart:typed_data';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/schematic_clipboard.dart';

import 'continuation_fixtures.dart';

SchematicFragment capture(EcadProject p, Set<String> ids) =>
    SchematicFragment.capture(
      project: p,
      sheet: p.pages.first,
      selectedIds: ids,
      sessionId: 'session',
      instanceId: 'instance',
      generation: 2,
    );
ClipboardPlacement prepare(
  SchematicFragment f,
  EcadProject p, {
  String session = 'session',
  int generation = 2,
}) => f.prepare(
  project: p,
  target: p.pages.first,
  sessionId: session,
  instanceId: 'instance',
  generation: generation,
);

void main() {
  test(
    'marker snapshot keeps same-session network; external wire stays outside',
    () {
      final p = continuationProject(sameSheet: 0);
      final fragment = capture(p, {'source'});
      final changed = ProjectEngine(p)..execute([
        UpdateContinuationMarker(
          p.pages.first.id,
          p.pages.first.continuations.single.copyWith(
            position: const Vec2(10, 10),
          ),
        ),
      ]);
      final placement = prepare(fragment, changed.project);
      expect(
        placement.preview.pages.single.continuations.single.position,
        const Vec2(1200, 800),
      );
      changed.execute(placement.commandsAt(const Vec2(600, 400)));
      final copy = changed.project.pages.first.continuations.last;
      expect(copy.id, isNot('source'));
      expect(copy.linkId, 'network');
      expect(copy.position, const Vec2(600, 400));
      expect(changed.project.pages.first.wires.length, 1);
      expect(
        changed.project.continuationLinks.length,
        p.continuationLinks.length,
      );
    },
  );

  test(
    'other session/generation never merges identical project, link IDs or labels',
    () {
      final p = continuationProject(sameSheet: 0);
      final f = capture(p, {'source'});
      for (final identity in [('other', 2), ('session', 3)]) {
        final engine = ProjectEngine(p);
        engine.execute(
          prepare(
            f,
            p,
            session: identity.$1,
            generation: identity.$2,
          ).commandsAt(Vec2.zero),
        );
        final copy = engine.project.pages.first.continuations.last;
        expect(copy.linkId, isNot('network'));
        expect(
          engine.project.continuationLinkById(copy.linkId)!.label,
          'SIGNAL (2)',
        );
      }
      final noSource = p.copyWith(
        continuationLinks: const [],
        pages: [
          p.pages.first.copyWith(continuations: const [], wires: const []),
        ],
      );
      final engine = ProjectEngine(noSource)
        ..execute(prepare(f, noSource).commandsAt(Vec2.zero));
      expect(
        engine.project.pages.first.continuations.single.linkId,
        isNot('network'),
      );
      expect(engine.project.continuationLinks.single.label, 'SIGNAL');
    },
  );

  test(
    'grouped occurrences clone physical piece once, ports, rotated geometry and manual route',
    () {
      final seed = createBuiltinComponent(
        componentId: 'piece',
        deviceId: 'first',
        kind: DeviceKind.breaker,
        designation: '-Q1',
        position: const Vec2(100, 100),
        articleId: 'article',
      );
      final context = StructureContext(functionPath: ['A']);
      final p = EcadProject(
        id: 'p',
        name: 'Synthetic',
        articles: const [
          Article(
            id: 'article',
            name: 'Generic breaker',
            unit: QuantityUnit.piece,
            note: 'omit note',
            sourceUrl: 'https://example.test/omit/path',
          ),
        ],
        components: [
          seed.component.copyWith(note: 'omit component note'),
          const Component(id: 'legacy', designation: '=A-Q1'),
        ],
        continuationLinks: const [
          ContinuationLink(id: 'link', label: 'SIGNAL'),
        ],
        pages: [
          Sheet(
            id: 's',
            name: 'Sheet',
            number: '1',
            structure: context,
            devices: [
              seed.device.copyWith(rotation: 90),
              seed.device.copyWith(
                id: 'second',
                position: const Vec2(300, 100),
              ),
            ],
            continuations: const [
              ContinuationMarker(
                id: 'marker',
                linkId: 'link',
                position: Vec2(400, 200),
              ),
            ],
            corners: const [
              ConnectionCorner(
                id: 'corner',
                position: Vec2(400, 100),
                orientation: CornerOrientation.bottomRight,
              ),
            ],
            graphics: [
              DrawingElement(
                id: 'graphic',
                kind: DrawingKind.text,
                position: const Vec2(110, 90),
                width: 60,
                height: 18,
                text: 'Generic annotation',
                rotation: 90,
              ),
            ],
            wires: [
              Wire(
                id: 'wire',
                from: const TerminalRef(deviceId: 'first', portId: 'out'),
                to: const CornerRef(cornerId: 'corner', portId: 'a'),
                waypoints: const [Vec2(180, 170), Vec2(390, 170)],
              ),
              Wire(
                id: 'link-wire',
                from: const CornerRef(cornerId: 'corner', portId: 'b'),
                to: const ContinuationRef(markerId: 'marker'),
              ),
            ],
          ),
        ],
      );
      final f = capture(p, {'first', 'second', 'corner', 'marker', 'graphic'});
      expect(f.encode(), isNot(contains('omit')));
      final paste = prepare(f, p);
      final engine = ProjectEngine(p)..execute(
        paste.commandsAt(f.anchor + const Vec2(100, 200)),
        label: 'paste',
      );
      final result = engine.project;
      final copied = result.components.last;
      expect(result.components.length, 3);
      expect(copied.designation, '=A-Q2');
      expect(result.articles.length, 1);
      expect(
        copied.electrical!.terminals
            .map((t) => t.id)
            .toSet()
            .intersection(
              seed.component.electrical!.terminals.map((t) => t.id).toSet(),
            ),
        isEmpty,
      );
      expect(
        copied.electrical!.functions.single.id,
        isNot(seed.component.electrical!.functions.single.id),
      );
      expect(
        result.pages.first.devices.skip(2).map((d) => d.componentId).toSet(),
        {copied.id},
      );
      expect(result.pages.first.devices[2].rotation, 90);
      expect(result.pages.first.devices[3].position, const Vec2(400, 300));
      expect(result.pages.first.wires[2].waypoints, [
        const Vec2(280, 370),
        const Vec2(490, 370),
      ]);
      expect(
        result.pages.first.wires[2].from.ownerId,
        result.pages.first.devices[2].id,
      );
      expect(result.pages.first.graphics.last.rotation, 90);
      expect(result.pages.first.graphics.last.kind, DrawingKind.text);
      expect(
        buildBom(result).articles
            .firstWhere((r) => r.articleId == 'article')
            .installed
            .knownBaseUnits,
        2,
      );
      expect(engine.undo(), isTrue);
      expect(engine.project.pages.first.devices.length, 2);
      expect(engine.project.components.length, 2);
      expect(engine.canUndo, isFalse);
    },
  );

  test(
    'cross-project article collision imports exact copied article under new identity',
    () {
      final seed = createBuiltinComponent(
        componentId: 'c',
        deviceId: 'd',
        kind: DeviceKind.supply,
        designation: '-G1',
        position: Vec2.zero,
        articleId: 'a',
      );
      final p = EcadProject(
        id: 'p',
        name: 'p',
        components: [seed.component],
        articles: const [
          Article(id: 'a', name: 'Original part', unit: QuantityUnit.piece),
        ],
        pages: [
          Sheet(id: 's', name: 's', number: '1', devices: [seed.device]),
        ],
      );
      final f = capture(p, {'d'});
      final other = p.copyWith(
        articles: [p.articles.single.copyWith(name: 'Unrelated part')],
      );
      final engine = ProjectEngine(other)..execute(
        prepare(f, other, session: 'other').commandsAt(const Vec2(200, 200)),
      );
      expect(engine.project.components.last.articleId, isNot('a'));
      expect(
        engine.project
            .articleById(engine.project.components.last.articleId!)!
            .name,
        'Original part',
      );
    },
  );

  test(
    'unselected procurement dependency and mounting selection fail concretely',
    () {
      final p = continuationProject();
      final included = p.copyWith(
        components: [
          p.components.single.copyWith(
            procurement: const Procurement(
              source: ProcurementSource.included,
              includedInComponentId: 'parent',
            ),
          ),
          const Component(id: 'parent', designation: '-A1'),
        ],
      );
      expect(() => capture(included, {'symbol'}), throwsFormatException);
      expect(
        () => SchematicFragment.capture(
          project: p,
          sheet: p.pages.first.copyWith(type: SheetType.cabinetLayout),
          selectedIds: {'source'},
          sessionId: 's',
          instanceId: 'instance',
          generation: 0,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'terminal numbering avoids full legacy collision and keeps connection points',
    () {
      final target = StructureContext(functionPath: ['A']);
      final source = StructureContext(functionPath: ['B']);
      final seed = createTerminalComponent(
        componentId: 'c',
        deviceId: 'd',
        stripId: 'source-strip',
        position: const Vec2(100, 100),
        sides: {PortSide.left, PortSide.right},
      );
      final p = EcadProject(
        id: 'p',
        name: 'p',
        components: [
          seed.component,
          const Component(id: 'legacy', designation: '=A-X1:1'),
        ],
        terminalStrips: [
          TerminalStrip(
            id: 'source-strip',
            reference: ComponentReference(
              context: source,
              localDesignation: 'X1',
            ),
          ),
          TerminalStrip(
            id: 'target-strip',
            reference: ComponentReference(
              context: target,
              localDesignation: 'X1',
            ),
          ),
        ],
        pages: [
          Sheet(
            id: 's',
            name: 's',
            number: '1',
            structure: target,
            devices: [seed.device],
          ),
        ],
      );
      final engine = ProjectEngine(p)..execute(
        prepare(capture(p, {'d'}), p).commandsAt(const Vec2(200, 100)),
      );
      final copy = engine.project.components.last;
      expect(ProjectResolver(engine.project).fullDesignation(copy), '=A-X1:2');
      expect(
        copy.terminal!.connectionPoints,
        seed.component.terminal!.connectionPoints,
      );
      expect(
        (engine.project.pages.first.devices.last.symbol as TerminalSymbolSpec)
            .sides,
        {PortSide.left, PortSide.right},
      );
    },
  );

  test(
    'custom port blocks preserve functions and internal procurement points to the new parent',
    () {
      final a = createBuiltinComponent(
        componentId: 'parent',
        deviceId: 'parent-view',
        kind: DeviceKind.supply,
        designation: '-G1',
        position: const Vec2(100, 100),
      );
      final b = createBuiltinComponent(
        componentId: 'child',
        deviceId: 'child-view',
        kind: DeviceKind.supply,
        designation: '-G2',
        position: const Vec2(300, 100),
      );
      final terminalId = b.component.electrical!.terminals.single.id;
      final block = PortBlockSpec(
        width: 80,
        height: 30,
        ports: [
          BlockPort(
            id: 'port',
            terminalId: terminalId,
            side: PortSide.right,
            fraction: 0.3,
          ),
        ],
      );
      final p = EcadProject(
        id: 'p',
        name: 'p',
        components: [
          a.component,
          b.component.copyWith(
            procurement: const Procurement(
              source: ProcurementSource.included,
              includedInComponentId: 'parent',
            ),
          ),
        ],
        pages: [
          Sheet(
            id: 's',
            name: 's',
            number: '1',
            devices: [
              a.device,
              b.device.copyWith(symbol: block, rotation: 270),
            ],
            wires: [
              Wire(
                id: 'w',
                from: const TerminalRef(deviceId: 'parent-view', portId: 'out'),
                to: const TerminalRef(deviceId: 'child-view', portId: 'port'),
              ),
            ],
          ),
        ],
      );
      final engine = ProjectEngine(p)..execute(
        prepare(
          capture(p, {'parent-view', 'child-view'}),
          p,
        ).commandsAt(const Vec2(200, 200)),
      );
      final clones = engine.project.components.skip(2).toList();
      expect(clones.last.procurement.includedInComponentId, clones.first.id);
      final device = engine.project.pages.first.devices.last;
      final symbol = device.symbol as PortBlockSpec;
      expect(symbol.width, 80);
      expect(symbol.height, 30);
      expect(symbol.ports.single.id, 'port');
      expect(
        symbol.ports.single.terminalId,
        clones.last.electrical!.terminals.single.id,
      );
      expect(symbol.ports.single.fraction, 0.3);
      expect(device.rotation, 270);
      expect(
        engine.project.pages.first.wires.last.to,
        TerminalRef(deviceId: device.id, portId: 'port'),
      );
    },
  );

  test(
    'recovered session and generation reused by another owner still import a fresh network',
    () {
      final p = continuationProject();
      final f = capture(p, {'source'});
      final placement = f.prepare(
        project: p,
        target: p.pages.first,
        sessionId: 'session',
        generation: 2,
        instanceId: 'new-runtime',
      );
      expect(
        placement.preview.pages.single.continuations.single.linkId,
        isNot('network'),
      );
    },
  );

  test(
    'small encoded data cannot import unbounded aggregate raster dimensions',
    () {
      final bytes = Uint8List(33)..setAll(0, [137, 80, 78, 71, 13, 10, 26, 10]);
      final header =
          ByteData.sublistView(bytes)
            ..setUint32(8, 13)
            ..setUint32(16, 4096)
            ..setUint32(20, 4096);
      header.buffer.asUint8List().setAll(12, [73, 72, 68, 82]);
      final p = EcadProject(
        id: 'p',
        name: 'p',
        pages: [
          Sheet(
            id: 's',
            name: 's',
            number: '1',
            graphics: [
              for (var i = 0; i < 2; i++)
                DrawingElement(
                  id: 'raster-$i',
                  kind: DrawingKind.image,
                  position: Vec2.zero,
                  width: 10,
                  height: 10,
                  imageData: base64Encode(bytes),
                ),
            ],
          ),
        ],
      );
      expect(() => capture(p, {'raster-0', 'raster-1'}), throwsFormatException);
    },
  );

  test(
    'strict format rejects oversized, deep, nonfinite, dangling and extraneous data',
    () {
      final f = capture(continuationProject(), {'source'});
      Map<String, dynamic> payload() =>
          jsonDecode(
                f.encode().substring(
                  SchematicFragment.begin.length,
                  f.encode().length - SchematicFragment.end.length,
                ),
              )
              as Map<String, dynamic>;
      String text(Map<String, dynamic> map) =>
          '${SchematicFragment.begin}${jsonEncode(map)}${SchematicFragment.end}';
      expect(
        () => SchematicFragment.decode('x' * (SchematicFragment.maxBytes + 1)),
        throwsFormatException,
      );
      expect(
        () => SchematicFragment.decode(
          '${SchematicFragment.begin}${'[' * 64}${']' * 64}${SchematicFragment.end}',
        ),
        throwsFormatException,
      );
      expect(
        () => SchematicFragment.decode('plain text'),
        throwsFormatException,
      );
      expect(
        () => SchematicFragment.decode(
          text(payload()..['sourcePath'] = '/arbitrary/path'),
        ),
        throwsA(isA<EcadException>()),
      );
      final missing = payload();
      missing['links'] = [];
      expect(
        () => SchematicFragment.decode(text(missing)),
        throwsA(isA<EcadException>()),
      );
      final nonfinite = text(payload()).replaceFirst('1200.0', '1e999');
      expect(
        () => SchematicFragment.decode(nonfinite),
        throwsA(isA<EcadException>()),
      );
      final huge = payload();
      huge['markers'] = List.filled(501, (huge['markers'] as List).single);
      expect(
        () => SchematicFragment.decode(text(huge)),
        throwsA(isA<EcadException>()),
      );
    },
  );
}
