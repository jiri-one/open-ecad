import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/project_export.dart';

void main() {
  test('CSV quotes data and protects text from spreadsheet formulas', () {
    final dangerous = [
      '=1+1',
      '+1+1',
      '-1+1',
      '@SUM(1)',
      '\t=1+1',
      '\r=1+1',
      '\n=1+1',
    ];
    for (final text in dangerous) {
      final sheet = Sheet(
        id: 'sheet',
        name: 'BOM',
        number: '1',
        type: SheetType.billOfMaterials,
        report: const BomTableSpec(kind: BomReportKind.articles),
      );
      final project = EcadProject(
        id: 'project',
        name: 'Synthetic',
        articles: [
          Article(
            id: 'article',
            name: 'Part, "quoted"',
            manufacturer: text,
            partNumber: 'CODE',
            unit: QuantityUnit.piece,
          ),
        ],
        components: const [
          Component(id: 'component', designation: '-A1', articleId: 'article'),
        ],
        pages: [sheet],
      );
      final csv = ProjectExportService().csv(project, sheetId: sheet.id);
      expect(csv, contains('"\'$text"'));
      expect(csv, contains('"Part, ""quoted"""'));
      expect(csv, contains('"ks","1","0","0","0","1"'));
      expect(project.articles.single.manufacturer, text);
    }
  });
}
