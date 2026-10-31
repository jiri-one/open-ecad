// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

import 'support.dart';

EcadProject _project() {
  final devices = [
    for (final id in ['left', 'right'])
      syntheticDevice(
        id: id,
        kind: DeviceKind.coil,
        position: const Vec2(300, 250),
      ),
  ];
  return EcadProject(
    id: 'project',
    name: 'Synthetic continuations',
    articles: const [
      Article(id: 'article', name: 'Synthetic coil', unit: QuantityUnit.piece),
    ],
    components: [
      for (final device in devices)
        syntheticComponent(device).copyWith(articleId: 'article'),
    ],
    continuationLinks: const [
      ContinuationLink(id: 'signal', label: ' Signal-A '),
      ContinuationLink(id: 'earth', label: 'PE'),
      ContinuationLink(id: 'unused', label: 'Spare'),
    ],
    pages: [
      for (final (i, side) in ['left', 'right'].indexed)
        Sheet(
          id: i == 0 ? 'z_sheet' : 'a_sheet',
          name: side,
          number: '01',
          documentCode: 'DOC',
          structure: StructureContext(
            functionPath: ['TEST'],
            locationPath: [side.toUpperCase()],
          ),
          devices: [devices[i]],
          continuations: [
            ContinuationMarker(
              id: 'marker_$side',
              linkId: 'signal',
              position: const Vec2(300, 130),
              direction: PortSide.bottom,
            ),
            if (i == 0) ...[
              const ContinuationMarker(
                id: 'local_peer',
                linkId: 'signal',
                position: Vec2(700, 470),
                direction: PortSide.right,
              ),
              const ContinuationMarker(
                id: 'earth_peer',
                linkId: 'earth',
                position: Vec2(900, 600),
                glyph: ContinuationGlyph.earth,
                direction: PortSide.top,
              ),
            ],
          ],
          wires: [
            Wire(
              id: 'wire_$side',
              from: ContinuationRef(markerId: 'marker_$side'),
              to: TerminalRef(deviceId: side, portId: 'a1'),
              waypoints: const [
                Vec2(300, 170),
                Vec2(330, 170),
                Vec2(330, 220),
                Vec2(300, 220),
              ],
            ),
          ],
        ),
    ],
  );
}

Matcher _error(String code) => isA<EcadException>()
    .having((error) => error.code, 'code', code)
    .having((error) => error.message, 'message', isNotEmpty);

Map<String, Object?> _content(EcadProject project) =>
    project.toJson()..remove('revision');

List<(String, String)> _addresses(List<ContinuationTarget> targets) => [
  for (final target in targets) (target.sheet.id, target.marker.id),
];

Object _unrelated(EcadProject project) {
  final resolver = ProjectResolver(project);
  final bom = buildBom(project);
  return [
    project.components.map((item) => item.toJson()).toList(),
    project.articles.map((item) => item.toJson()).toList(),
    project.mountingLayouts.map((item) => item.toJson()).toList(),
    project.terminalStrips.map((item) => item.toJson()).toList(),
    for (final sheet in project.pages)
      [
        sheet.devices.map((item) => item.toJson()).toList(),
        sheet.wires.map((item) => item.toJson()).toList(),
        for (final device in sheet.devices)
          for (final port in resolver.ports(device))
            (
              port.ref,
              port.node,
              port.label,
              port.signal,
              port.geometry.point,
              port.geometry.direction,
            ),
      ],
    for (final row in bom.articles)
      [
        row.rowKey,
        row.componentIds,
        row.designations,
        for (final total in [
          row.installed,
          row.spare,
          row.available,
          row.included,
          row.toPurchase,
          row.requiredTotal,
        ])
          [total.knownBaseUnits, total.unknownComponentIds],
      ],
    for (final row in bom.components)
      [
        row.component.id,
        row.occurrences,
        row.mountingSheetIds,
        row.layoutId,
        row.placementId,
      ],
  ];
}

