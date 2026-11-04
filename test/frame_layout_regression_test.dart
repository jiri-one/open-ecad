// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/services/document_layout.dart';
import 'package:open_ecad/services/export_fonts.dart';
import 'package:open_ecad/services/report_layout.dart';
import 'package:open_ecad/services/schematic_annotations.dart';

EcadProject _schematic({
  bool nearEdge = false,
  bool reference = false,
  String description = '',
}) {
  final template = FrameTemplates.builtin.copyWith(
    marginsMm: const FrameMargins(right: 80),
  );
  final blank = Sheet(id: 'sheet', name: 'Sheet', number: '1');
  final content = frameContentUnits(
    blank,
    layoutFrameGeometry(blank.paperSizeMm, ResolvedFrame(template)),
  );
  final seed = createBuiltinComponent(
    componentId: 'component',
    deviceId: 'device',
    kind: DeviceKind.supply,
    designation: '-P1',
    position: const Vec2(200, 200),
  );
  final device = seed.device.copyWith(
    position: Vec2(
      nearEdge
          ? content.x + content.width - geometryFor(seed.device).width / 2 - 2
          : 200,
      200,
    ),
  );
  return EcadProject(
    id: 'annotations',
    name: 'Synthetic',
    frameTemplates: [template],
    components: [seed.component.copyWith(description: description)],
    pages: [
      blank.copyWith(devices: [device]),
      if (reference)
        Sheet(
          id: 'second',
          name: 'Second',
          number: '2',
          devices: [
            seed.device.copyWith(id: 'peer', mode: OccurrenceMode.reference),
          ],
        ),
    ],
  );
}

