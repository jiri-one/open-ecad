// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    test(
      'BOM mounting references respect crop and rotated bodies at 1:$scale',
      () {
        final sheet = Sheet(
          id: 'crop',
          name: 'Detail',
          number: '02',
          type: SheetType.cabinetLayout,
          width: 1000,
          height: 1000,
          paperSizeMm: const SizeMm(width: 200, height: 200),
          mountingView: MountingView(
            layoutId: 'layout',
            originMm: const Vec2(50, 80),
            viewport: RectUnits(
              x: 70,
              y: 90,
              width: 200 / scale,
              height: 200 / scale,
            ),
            scaleDenominator: scale,
          ),
        );
        final items = [
          ('inside', const Vec2(60, 90), 0.0, true),
          ('outside', const Vec2(25, 90), 0.0, false),
          ('partial', const Vec2(48, 105), 0.0, true),
          ('touching', const Vec2(45, 100), 0.0, false),
          ('rotated_in', const Vec2(60, 123), 90.0, true),
          ('rotated_out', const Vec2(60, 127), 90.0, false),
          ('right_partial', const Vec2(94, 115), 0.0, true),
        ];
        final p = EcadProject(
          id: 'project',
          name: 'Crop test',
          components: [
            for (final item in items)
              Component(
                id: item.$1,
                designation: '-${item.$1}',
                mountingSizeOverrideMm: const DimensionsMm(
                  width: 10,
                  height: 4,
                ),
              ),
          ],
          pages: [
            sheet.copyWith(
              id: 'full',
              number: '01',
              mountingView: sheet.mountingView!.copyWith(
                originMm: Vec2.zero,
                viewport: const RectUnits(
                  x: 0,
                  y: 0,
                  width: 1000,
                  height: 1000,
                ),
                scaleDenominator: 1,
              ),
            ),
            sheet,
            Sheet(
              id: 'report',
              name: 'Components',
              number: '03',
              type: SheetType.billOfMaterials,
              report: const BomTableSpec(kind: BomReportKind.components),
            ),
          ],
          mountingLayouts: [
            MountingLayout(
              id: 'layout',
              name: 'Surface',
              widthMm: 150,
              heightMm: 160,
              placements: [
                for (final item in items)
                  MountingPlacement(
                    id: 'p_${item.$1}',
                    componentId: item.$1,
                    centerMm: item.$2,
                    rotation: item.$3,
                  ),
              ],
            ),
          ],
        );
        final bom = buildBom(p);
        final report = buildReport(p, p.pages.last);
        for (final item in items) {
          final row = bom.components.singleWhere(
            (r) => r.component.id == item.$1,
          );
          expect(
            row.mountingSheetIds,
            item.$4 ? ['full', 'crop'] : ['full'],
            reason: item.$1,
          );
          expect(row.placementId, 'p_${item.$1}');
          expect(row.layoutId, 'layout');
          expect(
            report.rows.singleWhere((r) => r.sourceKey == item.$1).cells[8],
            item.$4 ? '01, 02' : '01',
          );
        }
        expect(bom.articles.length, items.length);
        expect(
          bom.articles.every((r) => r.installed.knownBaseUnits == 1),
          isTrue,
        );
      },
    );
  }
}
