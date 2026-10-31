// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

EcadProject _project() => EcadProject(
  id: 'p',
  name: 'P',
  pages: [Sheet(id: 's', name: 'S', number: '1')],
);
void main() {
  test('all sheet kinds round-trip explicit paper and compatible content', () {
    for (final type in SheetType.values) {
      final p = _project().copyWith(
        pages: [
          Sheet(
            id: 's',
            name: 'S',
            number: '1',
            type: type,
            report:
                type == SheetType.billOfMaterials
                    ? const BomTableSpec(kind: BomReportKind.articles)
                    : null,
          ),
        ],
      );
      final restored = EcadProject.fromJson(jsonDecode(jsonEncode(p.toJson())));
      requireValidProject(restored);
      expect(restored.toJson(), p.toJson());
    }
  });
  test('type change cannot silently hide schematic or report content', () {
    final engine = ProjectEngine(DemoProject.create());
    final before = engine.project;
    expect(
      () => engine.execute([
        const SetSheetType('sheet_control', SheetType.cabinetLayout),
      ]),
      throwsA(isA<EcadException>()),
    );
    expect(engine.project, same(before));
    expect(
      () => engine.execute([const SetSheetType('sheet_bom', SheetType.form)]),
      throwsA(isA<EcadException>()),
    );
    expect(
      () => engine.execute([
        AddGraphics('sheet_bom', SheetTemplates.blankForm()),
      ]),
      throwsA(isA<EcadException>()),
    );
  });
  test(
    'renumber and reorder retain link targets; report numbers are reserved',
    () {
      final engine = ProjectEngine(DemoProject.create());
      final marker = engine.project.pages.first.continuations.first;
      engine.execute([
        UpdateSheet(engine.project.pages[1].copyWith(number: '99')),
        ReorderSheets(engine.project.pages.reversed.map((s) => s.id).toList()),
      ]);
      expect(
        ProjectResolver(
          engine.project,
        ).continuationTargets(marker).single.sheet.number,
        '99',
      );
      expect(
        () => engine.execute([
          AddSheet(Sheet(id: 'collision', name: 'S', number: 'B01.2')),
        ]),
        throwsA(isA<EcadException>()),
      );
      final before = engine.project;
      expect(
        () => engine.execute([
          ReorderSheets(['sheet_control']),
        ]),
        throwsA(isA<EcadException>()),
      );
      expect(engine.project, same(before));
    },
  );
  group('blank form starter', () {
    test('creates valid editable graphics inside the drawing area', () {
      final graphics = SheetTemplates.blankForm();
      for (final graphic in graphics) {
        requireValidDrawingElement(graphic);
        expect(graphic.position.x, greaterThanOrEqualTo(65));
        expect(graphic.position.y, greaterThanOrEqualTo(114));
        expect(graphic.position.x + graphic.width, lessThanOrEqualTo(1035));
        expect(graphic.position.y + graphic.height, lessThan(674));
      }
      expect(
        graphics
            .where((graphic) => graphic.kind == DrawingKind.text)
            .map((graphic) => graphic.text),
        SheetTemplates.formColumns.map((column) => column.$1),
      );
      expect(
        SheetTemplates.formColumns.fold<double>(0, (sum, c) => sum + c.$2),
        closeTo(1, 1e-9),
      );
      expect(
        graphics.where((graphic) => graphic.kind == DrawingKind.path),
        hasLength(
          1 + SheetTemplates.formRows + SheetTemplates.formColumns.length - 1,
        ),
      );
    });

    test('two starters can coexist and stay one undoable page', () {
      final engine = ProjectEngine(_project());
      for (final id in ['sheet_form_a', 'sheet_form_b']) {
        engine.execute([
          AddSheet(
            Sheet(
              id: id,
              name: 'Formulář',
              number: id,
              type: SheetType.form,
              graphics: SheetTemplates.blankForm(),
            ),
          ),
        ]);
      }
      final ids = engine.project.pages
          .expand((sheet) => sheet.graphics)
          .map((graphic) => graphic.id);
      expect(ids.toSet(), hasLength(ids.length));
      expect(engine.project.pages.last.devices, isEmpty);
      expect(engine.project.pages.last.wires, isEmpty);
      engine.undo();
      expect(engine.project.pages, hasLength(2));
      expect(engine.project.pages.last.type, SheetType.form);
    });
  });
}
