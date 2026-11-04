// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

EcadProject _project() => EcadProject(
  id: 'p',
  name: 'Project',
  pages: [Sheet(id: 's', name: 'Sheet', number: '01')],
);
FrameGeometry _geometry(EcadProject p, [Sheet? sheet]) => layoutFrameGeometry(
  (sheet ?? p.pages.first).paperSizeMm,
  resolveSheetFrame(p, sheet ?? p.pages.first),
);
FrameTemplate _withText(String text) => FrameTemplates.builtin.copyWith(
  titleBlock: FrameTemplates.builtin.titleBlock.copyWith(
    fields: [
      FrameTemplates.builtin.titleBlock.fields.first.copyWith(text: text),
    ],
  ),
);
String _bound(EcadProject p, {FramePageContext? context}) =>
    bindFrame(
      _geometry(p),
      p,
      p.pages.first,
      context ??
          const FramePageContext(
            number: '01',
            documentIndex: 1,
            documentCount: 1,
          ),
    ).texts.last.text;
Matcher _error(String code) =>
    isA<EcadException>().having((e) => e.code, 'code', code);

void main() {
  test(
    'cached validation cannot be mutated or reused for a changed snapshot',
    () {
      final project = _project();
      final diagnostics = validateProject(project);
      diagnostics.clear();
      requireValidProject(project);
      final invalid = project.copyWith(
        defaultFrame: const FrameChoice.template('missing'),
      );
      expect(
        () => requireValidProject(invalid),
        throwsA(_error('missing_frame_template')),
      );
      validateProject(invalid).clear();
      expect(
        () => requireValidProject(invalid),
        throwsA(_error('missing_frame_template')),
      );
    },
  );
  test(
    'headless constructors embed a real reusable default for every sheet type',
    () {
      for (final type in SheetType.values) {
        final p = _project().copyWith(
          pages: [
            Sheet(
              id: 's',
              name: 'Sheet',
              number: '01',
              type: type,
              report:
                  type == SheetType.billOfMaterials
                      ? const BomTableSpec(kind: BomReportKind.articles)
                      : null,
            ),
          ],
        );
        requireValidProject(p);
        expect(p.pages.single.frame.mode, FrameMode.inherit);
        expect(p.frameTemplates.single.id, p.defaultFrame.templateId);
        final resolved = resolveSheetFrame(p, p.pages.single)!;
        expect([
          resolved.border,
          resolved.titleBlock,
          resolved.zones,
        ], everyElement(isTrue));
        expect(_geometry(p).strokesMm, isNotEmpty);
        final decoded = EcadProject.fromJson(
          jsonDecode(jsonEncode(p.toJson())),
        );
        expect(decoded.toJson(), p.toJson());
      }
    },
  );

  test('part overrides inherit independently and reset to null', () {
    final p = _project().copyWith(
      defaultFrame: const FrameChoice.template(
        FrameTemplates.builtinId,
        border: false,
        zones: false,
      ),
    );
    final sheet = p.pages.first.copyWith(
      frame: const FrameChoice.inherit(zones: true, titleBlock: false),
    );
    final resolved = resolveSheetFrame(p, sheet)!;
    expect(
      [resolved.border, resolved.titleBlock, resolved.zones],
      [false, false, true],
    );
    final reset = sheet.copyWith(frame: sheet.frame.copyWith(zones: null));
    expect(resolveSheetFrame(p, reset)!.zones, isFalse);
    final explicit = sheet.copyWith(
      frame: const FrameChoice.template(FrameTemplates.builtinId),
    );
    final own = resolveSheetFrame(p, explicit)!;
    expect([own.border, own.titleBlock, own.zones], everyElement(isTrue));
  });

  test(
    'explicit none survives template/default updates and existing mutations',
    () {
      final p = _project().copyWith(
        pages: [
          _project().pages.first.copyWith(frame: const FrameChoice.none()),
        ],
      );
      final engine = ProjectEngine(p);
      engine.execute([
        UpdateFrameTemplate(FrameTemplates.builtin.copyWith(name: 'Changed')),
        const SetProjectFrame(
          FrameChoice.template(FrameTemplates.builtinId, border: false),
        ),
        const RenameSheet('s', 'New'),
      ]);
      final sheet = engine.project.pages.single;
      expect(resolveSheetFrame(engine.project, sheet), isNull);
      final geometry = _geometry(engine.project);
      expect(geometry.contentRectMm.toJson(), geometry.paperRectMm.toJson());
      expect(geometry.strokesMm, isEmpty);
      expect(geometry.titleFieldSlots, isEmpty);
      expect(Sheet.fromJson(sheet.toJson()).frame.mode, FrameMode.none);
      expect(
        resolveSheetFrame(
          p.copyWith(defaultFrame: const FrameChoice.none()),
          sheet.copyWith(frame: const FrameChoice.inherit(border: true)),
        ),
        isNull,
      );
    },
  );

  test(
    'legacy showFrame maps to one choice and never resets an explicit template',
    () {
      final s = Sheet(id: 's', name: 'S', number: '1', showFrame: false);
      expect(s.frame.mode, FrameMode.none);
      expect(s.toJson().containsKey('showFrame'), isFalse);
      expect(s.copyWith(showFrame: true).frame.mode, FrameMode.inherit);
      final explicit = s.copyWith(
        frame: const FrameChoice.template('custom', border: false),
      );
      expect(
        explicit.copyWith(showFrame: true).frame.toJson(),
        explicit.frame.toJson(),
      );
      final old = s.toJson()..remove('frame');
      old['showFrame'] = false;
      expect(Sheet.fromJson(old).frame.mode, FrameMode.none);
      expect(
        () => Sheet.fromJson({
          ...old,
          'frame': const FrameChoice.inherit().toJson(),
        }),
        throwsA(isA<EcadException>()),
      );
    },
  );

  test(
    'definition codec exports bindings and authored literals only; cloning changes identity',
    () {
      final original = _withText('Číslo: {{document.documentNumber}}');
      final encoded = FrameTemplateCodec.encode(original);
      final decoded = FrameTemplateCodec.decode(encoded);
      expect(decoded.toJson(), original.toJson());
      final clone = decoded.copyWith(id: newId('frame'), name: 'Independent');
      expect(clone.id, isNot(original.id));
      expect(
        clone.titleBlock.fields.single.text,
        original.titleBlock.fields.single.text,
      );
      expect(jsonDecode(encoded), {
        'format': FrameTemplateCodec.format,
        'formatVersion': 1,
        'template': original.toJson(),
      });
      expect(
        () => FrameTemplateCodec.fromJson({
          ...FrameTemplateCodec.toJson(original),
          'documentFields': {'drawnBy': 'private'},
        }),
        throwsA(_error('invalid_schema')),
      );
      expect(
        () => FrameTemplateCodec.fromJson({
          ...FrameTemplateCodec.toJson(original),
          'formatVersion': 1.0,
        }),
        throwsA(_error('unsupported_format')),
      );
    },
  );

  test('nested state and command field maps are immutable snapshots', () {
    final fields = {'drawnBy': 'A'};
    final slots = [FrameTemplates.builtin.titleBlock.fields.first];
    final lines = [const FrameLine(Vec2.zero, Vec2(10, 10))];
    final block = FrameTitleBlock(
      widthMm: 180,
      heightMm: 36,
      fields: slots,
      lines: lines,
    );
    final templates = [FrameTemplates.builtin.copyWith(titleBlock: block)];
    final p = _project().copyWith(
      frameTemplates: templates,
      documentFields: fields,
      pages: [_project().pages.first.copyWith(documentFields: fields)],
    );
    final command = SetSheetDocumentFields('s', fields);
    fields.clear();
    slots.clear();
    lines.clear();
    templates.clear();
    expect(p.documentFields, {'drawnBy': 'A'});
    expect(command.fields, {'drawnBy': 'A'});
    expect(p.frameTemplates.single.titleBlock.fields, hasLength(1));
    expect(() => p.pages.first.documentFields.clear(), throwsUnsupportedError);
    expect(p.frameTemplates.clear, throwsUnsupportedError);
    expect(block.lines.clear, throwsUnsupportedError);
    expect(() => _geometry(p).strokesMm.clear(), throwsUnsupportedError);
  });

  test(
    'document fields inherit, empty suppresses, and removing the key restores',
    () {
      final template = _withText(
        'By {{document.drawnBy}} / {{document.customer}} / {{document.unset}}',
      );
      final p = _project().copyWith(
        frameTemplates: [template],
        documentFields: {'drawnBy': 'Jiří', 'customer': 'Český závod'},
      );
      final engine = ProjectEngine(p);
      expect(_bound(p), 'By Jiří / Český závod / ');
      engine.execute([
        SetSheetDocumentFields('s', {'drawnBy': ''}),
      ]);
      expect(_bound(engine.project), 'By  / Český závod / ');
      engine.execute([SetSheetDocumentFields('s', {})]);
      expect(_bound(engine.project), 'By Jiří / Český závod / ');
    },
  );

  test(
    'page binding uses caller physical counts, full designation and mounting scale',
    () {
      final template = _withText(
        '{{sheet.designation}}|{{sheet.number}}|{{sheet.documentCode}}|{{sheet.type}}|{{page.number}}|{{page.index}}/{{page.count}}|{{page.inSheet}}/{{page.sheetCount}}|{{view.scale}}',
      );
      final sheet = _project().pages.first.copyWith(
        structure: StructureContext(locationPath: ['A']),
        documentCode: 'EL',
        type: SheetType.cabinetLayout,
        mountingView: const MountingView(
          layoutId: 'cabinet',
          viewport: RectUnits(x: 50, y: 50, width: 100, height: 100),
          scaleDenominator: 2.5,
        ),
      );
      final p = _project().copyWith(frameTemplates: [template], pages: [sheet]);
      expect(
        _bound(
          p,
          context: const FramePageContext(
            number: '+A&EL/01.2',
            documentIndex: 4,
            documentCount: 7,
            sheetPageIndex: 2,
            sheetPageCount: 3,
          ),
        ),
        '+A&EL/01|01|EL|cabinetLayout|+A&EL/01.2|4/7|2/3|1:2.5',
      );
      expect(
        () => _bound(
          p,
          context: const FramePageContext(
            number: '1',
            documentIndex: 0,
            documentCount: 1,
          ),
        ),
        throwsA(_error('invalid_frame_context')),
      );
    },
  );

  test(
    'binding is not recursive and drawing revision is independent of engine revision',
    () {
      final p = _project().copyWith(
        frameTemplates: [
          _withText('{{document.drawingRevision}}|{{document.drawnBy}}'),
        ],
        documentFields: {'drawingRevision': 'B', 'drawnBy': '{{project.name}}'},
      );
      final engine = ProjectEngine(p);
      engine.execute([const RenameProject('Changed')]);
      expect(_bound(engine.project), 'B|{{project.name}}');
      engine.undo();
      expect(engine.project.revision, 2);
      expect(_bound(engine.project), 'B|{{project.name}}');
      engine.redo();
      expect(_bound(engine.project), 'B|{{project.name}}');
      for (final text in [
        '{{project.revision}}',
        '{{document.a.b}}',
        '{{env.HOME}}',
        '{{sheet.name}',
        '{{project.name }}',
        '{{}}',
      ]) {
        expect(
          () => _withText(text).validate(),
          throwsA(_error('invalid_frame_binding')),
          reason: text,
        );
      }
    },
  );

  test(
    'A3/A4 layout uses physical dimensions and reserves the whole bottom band',
    () {
      for (final paper in [SizeMm.a3Landscape, SizeMm.a4Landscape]) {
        final p = _project().copyWith(
          pages: [_project().pages.first.copyWith(paperSizeMm: paper)],
        );
        final geometry = _geometry(p);
        expect(geometry.borderRectMm!.x, 10);
        expect(geometry.titleBlockRectMm!.width, 180);
        expect(geometry.titleBlockRectMm!.right, paper.width - 10);
        expect(geometry.contentRectMm.toJson(), {
          'x': 13.0,
          'y': 13.0,
          'width': paper.width - 26,
          'height': paper.height - 62,
        });
        expect(geometry.titleFieldSlots.first.rectMm.x, paper.width - 188);
        for (final slot in [
          ...geometry.titleFieldSlots,
          ...geometry.zoneLabelSlots,
        ]) {
          expect(slot.rectMm.x, greaterThanOrEqualTo(0));
          expect(slot.rectMm.y, greaterThanOrEqualTo(0));
          expect(slot.rectMm.right, lessThanOrEqualTo(paper.width));
          expect(slot.rectMm.bottom, lessThanOrEqualTo(paper.height));
        }
      }
    },
  );

  test(
    'part switches affect paint independently while margins always reserve content',
    () {
      final t = FrameTemplates.builtin;
      final base = layoutFrameGeometry(SizeMm.a3Landscape, ResolvedFrame(t));
      final borderOff = layoutFrameGeometry(
        SizeMm.a3Landscape,
        ResolvedFrame(t, border: false),
      );
      expect(borderOff.contentRectMm.toJson(), base.contentRectMm.toJson());
      expect(borderOff.strokesMm.length, base.strokesMm.length - 4);
      expect(borderOff.zoneLabelSlots, isNotEmpty);
      final titleOff = layoutFrameGeometry(
        SizeMm.a3Landscape,
        ResolvedFrame(t, titleBlock: false),
      );
      expect(titleOff.contentRectMm.height, base.contentRectMm.height + 36);
      expect(titleOff.titleFieldSlots, isEmpty);
      final allOff = layoutFrameGeometry(
        SizeMm.a3Landscape,
        ResolvedFrame(t, border: false, titleBlock: false, zones: false),
      );
      expect(allOff.strokesMm, isEmpty);
      expect(allOff.contentRectMm.x, 13);
      expect(allOff.contentRectMm.width, 394);
    },
  );

  test(
    'mismatched paper aspect uses existing centered transform without altering scale',
    () {
      final sheet = _project().pages.first.copyWith(
        width: 1000,
        height: 1000,
        paperSizeMm: SizeMm.a4Landscape,
        mountingView: const MountingView(
          layoutId: 'layout',
          viewport: RectUnits(x: 100, y: 100, width: 600, height: 600),
          scaleDenominator: 4,
        ),
      );
      final p = _project().copyWith(pages: [sheet]);
      final transform = SheetTransform(sheet);
      final units = frameContentUnits(sheet, _geometry(p));
      expect(units.x, lessThan(0));
      expect(transform.toPaperMm(units.topLeft), const Vec2(13, 13));
      final before = MountingTransform(sheet, sheet.mountingView!);
      final changed = sheet.copyWith(frame: const FrameChoice.none());
      expect(
        MountingTransform(changed, changed.mountingView!).unitsPerMm,
        before.unitsPerMm,
      );
      expect(transform.mmPerUnit, 0.21);
      final full = frameContentUnits(changed, _geometry(p, changed));
      expect(full.x, closeTo(transform.paperBoundsUnits.x, 1e-9));
      expect(full.y, closeTo(transform.paperBoundsUnits.y, 1e-9));
      expect(full.width, closeTo(transform.paperBoundsUnits.width, 1e-9));
      expect(full.height, closeTo(transform.paperBoundsUnits.height, 1e-9));
      expect(
        () => frameContentUnits(
          sheet,
          layoutFrameGeometry(SizeMm.a3Landscape, null),
        ),
        throwsA(_error('invalid_frame_layout')),
      );
    },
  );

  test(
    'template/default/field commands share one transaction, stale guard and history',
    () {
      final engine = ProjectEngine(_project());
      final clone = FrameTemplates.builtin.copyWith(
        id: 'custom',
        name: 'Custom',
      );
      final commands = <EcadCommand>[
        AddFrameTemplate(clone),
        const SetProjectFrame(FrameChoice.template('custom')),
        const SetSheetFrame('s', FrameChoice.inherit(zones: false)),
        SetProjectDocumentFields({'drawingRevision': 'C'}),
        SetSheetDocumentFields('s', {'checkedBy': 'Z'}),
      ];
      final decoded = decodeCommands(
        jsonDecode(jsonEncode(commands.map((c) => c.toJson()).toList())),
      );
      engine.execute(decoded, expectedRevision: 0, label: 'Frame');
      final after = engine.project;
      expect(after.revision, 1);
      expect(resolveSheetFrame(after, after.pages.single)!.zones, isFalse);
      expect(after.documentFields['drawingRevision'], 'C');
      expect(after.pages.single.documentFields['checkedBy'], 'Z');
      expect(
        () => engine.execute([
          const SetProjectFrame(FrameChoice.none()),
        ], expectedRevision: 0),
        throwsA(_error('stale_revision')),
      );
      expect(engine.project, same(after));
      engine.undo();
      expect(engine.project.frameTemplates, hasLength(1));
      expect(engine.project.documentFields, isEmpty);
      expect(engine.project.pages.first.documentFields, isEmpty);
      engine.redo();
      expect(engine.project.toJson(), after.copyWith(revision: 3).toJson());
    },
  );

  test(
    'live references block deletion; reassignment in the same batch is atomic',
    () {
      final engine = ProjectEngine(_project());
      final before = engine.project;
      expect(
        () => engine.execute([
          const DeleteFrameTemplate(FrameTemplates.builtinId),
        ]),
        throwsA(_error('missing_frame_template')),
      );
      expect(engine.project, same(before));
      expect(engine.canUndo, isFalse);
      engine.execute([
        const DeleteFrameTemplate(FrameTemplates.builtinId),
        AddFrameTemplate(FrameTemplates.builtin.copyWith(id: 'replacement')),
        const SetProjectFrame(FrameChoice.template('replacement')),
        const SetSheetFrame('s', FrameChoice.template('replacement')),
      ]);
      expect(engine.project.frameTemplates.single.id, 'replacement');
      engine.undo();
      expect(engine.project.defaultFrame.templateId, FrameTemplates.builtinId);
      engine.redo();
      engine.execute([const SetProjectFrame(FrameChoice.none())]);
      expect(
        () => engine.execute([const DeleteFrameTemplate('replacement')]),
        throwsA(_error('missing_frame_template')),
      );
    },
  );

  test(
    'shared edits affect all inheriting sheets; explicit clones stay independent',
    () {
      final p = _project();
      final clone = FrameTemplates.builtin.copyWith(id: 'clone');
      final engine = ProjectEngine(
        p.copyWith(
          frameTemplates: [...p.frameTemplates, clone],
          pages: [
            p.pages.first,
            Sheet(id: 's2', name: 'Second', number: '02'),
            Sheet(
              id: 's3',
              name: 'Clone',
              number: '03',
              frame: const FrameChoice.template('clone'),
            ),
          ],
        ),
      );
      engine.execute([
        UpdateFrameTemplate(
          FrameTemplates.builtin.copyWith(contentPaddingMm: 7),
        ),
      ]);
      expect(
        engine.project.pages.map(
          (s) => _geometry(engine.project, s).contentRectMm.x,
        ),
        [17, 17, 13],
      );
      expect(
        engine.project.pages.map((s) => s.graphics),
        everyElement(isEmpty),
      );
    },
  );

  test(
    'referenced shared template edit must fit every actual paper and rollback',
    () {
      final engine = ProjectEngine(
        _project().copyWith(
          pages: [
            _project().pages.first,
            Sheet(
              id: 'a4',
              name: 'A4',
              number: '2',
              paperSizeMm: SizeMm.a4Landscape,
            ),
          ],
        ),
      );
      final before = engine.project;
      final wider = FrameTemplates.builtin.copyWith(
        titleBlock: FrameTemplates.builtin.titleBlock.copyWith(widthMm: 300),
      );
      expect(
        () => engine.execute([
          const RenameProject('Must rollback'),
          UpdateFrameTemplate(wider),
        ]),
        throwsA(_error('invalid_frame_layout')),
      );
      expect(engine.project, same(before));
      expect(engine.canUndo, isFalse);
      engine.execute([
        const SetSheetFrame('a4', FrameChoice.none()),
        UpdateFrameTemplate(wider),
      ]);
      expect(engine.project.frameTemplates.single.titleBlock.widthMm, 300);
      expect(
        () =>
            engine.execute([const SetSheetFrame('a4', FrameChoice.inherit())]),
        throwsA(_error('invalid_frame_layout')),
      );
    },
  );

  test('ordinary sheet/structure/graphic commands preserve frame metadata', () {
    final engine = ProjectEngine(_project());
    engine.execute([
      const SetSheetFrame('s', FrameChoice.inherit(border: false)),
      SetSheetDocumentFields('s', {'drawnBy': 'A'}),
      SetProjectDocumentFields({'drawingRevision': 'A'}),
    ]);
    engine.execute([
      const RenameSheet('s', 'New'),
      const SetSheetType('s', SheetType.form),
      AddGraphics('s', SheetTemplates.blankForm()),
      AddSheet(Sheet(id: 's2', name: 'Next', number: '2')),
      ReorderSheets(['s2', 's']),
      const DeleteSheet('s2'),
    ]);
    final s = engine.project.pages.single;
    expect(s.frame.border, isFalse);
    expect(s.documentFields, {'drawnBy': 'A'});
    expect(engine.project.documentFields, {'drawingRevision': 'A'});
    expect(s.graphics, isNotEmpty);
    engine.execute([UpdateSheet(s.copyWith(number: '9'))]);
    expect(engine.project.pages.single.frame.toJson(), s.frame.toJson());
  });

  test(
    'strict choices, missing definitions and duplicate IDs reject instead of fallback',
    () {
      for (final choice in [
        {'mode': 'template'},
        {'mode': 'none', 'zones': false},
        {'mode': 'inherit', 'templateId': 'x'},
        {'mode': 'inherit', 'border': 1},
        {'mode': 'inherit', 'extra': 1},
        {'mode': 'other'},
      ]) {
        expect(
          () => FrameChoice.fromJson(choice),
          throwsA(isA<EcadException>()),
        );
      }
      final p = _project();
      expect(
        () => requireValidProject(
          p.copyWith(defaultFrame: const FrameChoice.inherit()),
        ),
        throwsA(_error('invalid_frame_choice')),
      );
      expect(
        () => requireValidProject(p.copyWith(frameTemplates: [])),
        throwsA(_error('missing_frame_template')),
      );
      expect(
        () => requireValidProject(
          p.copyWith(
            frameTemplates: [FrameTemplates.builtin, FrameTemplates.builtin],
          ),
        ),
        throwsA(_error('duplicate_id')),
      );
      expect(
        () => EcadProject.fromJson(p.toJson()..remove('frameTemplates')),
        throwsA(isA<EcadException>()),
      );
      expect(
        () => EcadProject.fromJson(p.toJson()..remove('defaultFrame')),
        throwsA(isA<EcadException>()),
      );
      expect(
        () => FrameTemplate.fromJson({
          ...FrameTemplates.builtin.toJson(),
          'foreign': true,
        }),
        throwsA(_error('invalid_schema')),
      );
    },
  );

  test(
    'programmatic and JSON templates enforce finite geometry, local bounds, IDs and fonts',
    () {
      final t = FrameTemplates.builtin;
      final block = t.titleBlock;
      final invalid = [
        t.copyWith(id: ''),
        t.copyWith(name: ''),
        t.copyWith(contentPaddingMm: double.nan),
        t.copyWith(strokeWidthMm: double.infinity),
        t.copyWith(strokeWidthMm: 0),
        t.copyWith(marginsMm: const FrameMargins(left: -1)),
        t.copyWith(zones: const FrameZones(rows: 0)),
        t.copyWith(zones: const FrameZones(columns: 101)),
        t.copyWith(zones: const FrameZones(tickMm: 8)),
        t.copyWith(
          titleBlock: block.copyWith(
            lines: [const FrameLine(Vec2(-1, 0), Vec2(1, 1))],
          ),
        ),
        t.copyWith(
          titleBlock: block.copyWith(
            fields: [block.fields.first, block.fields.first],
          ),
        ),
        t.copyWith(
          titleBlock: block.copyWith(
            fields: [
              block.fields.first.copyWith(
                rectMm: const RectMm(x: 179, y: 0, width: 2, height: 8),
              ),
            ],
          ),
        ),
        t.copyWith(
          titleBlock: block.copyWith(
            fields: [block.fields.first.copyWith(minFontSizeMm: 5)],
          ),
        ),
        t.copyWith(
          titleBlock: block.copyWith(
            fields: [block.fields.first.copyWith(fontSizeMm: double.nan)],
          ),
        ),
      ];
      for (final candidate in invalid) {
        expect(candidate.validate, throwsA(isA<EcadException>()));
        expect(
          () => FrameTemplate.fromJson(candidate.toJson()),
          throwsA(isA<EcadException>()),
        );
        expect(
          () => requireValidProject(
            _project().copyWith(frameTemplates: [candidate]),
          ),
          throwsA(isA<EcadException>()),
        );
      }
    },
  );

  test(
    'tiny layouts and exterior zones outside paper reject without implicit shrinking',
    () {
      final t = FrameTemplates.builtin;
      expect(
        () => layoutFrameGeometry(
          const SizeMm(width: 100, height: 100),
          ResolvedFrame(t),
        ),
        throwsA(_error('invalid_frame_layout')),
      );
      expect(
        () => layoutFrameGeometry(
          const SizeMm(width: 210, height: 62),
          ResolvedFrame(t),
        ),
        throwsA(_error('invalid_frame_layout')),
      );
      final margins = t.copyWith(marginsMm: const FrameMargins(left: 3));
      expect(
        () => layoutFrameGeometry(SizeMm.a3Landscape, ResolvedFrame(margins)),
        throwsA(_error('invalid_frame_layout')),
      );
      expect(
        layoutFrameGeometry(
          SizeMm.a3Landscape,
          ResolvedFrame(margins, zones: false),
        ).contentRectMm.x,
        6,
      );
      expect(
        () => layoutFrameGeometry(
          const SizeMm(width: double.nan, height: 100),
          null,
        ),
        throwsA(_error('invalid_frame_layout')),
      );
    },
  );

  test(
    'field bags and template text/counts have per-item and aggregate budgets',
    () {
      for (final fields in [
        {'bad.key': 'x'},
        {'a': 'x' * (FrameLimits.text + 1)},
        {'a': '\u0000'},
        {for (var i = 0; i <= FrameLimits.documentFields; i++) 'k$i': 'v'},
        {for (var i = 0; i < 32; i++) 'k$i': 'x' * FrameLimits.text},
      ]) {
        expect(
          () => validateDocumentFields(fields),
          throwsA(isA<EcadException>()),
        );
        expect(
          () => decodeDocumentFields(fields),
          throwsA(isA<EcadException>()),
        );
      }
      final t = FrameTemplates.builtin;
      expect(
        () =>
            t
                .copyWith(
                  titleBlock: t.titleBlock.copyWith(
                    lines: List.filled(257, t.titleBlock.lines.first),
                  ),
                )
                .validate(),
        throwsA(_error('limit_exceeded')),
      );
      expect(
        () => _withText('x' * (FrameLimits.text + 1)).validate(),
        throwsA(_error('limit_exceeded')),
      );
      final large = _project().copyWith(
        documentFields: {
          for (var i = 0; i < 10; i++) 'k$i': 'x' * FrameLimits.text,
        },
      );
      expect(
        () => requireValidProject(
          large.copyWith(
            pages: [
              for (var i = 0; i < 60; i++)
                Sheet(
                  id: 's$i',
                  name: 'S',
                  number: '$i',
                  documentFields: large.documentFields,
                ),
            ],
          ),
        ),
        throwsA(_error('limit_exceeded')),
      );
      expect(
        () => _bound(
          _project().copyWith(
            frameTemplates: [_withText('{{document.large}}' * 100)],
            documentFields: {'large': 'x' * 2048},
          ),
        ),
        throwsA(_error('limit_exceeded')),
      );
    },
  );
}