void main() {
  test('navigation includes local and remote peers in document order', () {
    final project = _project();
    requireValidProject(project);
    final index = ContinuationIndex(project);
    final peers = index.targets(sheetId: 'z_sheet', markerId: 'marker_left');
    expect(_addresses(peers), [
      ('z_sheet', 'local_peer'),
      ('a_sheet', 'marker_right'),
    ]);
    expect(peers.last.sheet.number, peers.first.sheet.number);
    expect(fullPageDesignation(peers.first.sheet), '=TEST+LEFT&DOC/01');
    expect(fullPageDesignation(peers.last.sheet), '=TEST+RIGHT&DOC/01');
    expect(
      peers.map((target) => target.marker),
      ProjectResolver(project)
          .continuationTargets(project.pages.first.continuations.first)
          .map((target) => target.marker),
    );
    expect(
      _addresses(index.targets(sheetId: 'a_sheet', markerId: 'marker_right')),
      [('z_sheet', 'marker_left'), ('z_sheet', 'local_peer')],
    );
    expect(index.occurrences('signal').clear, throwsUnsupportedError);
    expect(peers.clear, throwsUnsupportedError);
    expect(index.occurrences('signal'), hasLength(3));
  });

  test('same labels and IDs never join separate project snapshots', () {
    final first = _project();
    final second = first.copyWith(
      pages: [
        first.pages.first.copyWith(
          continuations: [first.pages.first.continuations.first],
        ),
      ],
    );
    final a = ContinuationIndex(first), b = ContinuationIndex(second);
    expect(a.occurrences('signal'), hasLength(3));
    expect(b.targets(sheetId: 'z_sheet', markerId: 'marker_left'), isEmpty);
    expect(b.occurrences('signal'), hasLength(1));
    expect(
      a.occurrence(sheetId: 'z_sheet', markerId: 'marker_left')!.sheet,
      same(first.pages.first),
    );
    expect(
      b.occurrence(sheetId: 'z_sheet', markerId: 'marker_left')!.sheet,
      same(second.pages.first),
    );
    final repeatedLabel = first.copyWith(
      continuationLinks: [
        ...first.continuationLinks,
        ContinuationLink(
          id: 'independent',
          label: first.continuationLinks.first.label,
        ),
      ],
      pages: [
        first.pages.first,
        first.pages.last.copyWith(
          continuations: [
            first.pages.last.continuations.single.copyWith(
              linkId: 'independent',
            ),
          ],
        ),
      ],
    );
    expect(
      _addresses(
        ContinuationIndex(
          repeatedLabel,
        ).targets(sheetId: 'z_sheet', markerId: 'marker_left'),
      ),
      [('z_sheet', 'local_peer')],
    );
    expect(a.occurrences('signal'), hasLength(3));
  });

  test(
    'missing, removed and orphan occurrences never yield guessed targets',
    () {
      final project = _project();
      final old = ContinuationIndex(project);
      for (final address in [
        ('missing', 'marker_left'),
        ('z_sheet', 'missing'),
        ('z_sheet', 'marker_right'),
      ]) {
        expect(
          old.occurrence(sheetId: address.$1, markerId: address.$2),
          isNull,
        );
        expect(old.targets(sheetId: address.$1, markerId: address.$2), isEmpty);
      }
      expect(old.occurrences('missing'), isEmpty);
      expect(old.occurrences('unused'), isEmpty);
      expect(old.targets(sheetId: 'z_sheet', markerId: 'earth_peer'), isEmpty);

      final engine = ProjectEngine(project)
        ..execute([const DeleteContinuationMarker('a_sheet', 'marker_right')]);
      final next = ContinuationIndex(engine.project);
      expect(
        next.targets(sheetId: 'a_sheet', markerId: 'marker_right'),
        isEmpty,
      );
      expect(
        next.occurrence(sheetId: 'a_sheet', markerId: 'marker_right'),
        isNull,
      );
      expect(
        _addresses(next.targets(sheetId: 'z_sheet', markerId: 'marker_left')),
        [('z_sheet', 'local_peer')],
      );
      expect(
        old.targets(sheetId: 'z_sheet', markerId: 'marker_left'),
        hasLength(2),
      );
      engine.undo();
      expect(
        ContinuationIndex(engine.project).occurrences('signal'),
        hasLength(3),
      );

      final orphaned = ContinuationIndex(
        project.copyWith(continuationLinks: []),
      );
      expect(orphaned.occurrences('signal'), isEmpty);
      expect(
        orphaned.occurrence(sheetId: 'z_sheet', markerId: 'marker_left'),
        isNull,
      );
      expect(
        orphaned.targets(sheetId: 'z_sheet', markerId: 'marker_left'),
        isEmpty,
      );
      final removedSheet = ContinuationIndex(
        project.copyWith(pages: [project.pages.first]),
      );
      expect(
        removedSheet.targets(sheetId: 'a_sheet', markerId: 'marker_right'),
        isEmpty,
      );
      expect(removedSheet.occurrences('signal'), hasLength(2));
    },
  );

  test('group creation and insertion are one undoable transaction', () {
    final project = _project();
    final engine = ProjectEngine(project);
    const marker = ContinuationMarker(
      id: 'new_marker',
      linkId: 'new_link',
      position: Vec2(800, 700),
    );
    final commands = continuationEditCommands(
      project,
      sheetId: 'a_sheet',
      marker: marker,
      isNewMarker: true,
      label: ' New signal ',
      createLink: true,
    );
    expect(engine.project, same(project));
    expect(project.continuationLinkById('new_link'), isNull);
    engine.execute(
      commands,
      label: 'Insert continuation',
      expectedRevision: project.revision,
    );
    final created = engine.project;
    expect(created.revision, project.revision + 1);
    expect(created.continuationLinkById('new_link')!.label, 'New signal');
    expect(
      ContinuationIndex(created).occurrences('new_link').single.marker,
      same(marker),
    );
    expect(_unrelated(created), _unrelated(project));
    engine.undo();
    expect(_content(engine.project), _content(project));
    expect(engine.canUndo, isFalse);
    expect(engine.canRedo, isTrue);
    engine.redo();
    expect(_content(engine.project), _content(created));
  });

  for (final type in [SheetType.multiLine, SheetType.singleLine]) {
    test(
      'all directions and glyphs can share a group on ${type.name} sheets',
      () {
        final initial = _project();
        final engine = ProjectEngine(
          initial.copyWith(
            pages: [
              initial.pages.first.copyWith(type: type),
              initial.pages.last,
            ],
          ),
        );
        for (final direction in PortSide.values) {
          for (final glyph in ContinuationGlyph.values) {
            final marker = ContinuationMarker(
              id: '${direction.name}_${glyph.name}',
              linkId: 'earth',
              position: const Vec2(150, 500),
              direction: direction,
              glyph: glyph,
            );
            engine.execute(
              continuationEditCommands(
                engine.project,
                sheetId: 'z_sheet',
                marker: marker,
                isNewMarker: true,
                label: 'PE',
              ),
            );
            final index = ContinuationIndex(engine.project);
            expect(
              index
                  .targets(sheetId: 'z_sheet', markerId: marker.id)
                  .map((target) => target.marker.id),
              contains('earth_peer'),
            );
          }
        }
        final index = ContinuationIndex(engine.project);
        expect(index.occurrences('earth'), hasLength(9));
        expect(
          index.targets(sheetId: 'z_sheet', markerId: 'earth_peer'),
          hasLength(8),
        );
        expect(_unrelated(engine.project), _unrelated(initial));
      },
    );
  }

  test(
    'reassignment changes only one marker and its logical net, then undoes',
    () {
      final project = _project();
      final engine = ProjectEngine(project);
      final marker = project.pages.first.continuations.first;
      final left =
          ProjectResolver(
            project,
          ).port(project.pages.first.devices.single, 'a1')!.node;
      final right =
          ProjectResolver(
            project,
          ).port(project.pages.last.devices.single, 'a1')!.node;
      expect(ConnectivityIndex.build(project).connected(left, right), isTrue);
      engine.execute(
        continuationEditCommands(
          project,
          sheetId: 'z_sheet',
          marker: marker.copyWith(linkId: 'earth'),
          isNewMarker: false,
          label: ' pe ',
        ),
      );
      final changed = engine.project;
      final index = ContinuationIndex(changed);
      expect(
        _addresses(index.targets(sheetId: 'z_sheet', markerId: marker.id)),
        [('z_sheet', 'earth_peer')],
      );
      expect(index.occurrences('signal').map((target) => target.marker.id), [
        'local_peer',
        'marker_right',
      ]);
      expect(ConnectivityIndex.build(changed).connected(left, right), isFalse);
      expect(
        ConnectivityIndex.build(
          changed,
        ).connected(left, const ElectricalNode.link('earth')),
        isTrue,
      );
      expect(
        changed.pages.first.continuations.first.toJson(),
        marker.copyWith(linkId: 'earth').toJson(),
      );
      expect(
        changed.pages.first.continuations.skip(1),
        project.pages.first.continuations.skip(1),
      );
      expect(changed.continuationLinks, project.continuationLinks);
      expect(_unrelated(changed), _unrelated(project));
      engine.undo();
      expect(_content(engine.project), _content(project));
      expect(
        ConnectivityIndex.build(engine.project).connected(left, right),
        isTrue,
      );
    },
  );

  test(
    'splitting an occurrence to a new group preserves the wired identity',
    () {
      final project = _project();
      final engine = ProjectEngine(project);
      final marker = project.pages.first.continuations.first.copyWith(
        linkId: 'separate',
      );
      engine.execute(
        continuationEditCommands(
          project,
          sheetId: 'z_sheet',
          marker: marker,
          isNewMarker: false,
          label: 'Separate',
          createLink: true,
        ),
      );
      expect(_unrelated(engine.project), _unrelated(project));
      expect(
        ContinuationIndex(engine.project).occurrences('signal'),
        hasLength(2),
      );
      expect(
        ContinuationIndex(
          engine.project,
        ).occurrences('separate').single.marker.id,
        'marker_left',
      );
      engine.undo();
      expect(_content(engine.project), _content(project));
    },
  );

  test(
    'reassignment leaves an empty group available for future occurrences',
    () {
      final project = _project();
      final engine = ProjectEngine(project);
      engine.execute(
        continuationEditCommands(
          project,
          sheetId: 'z_sheet',
          marker: project.pages.first.continuations.last.copyWith(
            linkId: 'signal',
          ),
          isNewMarker: false,
          label: 'Signal-A',
        ),
      );
      expect(
        engine.project.continuationLinkById('earth'),
        same(project.continuationLinkById('earth')),
      );
      expect(ContinuationIndex(engine.project).occurrences('earth'), isEmpty);
      expect(_unrelated(engine.project), _unrelated(project));
    },
  );

  test(
    'explicit group rename affects peers together and restores in one undo',
    () {
      final project = _project();
      final engine = ProjectEngine(project);
      final marker = project.pages.first.continuations.first;
      expect(
        () => continuationEditCommands(
          project,
          sheetId: 'z_sheet',
          marker: marker,
          isNewMarker: false,
          label: 'Control bus',
        ),
        throwsA(_error('rename_required')),
      );
      expect(engine.project, same(project));
      expect(engine.canUndo, isFalse);
      engine.execute(
        continuationEditCommands(
          project,
          sheetId: 'z_sheet',
          marker: marker,
          isNewMarker: false,
          label: ' Control bus ',
          renameLink: true,
        ),
      );
      final index = ContinuationIndex(engine.project);
      expect(index.occurrences('signal'), hasLength(3));
      for (final target in index.occurrences('signal')) {
        expect(
          engine.project.continuationLinkById(target.marker.linkId)!.label,
          'Control bus',
        );
      }
      expect(
        engine.project.pages.map((sheet) => sheet.toJson()),
        project.pages.map((sheet) => sheet.toJson()),
      );
      expect(_unrelated(engine.project), _unrelated(project));
      engine.undo();
      expect(_content(engine.project), _content(project));
      expect(engine.canUndo, isFalse);
    },
  );

  test(
    'equivalent label keeps original spelling while wired marker edits undo',
    () {
      final project = _project();
      final engine = ProjectEngine(project);
      final marker = project.pages.first.continuations.first.copyWith(
        position: const Vec2(340, 150),
        direction: PortSide.right,
        glyph: ContinuationGlyph.earth,
      );
      engine.execute(
        continuationEditCommands(
          project,
          sheetId: 'z_sheet',
          marker: marker,
          isNewMarker: false,
          label: ' signal-a ',
        ),
      );
      expect(
        engine.project.continuationLinkById('signal'),
        same(project.continuationLinkById('signal')),
      );
      expect(
        engine.project.pages.first.continuations.first.toJson(),
        marker.toJson(),
      );
      final wire = engine.project.pages.first.wires.single;
      final original = project.pages.first.wires.single;
      expect(wire.id, original.id);
      expect(wire.from, original.from);
      expect(wire.to, original.to);
      expect(wire.waypoints, isNot(original.waypoints));
      engine.undo();
      expect(_content(engine.project), _content(project));
    },
  );

  test(
    'label collisions never implicitly merge or partially rename groups',
    () {
      final project = _project();
      final engine = ProjectEngine(project);
      for (final create in [false, true]) {
        final marker = project.pages.first.continuations.first.copyWith(
          linkId: create ? 'new_group' : 'signal',
        );
        expect(
          () => continuationEditCommands(
            project,
            sheetId: 'z_sheet',
            marker: marker,
            isNewMarker: false,
            label: ' pe ',
            createLink: create,
            renameLink: !create,
          ),
          throwsA(_error('duplicate_link_label')),
        );
        expect(engine.project, same(project));
        expect(engine.canUndo, isFalse);
      }
    },
  );

  test('new IDs cannot collide with model identities or each other', () {
    final project = _project();
    final marker = project.pages.first.continuations.first;
    final usedIds = [
      'project',
      'z_sheet',
      'a_sheet',
      'article',
      'component_left',
      'left',
      'function_left',
      'terminal_left_a1',
      'wire_left',
      'signal',
      'marker_left',
      'marker_right',
    ];
    for (final id in usedIds) {
      expect(
        () => continuationEditCommands(
          project,
          sheetId: 'z_sheet',
          marker: marker.copyWith(id: id),
          isNewMarker: true,
          label: 'Signal-A',
        ),
        throwsA(_error('duplicate_id')),
        reason: 'marker $id',
      );
      expect(
        () => continuationEditCommands(
          project,
          sheetId: 'z_sheet',
          marker: marker.copyWith(linkId: id),
          isNewMarker: false,
          label: 'New name',
          createLink: true,
        ),
        throwsA(_error('duplicate_id')),
        reason: 'group $id',
      );
    }
    expect(
      () => continuationEditCommands(
        project,
        sheetId: 'z_sheet',
        marker: marker.copyWith(id: 'same', linkId: 'same'),
        isNewMarker: true,
        label: 'New name',
        createLink: true,
      ),
      throwsA(_error('duplicate_id')),
    );
  });

  test(
    'missing groups and markers cannot silently create or move an occurrence',
    () {
      final project = _project();
      final marker = project.pages.first.continuations.first;
      for (final sheetId in ['missing', 'a_sheet']) {
        expect(
          () => continuationEditCommands(
            project,
            sheetId: sheetId,
            marker: marker,
            isNewMarker: false,
            label: 'Signal-A',
          ),
          throwsA(_error('missing_reference')),
        );
      }
      expect(
        () => continuationEditCommands(
          project,
          sheetId: 'z_sheet',
          marker: marker.copyWith(id: 'missing'),
          isNewMarker: false,
          label: 'Signal-A',
        ),
        throwsA(_error('missing_reference')),
      );
      expect(
        () => continuationEditCommands(
          project,
          sheetId: 'z_sheet',
          marker: marker.copyWith(linkId: 'missing'),
          isNewMarker: false,
          label: 'Missing',
          renameLink: true,
        ),
        throwsA(_error('missing_link')),
      );
    },
  );

  test('planner bounds its inputs and rejects incompatible sheet content', () {
    final project = _project();
    final marker = project.pages.first.continuations.first;
    for (final label in ['', '   ', 'NUL\u0000', 'a' * 201]) {
      expect(
        () => continuationEditCommands(
          project,
          sheetId: 'z_sheet',
          marker: marker,
          isNewMarker: false,
          label: label,
          renameLink: true,
        ),
        throwsA(_error('invalid_metadata')),
      );
    }
    for (final id in ['', 'bad id', '@reserved', 'a' * 129]) {
      for (final input in [
        marker.copyWith(id: id),
        marker.copyWith(linkId: id),
      ]) {
        expect(
          () => continuationEditCommands(
            project,
            sheetId: 'z_sheet',
            marker: input,
            isNewMarker: true,
            label: 'Signal-A',
          ),
          throwsA(_error('invalid_id')),
        );
      }
    }
    for (final point in [
      const Vec2(double.nan, 0),
      const Vec2(0, double.infinity),
      Vec2(ProjectLimits.maxCoordinate + 1, 0),
      Vec2(0, -ProjectLimits.maxCoordinate - 1),
    ]) {
      expect(
        () => continuationEditCommands(
          project,
          sheetId: 'z_sheet',
          marker: marker.copyWith(position: point),
          isNewMarker: false,
          label: 'Signal-A',
        ),
        throwsA(_error('invalid_geometry')),
      );
    }
    final nonElectrical = project.copyWith(
      pages: [
        Sheet(
          id: 'drawing',
          name: 'Drawing',
          number: '01',
          type: SheetType.form,
        ),
      ],
    );
    expect(
      () => continuationEditCommands(
        nonElectrical,
        sheetId: 'drawing',
        marker: marker.copyWith(id: 'new_marker'),
        isNewMarker: true,
        label: 'Signal-A',
      ),
      throwsA(_error('incompatible_sheet_content')),
    );
  });

  test(
    'an execution-time collision rolls back the complete plan and history',
    () {
      final project = _project();
      final engine = ProjectEngine(project);
      const marker = ContinuationMarker(
        id: 'pending_marker',
        linkId: 'pending_group',
        position: Vec2(800, 700),
      );
      final plan = continuationEditCommands(
        project,
        sheetId: 'z_sheet',
        marker: marker,
        isNewMarker: true,
        label: 'Pending',
        createLink: true,
      );
      engine.execute([
        const AddContinuationLink(
          ContinuationLink(id: 'label_owner', label: 'PENDING'),
        ),
      ]);
      final before = engine.project;
      expect(
        () => engine.execute(plan),
        throwsA(_error('duplicate_link_label')),
      );
      expect(engine.project, same(before));
      expect(engine.project.continuationLinkById('pending_group'), isNull);
      expect(
        engine.project.pages.first.continuationById('pending_marker'),
        isNull,
      );
      expect(engine.canRedo, isFalse);
      engine.undo();
      expect(_content(engine.project), _content(project));
      expect(engine.canUndo, isFalse);
      expect(engine.canRedo, isTrue);
    },
  );

  test(
    'final engine validation rejects a stale marker ID without leaving its group',
    () {
      final project = _project();
      final engine = ProjectEngine(project);
      const marker = ContinuationMarker(
        id: 'future_id',
        linkId: 'future_group',
        position: Vec2(800, 700),
      );
      final plan = continuationEditCommands(
        project,
        sheetId: 'z_sheet',
        marker: marker,
        isNewMarker: true,
        label: 'Future',
        createLink: true,
      );
      engine.execute([
        const AddComponent(Component(id: 'future_id', designation: '-K9')),
      ]);
      final before = engine.project;
      expect(() => engine.execute(plan), throwsA(_error('duplicate_id')));
      expect(engine.project, same(before));
      expect(engine.project.continuationLinkById('future_group'), isNull);
      expect(_unrelated(engine.project), _unrelated(before));
      engine.undo();
      expect(_content(engine.project), _content(project));
      expect(engine.canUndo, isFalse);
    },
  );
}
