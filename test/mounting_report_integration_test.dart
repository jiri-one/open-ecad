// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/export_fonts.dart';
import 'package:open_ecad/services/mounting_annotations.dart';
import 'package:open_ecad/services/project_export.dart';
import 'package:open_ecad/services/report_layout.dart';

EcadProject denseTerminals(double denominator, {double rotation = 0}) =>
    EcadProject(
      id: 'synthetic',
      name: 'Dense terminals',
      articles: const [
        Article(
          id: 'article',
          name: 'Test terminal',
          unit: QuantityUnit.piece,
          dimensionsMm: DimensionsMm(width: 6.4, height: 55),
        ),
      ],
      components: [
        for (var i = 0; i < 24; i++)
          Component(
            id: 'c$i',
            designation: '-TEST:${i + 100}',
            articleId: 'article',
          ),
      ],
      mountingLayouts: [
        MountingLayout(
          id: 'layout',
          name: 'Panel',
          widthMm: 300,
          heightMm: 220,
          placements: [
            for (var i = 0; i < 24; i++)
              MountingPlacement(
                id: 'p$i',
                componentId: 'c$i',
                centerMm:
                    rotation == 0
                        ? Vec2(35 + 6.4 * i, 110)
                        : Vec2(100, 35 + 6.4 * i),
                rotation: rotation,
              ),
          ],
        ),
      ],
      pages: [
        Sheet(
          id: 'sheet',
          name: 'Mounting',
          number: '01',
          type: SheetType.cabinetLayout,
          mountingView: MountingView(
            layoutId: 'layout',
            viewport: const RectUnits(x: 20, y: 60, width: 1000, height: 650),
            scaleDenominator: denominator,
          ),
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ExportFonts.load);
  for (final denominator in [1.0, 2.0]) {
    for (final rotation in [0.0, 90.0]) {
      test(
        'dense mounting names remain complete and disjoint at 1:$denominator rotation $rotation',
        () async {
          final p = denseTerminals(denominator, rotation: rotation);
          requireValidProject(p);
          final before = jsonEncode(p.toJson());
          final resolver = ProjectResolver(p);
          final sheet = p.pages.single;
          final annotations = layoutMountingAnnotations(resolver, sheet);
          expect(annotations, hasLength(24));
          expect(
            annotations.map((a) => a.text).toSet(),
            p.components.map((c) => c.designation).toSet(),
          );
          final vp = sheet.mountingView!.viewport;
          final viewport = ui.Rect.fromLTWH(vp.x, vp.y, vp.width, vp.height);
          for (var i = 0; i < annotations.length; i++) {
            final a = annotations[i];
            expect(viewport.contains(a.bounds.topLeft), isTrue);
            expect(viewport.contains(a.bounds.bottomRight), isTrue);
            for (final other in annotations.skip(i + 1)) {
              expect(
                a.bounds.overlaps(other.bounds),
                isFalse,
                reason: '${a.text} / ${other.text}',
              );
            }
          }
          if (denominator == 2) {
            expect(annotations.any((a) => a.leaderStart != null), isTrue);
          }
          final exporter = ProjectExportService();
          final svg = exporter.svg(p);
          for (final a in annotations) {
            expect(svg, contains('data-mounting-label="${a.placementId}"'));
            expect(RegExp('>${a.text}</text>').allMatches(svg), hasLength(1));
          }
          final recorder = ui.PictureRecorder();
          paintMountingAnnotations(ui.Canvas(recorder), annotations);
          recorder.endRecording().dispose();
          expect(await exporter.pdf(p), isNotEmpty);
          expect(jsonEncode(p.toJson()), before);
          expect(resolver.dimensionsFor(p.components.first).width, 6.4);
          expect(
            resolver
                .mountingBounds(p.mountingLayouts.single.placements.first)!
                .width,
            closeTo(rotation == 0 ? 6.4 : 55, 1e-9),
          );
        },
      );
    }
  }

  test(
    'report quantity cells use comma across UI layout, SVG and CSV; JSON and text keep dots',
    () async {
      final p = EcadProject(
        id: 'p',
        name: 'Report',
        articles: const [
          Article(
            id: 'a',
            name: 'Cable 2.75',
            unit: QuantityUnit.metre,
            manufacturer: 'Maker.1',
            partNumber: 'CODE.2.75',
          ),
        ],
        components: [
          Component(
            id: 'c',
            kind: ComponentKind.material,
            articleId: 'a',
            quantity: Quantity.parse(QuantityUnit.metre, '2.75'),
            note: 'Text 2.75',
          ),
          const Component(
            id: 'unknown',
            kind: ComponentKind.material,
            articleId: 'a',
            quantity: Quantity.millimetres(null),
          ),
        ],
        pages: [
          for (final kind in BomReportKind.values)
            Sheet(
              id: kind.name,
              name: kind.name,
              number: kind == BomReportKind.articles ? '01' : '02',
              type: SheetType.billOfMaterials,
              report: BomTableSpec(kind: kind),
            ),
        ],
      );
      final exporter = ProjectExportService();
      for (final sheet in p.pages) {
        final data = buildReport(p, sheet);
        final texts =
            layoutReport(
              p,
              sheet,
            ).pages.expand((p) => p.texts).map((t) => t.text).toList();
        final quantity =
            sheet.report!.kind == BomReportKind.articles
                ? '2,75 + neurčeno'
                : '2,75';
        expect(data.rows.expand((r) => r.cells), contains(quantity));
        expect(texts, contains(quantity));
        expect(
          exporter.svg(p, sheetId: sheet.id),
          contains('>$quantity</text>'),
        );
        expect(exporter.csv(p, sheetId: sheet.id), contains('"$quantity"'));
        expect(
          texts,
          contains(
            sheet.report!.kind == BomReportKind.articles
                ? 'CODE.2.75'
                : 'Text 2.75',
          ),
        );
      }
      expect(await exporter.pdf(p), isNotEmpty);
      expect(p.components.first.quantity.amount, '2.75');
      expect(p.components.first.quantity.toJson()['amount'], '2.75');
      expect(
        EcadProject.fromJson(jsonDecode(jsonEncode(p.toJson()))).toJson(),
        p.toJson(),
      );
    },
  );
}
