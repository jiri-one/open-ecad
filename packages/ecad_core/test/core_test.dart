// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

Matcher errorCode(String code) =>
    isA<EcadException>().having((e) => e.code, 'code', code);
EcadProject roundTrip(EcadProject p) =>
    EcadProject.fromJson(jsonDecode(jsonEncode(p.toJson())));
Map<String, Object?> withoutRevision(EcadProject p) =>
    p.toJson()..remove('revision');

void main() {
  test('large totals stay exact beyond the per-item quantity limit', () {
    final p = EcadProject(
      id: 'p',
      name: 'P',
      articles: const [
        Article(id: 'a', name: 'Synthetic material', unit: QuantityUnit.metre),
      ],
      components: [
        for (var i = 0; i < 3; i++)
          Component(
            id: 'c$i',
            kind: ComponentKind.material,
            articleId: 'a',
            quantity: const Quantity.millimetres(Quantity.maxBaseUnits),
          ),
      ],
      pages: [Sheet(id: 's', name: 'S', number: '1')],
    );
    final row = buildBom(p).articles.single;
    expect(row.requiredTotal.knownBaseUnits, 300000000000);
    expect(row.requiredTotal.display(QuantityUnit.metre), '300000000');
    expect(
      () => const Quantity.millimetres(-500).toJson(),
      throwsA(errorCode('invalid_quantity')),
    );
  });

  test(
    'used article units require explicit reassignment to another article',
    () {
      final p = DemoProject.create();
      final engine = ProjectEngine(p);
      expect(
        () => engine.execute([
          UpdateArticle(p.articles[1].copyWith(unit: QuantityUnit.piece)),
          ...p.components
              .skip(1)
              .take(2)
              .map(
                (c) => UpdateComponent(
                  c.copyWith(quantity: const Quantity.pieces(1)),
                ),
              ),
        ]),
        throwsA(errorCode('article_unit_in_use')),
      );
      expect(engine.project, same(p));
    },
  );

  test(
    'global terminal and port budgets are checked before model allocation',
    () {
      final p = DemoProject.create();
      final raw = p.toJson();
      final c = p.components.first.toJson();
      final terminals = List<Object?>.filled(256, {
        'id': 't',
        'designation': 'T',
      });
      final oversized = List<Object?>.generate(
        391,
        (i) => {
          ...c,
          'electrical': {'terminals': terminals, 'functions': <Object?>[]},
        },
      );
      expect(
        () => EcadProject.fromJson({...raw, 'components': oversized}),
        throwsA(errorCode('limit_exceeded')),
      );
      final d = p.pages.first.devices.first.toJson();
      final ports = List<Object?>.filled(256, {
        'id': 'p',
        'terminalId': 't',
        'side': 'left',
        'fraction': .5,
      });
      expect(
        () => EcadProject.fromJson({
          ...raw,
          'pages': [
            {
              ...p.pages.first.toJson(),
              'devices': List<Object?>.filled(391, {
                ...d,
                'symbol': {
                  'type': 'block',
                  'width': 100,
                  'height': 100,
                  'ports': ports,
                },
              }),
            },
          ],
        }),
        throwsA(errorCode('limit_exceeded')),
      );
      expect(
        () => BuiltinSymbolSpec.fromJson({
          'type': 'block',
          'kind': 'coil',
          'bindings': <String, String>{},
        }),
        throwsA(errorCode('invalid_schema')),
      );
    },
  );

  test('multiple wiring views share only the same physical terminal', () {
    final p = DemoProject.create();
    final first = p.pages.first;
    final duplicate = first.devices.single.copyWith(id: 'second_wiring');
    final project = p.copyWith(
      pages: [
        first.copyWith(devices: [...first.devices, duplicate]),
        ...p.pages.skip(1),
      ],
    );
    final index = ConnectivityIndex.build(project);
    final resolver = index.resolver;
    expect(
      resolver.port(first.devices.single, 'a1')!.node,
      resolver.port(duplicate, 'a1')!.node,
    );
    expect(
      index.connected(
        resolver.port(duplicate, 'a1')!.node,
        const ElectricalNode.terminal('component_relay', 'terminal_13'),
      ),
      isTrue,
    );
    expect(
      validateProject(
        project,
      ).where((d) => d.code == 'repeated_wiring_terminal'),
      hasLength(2),
    );
    expect(
      buildBom(project).articles
          .singleWhere((r) => r.articleId == 'article_relay')
          .installed
          .knownBaseUnits,
      1,
    );
  });

  test(
    'sheet removal preserves components and layout; deleting last sheet is atomic',
    () {
      final p = DemoProject.create();
      final engine = ProjectEngine(p)
        ..execute([const DeleteSheet('sheet_control')]);
      expect(engine.project.components, p.components);
      expect(engine.project.mountingLayouts, p.mountingLayouts);
      final before = engine.project;
      expect(
        () => engine.execute([for (final s in before.pages) DeleteSheet(s.id)]),
        throwsA(errorCode('invalid_page_count')),
      );
      expect(engine.project, same(before));
      engine.undo();
      expect(withoutRevision(engine.project), withoutRevision(p));
    },
  );

  test(
    'marker and device move together preserving manual route in undo history',
    () {
      final p = DemoProject.create();
      final sheet = p.pages.first;
      final routed = sheet.copyWith(
        wires: [
          sheet.wires.first.copyWith(waypoints: const [Vec2(300, 180)]),
        ],
      );
      final engine = ProjectEngine(
        p.copyWith(pages: [routed, ...p.pages.skip(1)]),
      );
      final marker = sheet.continuations.first;
      final device = sheet.devices.first;
      engine.execute([
        UpdateContinuationMarker(
          sheet.id,
          marker.copyWith(position: marker.position + const Vec2(100, 0)),
        ),
        MoveDevices(sheet.id, {
          device.id: device.position + const Vec2(100, 0),
        }),
      ]);
      final after = engine.project.pages.first;
      final route = ProjectResolver(
        engine.project,
      ).wirePath(after, after.wires.single);
      expect(route.first.x, 400);
      expect(route.last.x, 400);
      engine.undo();
      expect(engine.project.pages.first.toJson(), routed.toJson());
    },
  );

  test('complete demo round-trips v4 with strict graph references', () {
    final p = DemoProject.create();
    final restored = roundTrip(p);
    requireValidProject(restored);
    expect(restored.toJson(), p.toJson());
    expect(restored.toJson()['formatVersion'], EcadProject.formatVersion);
    expect(restored.pages, hasLength(5));
    for (final version in [0, 1, 2, 3, 6, 4.0, null]) {
      expect(
        () => EcadProject.fromJson({...p.toJson(), 'formatVersion': version}),
        throwsA(errorCode('unsupported_format')),
      );
    }
    expect(
      () => EcadProject.fromJson({...p.toJson(), 'execute': 'something'}),
      throwsA(errorCode('invalid_schema')),
    );
    expect(
      () => EcadProject.fromJson({...p.toJson()}..remove('components')),
      throwsA(errorCode('limit_exceeded')),
    );
    final bad = p.copyWith(
      components: [
        p.components.first.copyWith(articleId: 'missing'),
        ...p.components.skip(1),
      ],
    );
    expect(
      () => requireValidProject(roundTrip(bad)),
      throwsA(errorCode('missing_article')),
    );
  });

  test('collections are immutable and nullable copyWith can erase values', () {
    final terminals = <ComponentTerminal>[
      const ComponentTerminal(id: 't', designation: '1'),
    ];
    final functionIds = <String>['t'];
    final functions = [
      ComponentFunction(id: 'f', name: 'F', terminalIds: functionIds),
    ];
    final electrical = ElectricalModel(
      terminals: terminals,
      functions: functions,
    );
    terminals.clear();
    functionIds.clear();
    functions.clear();
    expect(electrical.terminals, hasLength(1));
    expect(electrical.functions.single.terminalIds, ['t']);
    expect(electrical.functions.clear, throwsUnsupportedError);
    expect(
      electrical.functions.single.terminalIds.clear,
      throwsUnsupportedError,
    );
    final bindings = <String, String>{'in': 't'};
    final symbol = BuiltinSymbolSpec(
      kind: DeviceKind.supply,
      bindings: bindings,
    );
    bindings.clear();
    expect(symbol.bindings, {'in': 't'});
    expect(symbol.bindings.clear, throwsUnsupportedError);
    final p = DemoProject.create();
    expect(p.components.clear, throwsUnsupportedError);
    expect(p.articles.clear, throwsUnsupportedError);
    expect(p.pages.first.continuations.clear, throwsUnsupportedError);
    expect(p.mountingLayouts.single.placements.clear, throwsUnsupportedError);
    final c = p.components.first;
    expect(c.copyWith().articleId, c.articleId);
    expect(
      c
          .copyWith(articleId: null, electrical: null, designation: null)
          .articleId,
      isNull,
    );
    expect(c.copyWith(electrical: null).electrical, isNull);
    expect(
      p.articles.first
          .copyWith(manufacturer: null, dimensionsMm: null)
          .dimensionsMm,
      isNull,
    );
    expect(p.pages[2].copyWith(mountingView: null).mountingView, isNull);
    expect(p.pages[3].copyWith(report: null).report, isNull);
    expect(
      const Quantity.pieces(3).copyWith(baseUnits: null).baseUnits,
      isNull,
    );
  });

  test('exact quantities preserve unknowns and reject ambiguous decimals', () {
    for (final (input, mm, canonical) in [
      ('2.750', 2750, '2.75'),
      ('0.001', 1, '0.001'),
      ('12', 12000, '12'),
      ('0.100', 100, '0.1'),
    ]) {
      final q = Quantity.parse(QuantityUnit.metre, input);
      expect((q.baseUnits, q.amount), (mm, canonical));
      expect(Quantity.fromJson(q.toJson()).baseUnits, mm);
    }
    expect(
      Quantity.fromJson({'unit': 'metre', 'amount': null}).baseUnits,
      isNull,
    );
    for (final bad in [
      '0',
      '-1',
      '1e3',
      '2,75',
      '.5',
      '1.0001',
      'Infinity',
      ' 1',
      '100000001',
    ]) {
      expect(
        () => Quantity.parse(QuantityUnit.metre, bad),
        throwsA(errorCode('invalid_quantity')),
        reason: bad,
      );
    }
    expect(
      () => Quantity.parse(QuantityUnit.piece, '1.5'),
      throwsA(errorCode('invalid_quantity')),
    );
    expect(
      () => Quantity.fromJson({'unit': 'piece', 'amount': 1}),
      throwsA(errorCode('invalid_schema')),
    );
    expect(
      () => Quantity.fromJson({'unit': 'metre'}),
      throwsA(errorCode('invalid_schema')),
    );
  });

  test('BOM counts components once across functions, references and views', () {
    final base = DemoProject.create();
    final p = base.copyWith(
      pages: [
        ...base.pages,
        base.pages[2].copyWith(
          id: 'detail',
          number: '04',
          mountingView: base.pages[2].mountingView!.copyWith(
            scaleDenominator: 1,
          ),
        ),
      ],
    );
    final bom = buildBom(p);
    final relay = bom.articles.singleWhere(
      (r) => r.articleId == 'article_relay',
    );
    expect(relay.installed.knownBaseUnits, 1);
    expect(relay.componentIds, ['component_relay']);
    final row = bom.components.singleWhere(
      (r) => r.component.id == 'component_relay',
    );
    expect(row.occurrences, hasLength(3));
    expect(row.mountingSheetIds, ['sheet_mounting', 'detail']);
    expect(row.hasRepresentation, isTrue);
    final material = bom.articles.singleWhere(
      (r) => r.articleId == 'article_material',
    );
    expect(material.requiredTotal.knownBaseUnits, 3250);
    expect(material.toPurchase.knownBaseUnits, 2750);
    expect(material.available.knownBaseUnits, 500);
    final another = p.copyWith(
      components: [
        ...p.components,
        const Component(
          id: 'mechanical',
          designation: '-K2',
          articleId: 'article_relay',
        ),
      ],
    );
    final row2 = buildBom(
      another,
    ).articles.singleWhere((r) => r.articleId == 'article_relay');
    expect(row2.installed.knownBaseUnits, 2);
    expect(
      buildBom(another).components
          .singleWhere((r) => r.component.id == 'mechanical')
          .hasRepresentation,
      isFalse,
    );
    expect(
      bom.articles.map((r) => r.componentIds).expand((ids) => ids),
      isNot(contains('marker_pe')),
    );
  });

  test('BOM distinguishes article IDs, missing articles and procurement', () {
    final base = DemoProject.create();
    final p = base.copyWith(
      articles: [
        ...base.articles,
        base.articles.first.copyWith(id: 'other_article'),
        const Article(id: 'unused', name: 'Unused', unit: QuantityUnit.piece),
      ],
      components: [
        ...base.components,
        const Component(
          id: 'unknown_length',
          kind: ComponentKind.material,
          articleId: 'article_material',
          quantity: Quantity.millimetres(null),
          usage: ComponentUsage.spare,
        ),
        const Component(
          id: 'included',
          designation: '-X8',
          articleId: 'other_article',
          procurement: Procurement(
            source: ProcurementSource.included,
            includedInComponentId: 'component_relay',
          ),
        ),
        const Component(
          id: 'missing_other',
          kind: ComponentKind.material,
          quantity: Quantity.pieces(null),
        ),
      ],
    );
    final bom = buildBom(p);
    expect(bom.articles.map((r) => r.articleId), isNot(contains('unused')));
    expect(bom.articles.where((r) => r.article == null), hasLength(2));
    final length = bom.articles.singleWhere(
      (r) => r.articleId == 'article_material',
    );
    expect(length.requiredTotal.unknownComponentIds, {'unknown_length'});
    expect(length.toPurchase.display(QuantityUnit.metre), '2,75 + neurčeno');
    expect(length.available.isKnown, isTrue);
    final included = bom.articles.singleWhere(
      (r) => r.articleId == 'other_article',
    );
    expect(included.included.knownBaseUnits, 1);
    expect(included.toPurchase.knownBaseUnits, 0);
    expect(
      bom.components
          .singleWhere((r) => r.component.id == 'included')
          .includedInDesignation,
      '-K1',
    );
  });

  test(
    'live report reads current revision without serializing generated rows',
    () {
      final engine = ProjectEngine(DemoProject.create());
      final original = engine.project;
      final report = buildReport(original, original.sheetById('sheet_bom')!);
      final text = report.rows.map((r) => r.cells.join('|')).join('\n');
      expect(text, contains('Demo Works'));
      expect(report.rows.clear, throwsUnsupportedError);
      expect(report.rows.first.cells.clear, throwsUnsupportedError);
      expect(
        jsonEncode(original.sheetById('sheet_bom')!.toJson()),
        isNot(contains('Demo Works')),
      );
      engine.execute([
        UpdateArticle(original.articles.first.copyWith(name: 'Changed')),
      ]);
      final updated = buildReport(
        engine.project,
        engine.project.sheetById('sheet_bom')!,
      );
      expect(updated.sourceRevision, 1);
      expect(
        updated.rows.map((r) => r.cells.join('|')).join('\n'),
        contains('Changed'),
      );
      expect(engine.project.revision, 1);
      engine.undo();
      expect(
        buildReport(
          engine.project,
          engine.project.sheetById('sheet_bom')!,
        ).sourceRevision,
        2,
      );
      expect(withoutRevision(engine.project), withoutRevision(original));
    },
  );

  test('atomic failures preserve identity, redo and revision', () {
    final engine = ProjectEngine(DemoProject.create());
    engine.execute([const RenameProject('Edit')]);
    engine.undo();
    final before = engine.project;
    final c = before.components.first;
    for (final commands in <List<EcadCommand>>[
      [
        const RenameProject('Not applied'),
        const DeleteArticle('article_relay'),
      ],
      [UpdateComponent(c.copyWith(quantity: const Quantity.pieces(2)))],
      [UpdateComponent(c.copyWith(articleId: 'article_material'))],
      [const DeleteComponent('component_relay')],
      [const DeleteContinuationLink('link_signal')],
      [const DeleteMountingLayout('layout_demo')],
      [UpdateComponent(c.copyWith(usage: ComponentUsage.spare))],
      [
        UpdateComponent(
          c.copyWith(
            procurement: const Procurement(
              source: ProcurementSource.included,
              includedInComponentId: 'component_relay',
            ),
          ),
        ),
      ],
      [
        UpdateComponent(
          c.copyWith(
            procurement: const Procurement(
              source: ProcurementSource.included,
              includedInComponentId: 'material_unknown',
            ),
          ),
        ),
        UpdateComponent(
          before.components.last.copyWith(
            procurement: const Procurement(
              source: ProcurementSource.included,
              includedInComponentId: 'component_relay',
            ),
          ),
        ),
      ],
      [
        UpdateDevice(
          'sheet_control',
          before.pages.first.devices.first.copyWith(
            mode: OccurrenceMode.reference,
          ),
        ),
      ],
    ]) {
      expect(() => engine.execute(commands), throwsA(isA<EcadException>()));
      expect(engine.project, same(before));
      expect(engine.canRedo, isTrue);
      expect(engine.canUndo, isFalse);
    }
    expect(
      () => engine.execute([const RenameProject('Stale')], expectedRevision: 0),
      throwsA(errorCode('stale_revision')),
    );
    expect(engine.project, same(before));
    expect(engine.redo(), isTrue);
    expect((engine.project.name, engine.project.revision), ('Edit', 3));
  });

  test(
    'one atomic batch creates domain graph and undo restores everything',
    () {
      final base = EcadProject(
        id: 'p',
        name: 'P',
        pages: [Sheet(id: 's', name: 'S', number: '1')],
      );
      final seed = createBuiltinComponent(
        componentId: 'c',
        deviceId: 'd',
        kind: DeviceKind.coil,
        designation: '-K9',
        position: const Vec2(200, 200),
      );
      final commands = <EcadCommand>[
        const AddArticle(
          Article(id: 'a', name: 'Demo', unit: QuantityUnit.piece),
        ),
        AddComponent(seed.component.copyWith(articleId: 'a')),
        AddDevice('s', seed.device),
        AddDevice(
          's',
          seed.device.copyWith(id: 'd2', mode: OccurrenceMode.reference),
        ),
      ];
      final decoded = decodeCommands(
        jsonDecode(jsonEncode(commands.map((c) => c.toJson()).toList())),
      );
      final engine = ProjectEngine(base)
        ..execute(decoded, label: 'Insert', expectedRevision: 0);
      final after = engine.project;
      expect(buildBom(after).articles.single.installed.knownBaseUnits, 1);
      expect(engine.undoLabel, 'Insert');
      expect(engine.undo(), isTrue);
      expect(withoutRevision(engine.project), withoutRevision(base));
      expect(engine.redo(), isTrue);
      expect(withoutRevision(engine.project), withoutRevision(after));
      engine.execute([
        DeleteDevices('s', {'d', 'd2'}),
      ]);
      expect(
        buildBom(engine.project).articles.single.installed.knownBaseUnits,
        1,
      );
      engine.execute([const DeleteComponent('c'), const DeleteArticle('a')]);
      expect(engine.project.components, isEmpty);
    },
  );

  test(
    'component and terminal renames preserve wires and electrical identity',
    () {
      final engine = ProjectEngine(DemoProject.create());
      final c = engine.project.components.first;
      final originalWires = engine.project.pages.first.wires;
      final electrical = c.electrical!;
      engine.execute([
        UpdateComponent(
          c.copyWith(
            designation: '-K55',
            electrical: electrical.copyWith(
              terminals: [
                electrical.terminals.first.copyWith(
                  designation: 'X1:7',
                  signal: 'Enable',
                ),
                ...electrical.terminals.skip(1),
              ],
            ),
          ),
        ),
      ]);
      final d = engine.project.pages.first.devices.first;
      final p = ProjectResolver(engine.project).port(d, 'a1')!;
      expect(
        (p.label, p.signal, p.node.terminalId),
        ('X1:7', 'Enable', 'terminal_a1'),
      );
      expect(engine.project.pages.first.wires, originalWires);
      expect(
        buildBom(engine.project).articles
            .singleWhere((r) => r.articleId == 'article_relay')
            .designations,
        ['-K55'],
      );
    },
  );

  test(
    'mounting keeps millimetres under view scaling and has no electrical ports',
    () {
      final p = DemoProject.create();
      final layout = p.mountingLayouts.single;
      final placement = layout.placements.single;
      final sheet = p.pages[2];
      final view = sheet.mountingView!;
      final transform = MountingTransform(sheet, view);
      final mapped = transform.toSheet(placement.centerMm);
      final restored = transform.toMountingMm(mapped);
      expect(restored.x, closeTo(65, 1e-9));
      expect(restored.y, closeTo(55, 1e-9));
      final paper = SheetTransform(sheet);
      final a = paper.toPaperMm(transform.toSheet(Vec2.zero));
      final b = paper.toPaperMm(transform.toSheet(const Vec2(100, 0)));
      expect(b.x - a.x, closeTo(50, 1e-9));
      final engine = ProjectEngine(p)..execute([
        UpdateSheet(
          sheet.copyWith(mountingView: view.copyWith(scaleDenominator: 5)),
        ),
      ]);
      expect(engine.project.mountingLayouts.single.toJson(), layout.toJson());
      expect(engine.project.pages[2].devices, isEmpty);
      expect(
        ProjectResolver(p).mountingBounds(placement)!.width,
        closeTo(48, 1e-9),
      );
      expect(
        ProjectResolver(
          p,
        ).mountingBounds(placement.copyWith(rotation: 90))!.width,
        closeTo(60, 1e-9),
      );
      final unknownSize = p.articles.first.copyWith(dimensionsMm: null);
      expect(
        () => engine.execute([UpdateArticle(unknownSize)]),
        throwsA(errorCode('missing_mounting_dimensions')),
      );
      expect(
        () => engine.execute([
          UpdateMountingLayout(
            layout.copyWith(
              placements: [placement, placement.copyWith(id: 'duplicate')],
            ),
          ),
        ]),
        throwsA(errorCode('duplicate_placement')),
      );
      final override = p.components.first.copyWith(
        mountingSizeOverrideMm: const DimensionsMm(width: 52),
      );
      expect(ProjectResolver(p).dimensionsFor(override).height, 60);
      expect(ProjectResolver(p).dimensionsFor(override).width, 52);
    },
  );

  test(
    'explicit links connect across sheets; same component and text do not',
    () {
      final p = DemoProject.create();
      final index = ConnectivityIndex.build(p);
      const a1 = ElectricalNode.terminal('component_relay', 'terminal_a1');
      const a2 = ElectricalNode.terminal('component_relay', 'terminal_a2');
      const contact = ElectricalNode.terminal('component_relay', 'terminal_13');
      expect(index.connected(a1, contact), isTrue);
      expect(index.connected(a1, a2), isFalse);
      expect(
        index.connected(a1, const ElectricalNode.link('link_earth')),
        isFalse,
      );
      final unlinked = p.copyWith(
        continuationLinks: [
          ...p.continuationLinks,
          const ContinuationLink(id: 'other_link', label: 'SIGNAL-B'),
        ],
        pages: [
          p.pages.first,
          p.pages[1].copyWith(
            continuations: [
              p.pages[1].continuations.single.copyWith(linkId: 'other_link'),
            ],
          ),
          ...p.pages.skip(2),
        ],
      );
      requireValidProject(unlinked);
      expect(ConnectivityIndex.build(unlinked).connected(a1, contact), isFalse);
      final engine = ProjectEngine(p);
      expect(
        () => engine.execute([
          AddWire(
            'sheet_control',
            Wire(
              id: 'cross',
              from: const TerminalRef(deviceId: 'dev_coil', portId: 'a1'),
              to: const TerminalRef(deviceId: 'dev_contact', portId: 'in'),
            ),
          ),
        ]),
        throwsA(errorCode('missing_device')),
      );
      expect(
        () => engine.execute([
          const AddContinuationLink(
            ContinuationLink(id: 'same_text', label: 'SIGNAL-A'),
          ),
        ]),
        throwsA(errorCode('duplicate_link_label')),
      );
      engine.execute([
        const DeleteContinuationMarker('sheet_control', 'marker_a'),
      ]);
      expect(engine.project.pages.first.wires, isEmpty);
      expect(engine.project.components.length, p.components.length);
    },
  );

  test('stable block ports round-trip and invalid references are rejected', () {
    final p = DemoProject.create();
    final d = p.pages.first.devices.first.copyWith(
      symbol: PortBlockSpec(
        width: 80,
        height: 100,
        ports: const [
          BlockPort(
            id: 'input',
            terminalId: 'terminal_a1',
            side: PortSide.left,
            fraction: .25,
          ),
          BlockPort(
            id: 'return',
            terminalId: 'terminal_a2',
            side: PortSide.bottom,
            fraction: .5,
          ),
        ],
      ),
    );
    final wire = p.pages.first.wires.single.copyWith(
      to: const TerminalRef(deviceId: 'dev_coil', portId: 'input'),
    );
    final block = p.copyWith(
      pages: [
        p.pages.first.copyWith(devices: [d], wires: [wire]),
        ...p.pages.skip(1),
      ],
    );
    requireValidProject(roundTrip(block));
    expect(ProjectResolver(block).ports(d).map((p) => p.label), ['A1', 'A2']);
    final engine = ProjectEngine(block);
    final spec = d.symbol as PortBlockSpec;
    engine.execute([
      UpdateDevice(
        'sheet_control',
        d.copyWith(symbol: spec.copyWith(width: 120)),
      ),
    ]);
    expect(engine.project.pages.first.wires.single.to, wire.to);
    expect(
      () => engine.execute([
        UpdateDevice(
          'sheet_control',
          d.copyWith(
            symbol: spec.copyWith(
              ports: [spec.ports.first.copyWith(terminalId: 'terminal_13')],
            ),
          ),
        ),
      ]),
      throwsA(errorCode('invalid_port_binding')),
    );
    expect(
      () => engine.execute([
        UpdateDevice(
          'sheet_control',
          d.copyWith(
            symbol: spec.copyWith(
              ports: [spec.ports.first.copyWith(fraction: 0)],
            ),
          ),
        ),
      ]),
      throwsA(errorCode('invalid_port_geometry')),
    );
  });

  test('command codec covers new operations without unknown fields', () {
    final p = DemoProject.create();
    final commands = <EcadCommand>[
      AddArticle(p.articles.first),
      UpdateArticle(p.articles.first),
      const DeleteArticle('a'),
      AddComponent(p.components.first),
      UpdateComponent(p.components.first),
      const DeleteComponent('c'),
      AddContinuationLink(p.continuationLinks.first),
      UpdateContinuationLink(p.continuationLinks.first),
      const DeleteContinuationLink('l'),
      AddMountingLayout(p.mountingLayouts.single),
      UpdateMountingLayout(p.mountingLayouts.single),
      const DeleteMountingLayout('l'),
      AddContinuationMarker('s', p.pages.first.continuations.first),
      UpdateContinuationMarker('s', p.pages.first.continuations.first),
      const DeleteContinuationMarker('s', 'm'),
      UpdateSheet(p.pages.first),
      const DeleteSheet('s'),
      ReorderSheets(['s']),
      const SetProjectDescription('Description'),
      UpdateWire('s', p.pages.first.wires.single),
    ];
    for (final c in commands) {
      expect(
        EcadCommand.fromJson(jsonDecode(jsonEncode(c.toJson()))).toJson(),
        c.toJson(),
      );
      expect(
        () => EcadCommand.fromJson({...c.toJson(), 'unknown': true}),
        throwsA(errorCode('invalid_schema')),
      );
    }
  });

  test('bounded metadata, identity, revisions and histories', () {
    final p = DemoProject.create();
    expect(
      () => ProjectEngine(p, historyLimit: 0),
      throwsA(isA<EcadException>()),
    );
    final capped = ProjectEngine(
      p.copyWith(revision: ProjectLimits.maxRevision),
    );
    expect(
      () => capped.execute([const RenameProject('Overflow')]),
      throwsA(errorCode('limit_exceeded')),
    );
    final engine = ProjectEngine(p, historyLimit: 2);
    for (var i = 0; i < 3; i++) {
      engine.execute([RenameProject('Edit $i')]);
    }
    expect(engine.undo(), isTrue);
    expect(engine.undo(), isTrue);
    expect(engine.undo(), isFalse);
    final ids = {for (var i = 0; i < 200; i++) newId('component')};
    expect(ids, hasLength(200));
    expect(() => newId('../bad'), throwsA(isA<EcadException>()));
    expect(
      () => ProjectEngine(
        p.copyWith(
          components: [
            ...p.components,
            p.components.first.copyWith(id: 'new_id', electrical: null),
          ],
        ),
      ),
      throwsA(errorCode('duplicate_designation')),
    );
    expect(
      () => ProjectEngine(
        p.copyWith(components: [...p.components, p.components.first]),
      ),
      throwsA(errorCode('duplicate_id')),
    );
    expect(
      () => EcadProject.fromJson({
        ...p.toJson(),
        'pages': List<Object?>.filled(ProjectLimits.maxPages + 1, null),
      }),
      throwsA(errorCode('limit_exceeded')),
    );
    expect(
      () => EcadProject.fromJson({...p.toJson(), 'name': 'x' * 201}),
      throwsA(errorCode('invalid_schema')),
    );
    expect(
      () => Device.fromJson({
        ...p.pages.first.devices.first.toJson(),
        'position': {'x': double.infinity, 'y': 0},
      }),
      throwsA(errorCode('invalid_geometry')),
    );
  });
}