EcadProject _reportProject() {
  final project = _schematic();
  return project.copyWith(
    pages: [
      ...project.pages,
      Sheet(
        id: 'bom',
        name: 'Components',
        number: 'B1',
        type: SheetType.billOfMaterials,
        report: const BomTableSpec(kind: BomReportKind.components),
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ExportFonts.load);

  test(
    'diagnostics include cross references and port text beyond symbol body',
    () {
      final project = _schematic(nearEdge: true, reference: true);
      final sheet = project.pages.first;
      final page = layoutDocument(project).firstPageFor(sheet.id);
      final reference =
          layoutDeviceCrossReferences(
            ProjectResolver(project),
            sheet.devices.single,
          ).single;
      expect(
        SheetTransform(
          sheet,
        ).toPaperMm(Vec2(reference.bounds.left, reference.bounds.top)).x,
        greaterThan(page.frame.source.geometry.borderRectMm!.right),
      );
      expect(page.diagnostics, isNotEmpty);
      expect(
        layoutDocument(
          _schematic(reference: true),
        ).pages.every((p) => p.diagnostics.isEmpty),
        isTrue,
      );
    },
  );

  test('long device description warns even when geometry and ports fit', () {
    final project = _schematic(
      description: List.filled(50, 'description').join(' '),
    );
    expect(layoutDocument(project).pages.single.diagnostics, isNotEmpty);
    expect(layoutDocument(_schematic()).pages.single.diagnostics, isEmpty);
  });

  test(
    'continuation labels and rotated glyphs are included in diagnostics',
    () {
      for (final direction in PortSide.values) {
        final blank = Sheet(id: 's', name: 'Sheet', number: '1');
        final area = frameContentUnits(
          blank,
          layoutFrameGeometry(
            blank.paperSizeMm,
            ResolvedFrame(FrameTemplates.builtin),
          ),
        );
        EcadProject at(double x) => EcadProject(
          id: 'markers',
          name: 'Markers',
          continuationLinks: const [
            ContinuationLink(id: 'link', label: 'Continuation'),
          ],
          pages: [
            blank.copyWith(
              continuations: [
                ContinuationMarker(
                  id: 'marker',
                  linkId: 'link',
                  position: Vec2(x, 200),
                  direction: direction,
                  glyph: ContinuationGlyph.earth,
                ),
              ],
            ),
          ],
        );
        expect(
          layoutDocument(at(area.x + area.width - 35)).pages.single.diagnostics,
          isNotEmpty,
        );
        expect(layoutDocument(at(200)).pages.single.diagnostics, isEmpty);
      }
    },
  );

  test(
    'frame preview repaginates cached report data when content height changes',
    () {
      final source = _reportProject().copyWith(
        components: [
          ..._reportProject().components,
          for (var i = 0; i < 100; i++)
            Component(
              id: 'material-$i',
              kind: ComponentKind.material,
              description: 'Material $i',
            ),
        ],
        pages: [
          Sheet(
            id: 'bom',
            name: 'Components',
            number: 'B1',
            type: SheetType.billOfMaterials,
            report: const BomTableSpec(kind: BomReportKind.components),
          ),
        ],
      );
      final original = layoutDocument(source);
      final template = source.frameTemplates.single;
      final candidate = source.copyWith(
        frameTemplates: [
          template.copyWith(
            titleBlock: template.titleBlock.copyWith(heightMm: 140),
          ),
        ],
      );
      final preview = previewDocumentFrames(candidate, source: source);
      expect(preview.pages.length, greaterThan(original.pages.length));
      expect(preview.reports['bom']!.data, same(original.reports['bom']!.data));
      expect(preview.pages.length, layoutDocument(candidate).pages.length);
    },
  );

  test('fresh and demo mounting sheets keep captions inside frame content', () {
    final app = EditorController(startEmpty: true);
    addTearDown(app.dispose);
    app.addSheet(type: SheetType.cabinetLayout, name: 'Mounting');
    expect(app.configureMounting(width: 600, height: 800, scale: 5), isTrue);
    final view = app.sheet.mountingView!;
    expect(view.scaleDenominator, 5);
    expect(
      layoutDocument(app.project).firstPageFor(app.sheet.id).diagnostics,
      isEmpty,
    );
    expect(
      layoutDocument(
        DemoProject.create(),
      ).firstPageFor('sheet_mounting').diagnostics,
      isEmpty,
    );
  });

  test('report pagination reuses pages after device moves and field drags', () {
    final project = _reportProject();
    final original = layoutReport(project, project.pages.last);
    final moved = project.copyWith(
      revision: 1,
      pages: [
        project.pages.first.copyWith(
          devices: [
            project.pages.first.devices.single.copyWith(
              position: const Vec2(250, 220),
            ),
          ],
        ),
        project.pages.last,
      ],
    );
    final movedReport = layoutReport(moved, moved.pages.last);
    expect(movedReport.pages.first, same(original.pages.first));
    expect(movedReport.data.sourceRevision, 1);
    final template = project.frameTemplates.single;
    final fields = template.titleBlock.fields;
    final dragged = moved.copyWith(
      frameTemplates: [
        template.copyWith(
          titleBlock: template.titleBlock.copyWith(
            fields: [
              fields.first.copyWith(
                rectMm: RectMm(
                  x: fields.first.rectMm.x + 1,
                  y: fields.first.rectMm.y,
                  width: fields.first.rectMm.width - 1,
                  height: fields.first.rectMm.height,
                ),
              ),
              ...fields.skip(1),
            ],
          ),
        ),
      ],
    );
    expect(
      layoutReport(dragged, dragged.pages.last).pages.first,
      same(original.pages.first),
    );
    final extraSheet = dragged.copyWith(
      pages: [...dragged.pages, Sheet(id: 'extra', name: 'Extra', number: '3')],
    );
    expect(
      layoutDocument(extraSheet).pages.length,
      layoutDocument(project).pages.length + 1,
    );
  });

  test('report cache invalidates all table and page inputs', () {
    final project = _reportProject();
    final sheet = project.pages.last;
    final original = layoutReport(project, sheet);
    final variants = [
      project.copyWith(
        components: [
          project.components.single.copyWith(
            description: 'Changed description',
          ),
        ],
      ),
      project.copyWith(
        components: [
          project.components.single,
          Component(
            id: 'material',
            kind: ComponentKind.material,
            quantity: const Quantity.pieces(3),
          ),
        ],
      ),
      project.copyWith(
        pages: [project.pages.first, sheet.copyWith(name: 'New heading')],
      ),
      project.copyWith(
        pages: [project.pages.first, sheet.copyWith(number: 'B2')],
      ),
      project.copyWith(
        pages: [
          project.pages.first,
          sheet.copyWith(
            report: const BomTableSpec(
              kind: BomReportKind.components,
              note: 'A note',
            ),
          ),
        ],
      ),
      project.copyWith(
        pages: [
          project.pages.first,
          sheet.copyWith(
            frame: const FrameChoice.template(
              FrameTemplates.builtinId,
              titleBlock: false,
            ),
          ),
        ],
      ),
      project.copyWith(
        pages: [
          project.pages.first,
          sheet.copyWith(paperSizeMm: SizeMm.a4Landscape),
        ],
      ),
    ];
    for (final candidate in variants) {
      final result = layoutReport(candidate, candidate.pages.last);
      expect(result.pages.first, isNot(same(original.pages.first)));
    }
    final changed = layoutReport(variants.first, variants.first.pages.last);
    expect(
      changed.data.rows.single.cells.first,
      contains('Changed description'),
    );
  });

  test('preview caching never bypasses full export validation', () {
    final valid = _reportProject();
    layoutDocument(valid);
    final invalid = valid.copyWith(
      pages: [valid.pages.first, valid.pages.first],
    );
    previewDocumentFrames(invalid, source: valid);
    expect(() => layoutDocument(invalid), throwsA(isA<EcadException>()));
  });
}
