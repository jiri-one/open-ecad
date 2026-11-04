// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/document_layout.dart';
import 'package:open_ecad/services/export_fonts.dart';
import 'package:open_ecad/services/project_export.dart';
import 'package:open_ecad/services/report_layout.dart';
import 'package:open_ecad/services/schematic_annotations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ExportFonts.load);
  final exporter = ProjectExportService();

  test(
    'terminal references use separate rows inside the page in exports',
    () async {
      final seed = createTerminalComponent(
        componentId: 'component',
        deviceId: 'source',
        stripId: 'strip',
        position: const Vec2(800, 300),
      );
      final project = EcadProject(
        id: 'project',
        name: 'Synthetic terminal references',
        components: [seed.component],
        terminalStrips: [
          TerminalStrip(
            id: 'strip',
            reference: ComponentReference(
              context: const StructureContext.empty(),
              localDesignation: 'X1',
            ),
          ),
        ],
        pages: [
          Sheet(
            id: 'first',
            number: '1',
            name: 'Source',
            devices: [seed.device],
          ),
          Sheet(
            id: 'second',
            number: '2',
            name: 'Targets',
            devices: [
              for (var i = 0; i < 5; i++)
                seed.device.copyWith(
                  id: 'target-$i',
                  mode: OccurrenceMode.reference,
                  position: Vec2(100.0 + i * 100, 200),
                ),
            ],
          ),
        ],
      );
      requireValidProject(project);
      final svg = exporter.svg(project, sheetId: 'first');
      final rows =
          RegExp(
            r'<text data-cross-reference="([^"]+)" x="([^"]+)" y="([^"]+)" font-size="8.5">([^<]+)</text>',
          ).allMatches(svg).toList();
      expect(rows.map((r) => r[1]), [for (var i = 0; i < 5; i++) 'target-$i']);
      expect(rows.map((r) => r[3]).toSet(), hasLength(5));
      for (final row in rows) {
        final x = double.parse(row[2]!);
        final painter = reportTextPainter(row[4]!, 8.5);
        expect(x + painter.width, lessThanOrEqualTo(project.pages.first.width));
        painter.dispose();
      }
      expect(await exporter.pdf(project), isNotEmpty);
    },
  );

  test(
    '125 source rows paginate once with Czech text and repeated headings',
    () {
      final project = _reportProject(125);
      requireValidProject(project);
      final before = jsonEncode(project.toJson());
      final report = layoutReport(project, project.pages.single);
      expect(report.pages.length, greaterThanOrEqualTo(3));
      final fragments = report.pages.expand((p) => p.rowFragments).toList();
      expect(
        fragments.map((f) => f.sourceKey).toList(),
        report.data.rows.map((r) => r.sourceKey).toList(),
      );
      expect(
        fragments.map((f) => f.rowIndex).toList(),
        List.generate(125, (i) => i),
      );
      for (final page in report.pages) {
        expect(page.number, page.index == 0 ? 'B01' : 'B01.${page.index + 1}');
        expect(page.texts.map((t) => t.text), contains('Výrobce'));
        expect(page.texts.map((t) => t.text), contains('Pořídit'));
        _checkPageBounds(page);
      }
      for (var i = 0; i < fragments.length; i++) {
        expect(fragments[i].cells[4], ['${i + 10}']);
        expect(fragments[i].cells[8], ['${i + 10}']);
      }
      final svg = exporter.svg(project);
      final pageNumbers =
          RegExp(
            r'data-page="([^"]+)"',
          ).allMatches(svg).map((m) => m[1]).toList();
      expect(pageNumbers, report.pages.map((p) => p.number).toList());
      for (var i = 0; i < 125; i++) {
        expect(
          RegExp('SYN-${i.toString().padLeft(3, '0')}</text>').allMatches(svg),
          hasLength(1),
        );
      }
      expect(jsonEncode(project.toJson()), before);
    },
  );

  test(
    'one row larger than a page preserves every token and quantity once',
    () {
      final project = _reportProject(1, longRow: true);
      final report = layoutReport(project, project.pages.single);
      expect(report.pages.length, greaterThanOrEqualTo(3));
      final fragments = report.pages.expand((p) => p.rowFragments).toList();
      expect(fragments.length, report.pages.length);
      expect(fragments.first.startLine, 0);
      expect(fragments.last.endLine, fragments.last.lineCount);
      for (var i = 1; i < fragments.length; i++) {
        expect(fragments[i].startLine, fragments[i - 1].endLine);
        expect(fragments[i].continuesBefore, isTrue);
      }
      for (var c = 0; c < report.data.columns.length; c++) {
        final text = fragments.expand((f) => f.cells[c]).join(' ');
        expect(_compact(text), _compact(report.data.rows.single.cells[c]));
      }
      expect(fragments.expand((f) => f.cells[4]).toList(), ['10']);
      expect(fragments.expand((f) => f.cells[8]).toList(), ['10']);
      for (final page in report.pages) {
        _checkPageBounds(page);
      }
    },
  );

  test(
    'unbroken Czech labels wrap by measured width and retain all characters',
    () {
      final source = _reportProject(1);
      final label = 'PřílišŽluťoučkýKůň' * 9;
      final project = source.copyWith(
        articles: [source.articles.single.copyWith(partNumber: label)],
      );
      final report = layoutReport(project, project.pages.single);
      final actual =
          report.pages
              .expand((p) => p.rowFragments)
              .expand((f) => f.cells[1])
              .join();
      expect(actual, label);
      for (final page in report.pages) {
        _checkPageBounds(page);
      }
    },
  );

  test('empty, A4 portrait and long notes remain bounded and numbered', () {
    final empty = _reportProject(0);
    final report = layoutReport(empty, empty.pages.single);
    expect(report.pages, hasLength(1));
    expect(
      report.pages.single.texts.map((t) => t.text),
      contains('Žádné položky.'),
    );
    final source = _reportProject(3, kind: BomReportKind.components);
    final sheet = source.pages.single.copyWith(
      paperSizeMm: const SizeMm(width: 210, height: 297),
      report: BomTableSpec(
        kind: BomReportKind.components,
        note: 'Řádek poznámky s diakritikou.\n' * 120,
      ),
    );
    final project = source.copyWith(pages: [sheet]);
    final long = layoutReport(project, sheet);
    expect(long.pages.length, greaterThan(1));
    expect(
      long.pages.expand((p) => p.rowFragments).map((f) => f.sourceKey).toSet(),
      hasLength(3),
    );
    expect(
      long.pages
          .expand((p) => p.texts)
          .where((t) => t.text == 'Řádek poznámky s diakritikou.'),
      hasLength(120),
    );
    for (final page in long.pages) {
      _checkPageBounds(page);
    }
  });

  test(
    'reserved continuation numbers fail before producing any export',
    () async {
      final source = _reportProject(2);
      final project = source.copyWith(
        pages: [
          ...source.pages,
          Sheet(id: 'collision', name: 'Kolize', number: 'B01.2'),
        ],
      );
      expect(
        () => exporter.svg(project),
        throwsA(
          isA<EcadException>().having(
            (e) => e.code,
            'code',
            'reserved_sheet_number',
          ),
        ),
      );
      expect(
        () => exporter.csv(project, sheetId: 'bom'),
        throwsA(isA<EcadException>()),
      );
      await expectLater(exporter.pdf(project), throwsA(isA<EcadException>()));
    },
  );

  test('BOM and CSV distinguish pieces, views, reserves and procurement', () {
    final source = _mixedProject();
    final project = source.copyWith(
      components: [
        ...source.components,
        const Component(
          id: 'spare',
          kind: ComponentKind.material,
          articleId: 'box',
          usage: ComponentUsage.spare,
          quantity: Quantity.pieces(5),
        ),
        const Component(
          id: 'available',
          kind: ComponentKind.material,
          articleId: 'box',
          quantity: Quantity.pieces(3),
          procurement: Procurement(source: ProcurementSource.available),
        ),
        const Component(
          id: 'included',
          kind: ComponentKind.material,
          articleId: 'box',
          quantity: Quantity.pieces(2),
          procurement: Procurement(
            source: ProcurementSource.included,
            includedInComponentId: 'coil',
          ),
        ),
        const Component(
          id: 'unknown',
          kind: ComponentKind.material,
          quantity: Quantity.millimetres(null),
          description: 'Délka; "neurčená"\nDruhý řádek',
        ),
      ],
    );
    final report = buildReport(project, project.sheetById('bom')!);
    final box = report.rows.firstWhere(
      (r) => r.sourceKey == 'article:box:piece',
    );
    expect(box.cells.skip(3).toList(), ['ks', '6', '5', '3', '2', '6']);
    String expectedCsvText(String text) =>
        const {
          '-A1 · Zkušební blok': "'-A1 · Zkušební blok",
          '-K1 · Řídicí relé': "'-K1 · Řídicí relé",
          '-K1': "'-K1",
        }[text] ??
        text;
    final csv = exporter.csv(project, sheetId: 'bom');
    expect(_parseCsv(csv), [
      report.columns,
      ...report.rows.map((r) => r.cells.map(expectedCsvText).toList()),
    ]);
    final unknown = report.rows.firstWhere(
      (r) => r.sourceKey == 'component:unknown',
    );
    expect(unknown.cells[4], 'neurčeno');
    expect(unknown.cells[8], 'neurčeno');
    final componentReport = buildReport(
      project,
      project.sheetById('components')!,
    );
    expect(
      componentReport.rows.firstWhere((r) => r.sourceKey == 'coil').cells[2],
      '1',
    );
    expect(
      componentReport.rows.firstWhere((r) => r.sourceKey == 'coil').cells[8],
      '01, 02, M01, M02',
    );
    expect(_parseCsv(exporter.csv(project, sheetId: 'components')), [
      componentReport.columns,
      ...componentReport.rows.map((r) => r.cells.map(expectedCsvText).toList()),
    ]);
  });

  test(
    'current component, port and continuation labels accompany real glyphs',
    () {
      final project = _mixedProject();
      requireValidProject(project);
      final svg = exporter.svg(project, sheetId: 'electric');
      expect(svg, contains(ProjectExportService.symbolSvg(DeviceKind.coil)));
      expect(svg, contains('data-device="block_view"'));
      expect(svg, contains('L+ · Napájení'));
      expect(svg, contains('DO1 · Ovládání čerpadla'));
      expect(svg, contains('-K1'));
      expect(svg, contains('Řídicí relé'));
      expect(svg, contains('SIG-A -&gt; 02'));
      expect(svg, contains('<polyline'));
      final engine = ProjectEngine(project)..execute([
        UpdateSheet(project.sheetById('reference')!.copyWith(number: 'E07')),
        UpdateComponent(
          project.componentById('coil')!.copyWith(designation: '-K9'),
        ),
      ]);
      final revised = exporter.svg(engine.project, sheetId: 'electric');
      expect(revised, contains('SIG-A -&gt; E07'));
      expect(revised, isNot(contains('SIG-A -&gt; 02')));
      expect(revised, contains('-K9'));
      expect(revised, isNot(contains('>-K1</text>')));
    },
  );

  test('pin labels remain horizontal and separate for every quarter turn', () {
    final project = _mixedProject();
    final block = project.sheetById('electric')!.deviceById('block_view')!;
    final resolver = ProjectResolver(project);
    for (final rotation in [0.0, 90.0, 180.0, 270.0]) {
      final annotations = layoutPortAnnotations(
        resolver,
        block.copyWith(rotation: rotation),
      );
      expect(
        annotations.map((p) => p.text),
        contains('DO1 · Ovládání čerpadla'),
      );
      for (var i = 0; i < annotations.length; i++) {
        for (var j = i + 1; j < annotations.length; j++) {
          expect(
            annotations[i].bounds.overlaps(annotations[j].bounds),
            isFalse,
          );
        }
      }
    }
  });

  test('100 mm at 1:2 exports as 50 mm independent of graphics or framing', () {
    final project = _mixedProject();
    final sheet = project.sheetById('mounting')!;
    final svg = exporter.svg(project, sheetId: sheet.id);
    final shape =
        RegExp(
          r'<g data-placement="placement"[^>]+><rect[^>]+/></g>',
        ).firstMatch(svg)!.group(0)!;
    final width = double.parse(
      RegExp(r'width="([0-9.]+)"').firstMatch(shape)![1]!,
    );
    final outer =
        RegExp(
          r'<g transform="translate\([^)]+\) scale\(([0-9.]+)\)">',
        ).firstMatch(svg)!;
    final mmPerUnit = double.parse(outer[1]!);
    expect(width * mmPerUnit, closeTo(50, 0.0002));
    expect(svg, contains('width="297mm" height="210mm"'));
    expect(svg, contains('100 × 40 mm'));
    final graphic = DrawingElement(
      id: 'annotation',
      kind: DrawingKind.text,
      position: const Vec2(900, 600),
      width: 120,
      height: 20,
      text: 'Volná poznámka',
    );
    final changed = project.copyWith(
      pages: [
        for (final p in project.pages)
          p.id == sheet.id
              ? p.copyWith(graphics: [graphic], showFrame: false)
              : p,
      ],
    );
    final after = exporter.svg(changed, sheetId: sheet.id);
    expect(
      RegExp(
        r'<g data-placement="placement"[^>]+><rect[^>]+/></g>',
      ).firstMatch(after)!.group(0),
      shape,
    );
    expect(after, contains(outer.group(0)!));
    expect(
      exporter.svg(project, sheetId: 'detail'),
      isNot(contains('100 × 40 mm')),
    );
    expect(
      () => exporter.svg(project, sheetId: 'missing'),
      throwsFormatException,
    );
  });

  test(
    'long pin signals wrap without losing text or overlapping neighbours',
    () {
      final source = _mixedProject();
      final component = source.componentById('block')!;
      final signal = 'Příliš žluťoučký kůň ' * 8;
      final electrical = component.electrical!;
      final project = source.copyWith(
        components: [
          for (final c in source.components)
            c.id == component.id
                ? c.copyWith(
                  electrical: electrical.copyWith(
                    terminals: [
                      electrical.terminals.first,
                      electrical.terminals.last.copyWith(signal: signal),
                    ],
                  ),
                )
                : c,
        ],
      );
      requireValidProject(project);
      final labels = layoutPortAnnotations(
        ProjectResolver(project),
        project.pages.first.devices.last,
      );
      expect(_compact(labels.last.text), _compact('DO1 · $signal'));
      expect(labels.last.text.split('\n').length, greaterThan(1));
      expect(labels.last.bounds.width, lessThanOrEqualTo(184));
      final svg = exporter.svg(project, sheetId: 'electric');
      for (final line in labels.last.text.split('\n')) {
        expect(svg, contains('>$line</text>'));
      }
    },
  );

  test('every builtin electrical glyph survives the v4 resolver', () {
    final seeds = [
      for (final kind in DeviceKind.values.where((k) => k != DeviceKind.earth))
        createBuiltinComponent(
          componentId: 'c_${kind.name}',
          deviceId: 'd_${kind.name}',
          kind: kind,
          designation: '-${kind.name}',
          position: const Vec2(300, 300),
        ),
    ];
    final project = EcadProject(
      id: 'glyphs',
      name: 'Syntetické značky',
      components: seeds.map((s) => s.component).toList(),
      pages: [
        for (var i = 0; i < seeds.length; i++)
          Sheet(
            id: 'sheet_$i',
            name: 'Značka $i',
            number: '$i',
            devices: [seeds[i].device],
          ),
      ],
    );
    final svg = exporter.svg(project);
    for (final kind in DeviceKind.values.where((k) => k != DeviceKind.earth)) {
      expect(svg, contains(ProjectExportService.symbolSvg(kind)));
    }
  });

  test(
    'live report follows edits and undo without adding generated model rows',
    () {
      final project = _reportProject(1);
      final engine = ProjectEngine(project);
      List<String> values() =>
          layoutReport(
            engine.project,
            engine.project.pages.single,
          ).data.rows.single.cells;
      expect(values()[4], '10');
      engine.execute([
        const AddComponent(
          Component(
            id: 'second',
            kind: ComponentKind.material,
            articleId: 'article_0',
            quantity: Quantity.pieces(2),
          ),
        ),
        UpdateArticle(
          project.articles.single.copyWith(name: 'Změněný výrobek'),
        ),
      ]);
      expect(values()[4], '12');
      expect(values()[2], contains('Změněný výrobek'));
      expect(engine.project.pages, hasLength(1));
      expect(engine.project.pages.single.graphics, isEmpty);
      expect(engine.undo(), isTrue);
      expect(values()[4], '10');
      expect(engine.redo(), isTrue);
      expect(values()[4], '12');
    },
  );

  test(
    'document numbering includes derived report pages and does not mutate',
    () {
      final source = _reportProject(125);
      final project = source.copyWith(
        pages: [
          Sheet(id: 'intro', name: 'Úvod', number: '01'),
          ...source.pages,
          Sheet(id: 'last', name: 'Závěr', number: '02'),
        ],
      );
      final before = jsonEncode(project.toJson());
      final layout = layoutDocument(project);
      expect(layout.pages.first.number, '01');
      expect(layout.pages.last.number, '02');
      expect(
        layout.pages.map((p) => p.index),
        orderedEquals(List.generate(layout.pages.length, (i) => i)),
      );
      expect(
        layout.pages.where((p) => p.sheet.id == 'bom').length,
        greaterThanOrEqualTo(3),
      );
      expect(
        exporter.svg(project, sheetId: 'last'),
        contains('${layout.pages.length} / ${layout.pages.length}'),
      );
      expect(jsonEncode(project.toJson()), before);
    },
  );

  test(
    'PDF keeps paper sizes, embeds fonts and matches all derived pages',
    () async {
      final projects = {
        'mixed': _mixedProject(),
        'rows125': _reportProject(125),
        'long-row': _reportProject(1, longRow: true),
      };
      for (final entry in projects.entries) {
        final layout = layoutDocument(entry.value);
        final pdf = await exporter.pdf(entry.value);
        final raw = latin1.decode(pdf);
        expect(raw, startsWith('%PDF-'));
        expect(
          RegExp(r'/Type\s*/Page\b').allMatches(raw),
          hasLength(layout.pages.length),
        );
        expect(raw, contains('/FontFile2'));
        expect(raw, contains('/ToUnicode'));
        final svg = exporter.svg(entry.value);
        expect(svg, contains('@font-face'));
        expect(svg, isNot(contains('<image')));
        const directory = String.fromEnvironment('EXPORT_QA_DIR');
        if (directory.isNotEmpty) {
          Directory(directory).createSync(recursive: true);
          File('$directory/${entry.key}.pdf').writeAsBytesSync(pdf);
          File('$directory/${entry.key}.svg').writeAsStringSync(svg);
          File('$directory/${entry.key}-layout.json').writeAsStringSync(
            jsonEncode({
              'pages': [
                for (final p in layout.pages)
                  {
                    'number': p.number,
                    'widthMm': p.sizeMm.width,
                    'heightMm': p.sizeMm.height,
                    'positions': [
                      for (final t in p.report?.texts ?? <ReportText>[])
                        {
                          'text': t.text,
                          'x': t.x,
                          'y': t.baseline,
                          'width': t.width,
                        },
                    ],
                    'texts': [
                      for (final t in p.report?.texts ?? <ReportText>[]) t.text,
                    ],
                    'rows': [
                      for (final r
                          in p.report?.rowFragments ?? <ReportRowFragment>[])
                        {
                          'key': r.sourceKey,
                          'start': r.startLine,
                          'end': r.endLine,
                          'cells': r.cells,
                        },
                    ],
                  },
              ],
            }),
          );
          final report =
              layout.pages.where((p) => p.report != null).first.report!;
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder)..scale(3);
          paintReportPage(canvas, report);
          final picture = recorder.endRecording();
          final image = await picture.toImage(
            (report.sizeMm.width * 3).ceil(),
            (report.sizeMm.height * 3).ceil(),
          );
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            '$directory/${entry.key}-canvas.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
        }
      }
    },
  );
}

String _compact(String text) => text.replaceAll(RegExp(r'\s+'), '');

void _checkPageBounds(ReportPage page) {
  for (final text in page.texts) {
    expect(text.x, greaterThanOrEqualTo(0));
    expect(text.x + text.width, lessThanOrEqualTo(page.sizeMm.width - 7));
    expect(text.baseline - text.ascent, greaterThanOrEqualTo(0));
    expect(text.baseline, lessThan(page.sizeMm.height - 5));
  }
  for (final fragment in page.rowFragments) {
    expect(
      fragment.bounds.bottom,
      lessThanOrEqualTo(page.sizeMm.height - 18 + 0.0001),
    );
    for (final text in page.texts.where(
      (t) =>
          t.baseline > fragment.bounds.top &&
          t.baseline < fragment.bounds.bottom,
    )) {
      final box =
          page.boxes
              .where((b) => b.rect.contains(ui.Offset(text.x, text.baseline)))
              .first;
      expect(text.x + text.width, lessThanOrEqualTo(box.rect.right - 1.7));
    }
  }
}

List<List<String>> _parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == '"') {
      if (quoted && i + 1 < text.length && text[i + 1] == '"') {
        cell.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (char == ',' && !quoted) {
      row.add(cell.toString());
      cell.clear();
    } else if (char == '\r' && !quoted) {
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = [];
      i++;
    } else {
      cell.write(char);
    }
  }
  return rows;
}

EcadProject _reportProject(
  int count, {
  bool longRow = false,
  BomReportKind kind = BomReportKind.articles,
}) {
  final articles = [
    for (var i = 0; i < count; i++)
      Article(
        id: 'article_$i',
        name: 'Český zkušební díl $i',
        unit: QuantityUnit.piece,
        manufacturer: 'Syntetická výroba',
        partNumber: 'SYN-${i.toString().padLeft(3, '0')}',
        specification:
            longRow
                ? List.generate(
                  200,
                  (j) => 'Příliš žluťoučký kůň $j.',
                ).join(' ')
                : 'Ověření řádků a množství',
      ),
  ];
  return EcadProject(
    id: 'report_project',
    name: 'Syntetický kusovník',
    articles: articles,
    components: [
      for (var i = 0; i < count; i++)
        Component(
          id: 'material_$i',
          kind: ComponentKind.material,
          articleId: 'article_$i',
          description: 'Zkušební položka $i',
          quantity: Quantity.pieces(i + 10),
        ),
    ],
    pages: [
      Sheet(
        id: 'bom',
        name: 'Přehled materiálu',
        number: 'B01',
        type: SheetType.billOfMaterials,
        paperSizeMm: SizeMm.a4Landscape,
        report: BomTableSpec(
          kind: kind,
          title: 'Český přehled - kontrola',
          note: 'Pouze syntetická data.',
        ),
      ),
    ],
  );
}

EcadProject _mixedProject() {
  final seed = createBuiltinComponent(
    componentId: 'coil',
    deviceId: 'coil_view',
    kind: DeviceKind.coil,
    designation: '-K1',
    position: const Vec2(180, 220),
    articleId: 'box',
    description: 'Řídicí relé',
  );
  final block = Component(
    id: 'block',
    designation: '-A1',
    description: 'Zkušební blok',
    electrical: ElectricalModel(
      terminals: const [
        ComponentTerminal(id: 'power', designation: 'L+', signal: 'Napájení'),
        ComponentTerminal(
          id: 'output',
          designation: 'DO1',
          signal: 'Ovládání čerpadla',
        ),
      ],
      functions: [
        ComponentFunction(
          id: 'interface',
          name: 'Rozhraní',
          terminalIds: ['power', 'output'],
        ),
      ],
    ),
  );
  return EcadProject(
    id: 'synthetic_export',
    name: 'Řízení <zkouška> & "1"',
    components: [seed.component, block],
    articles: const [
      Article(
        id: 'box',
        name: 'Syntetické relé',
        unit: QuantityUnit.piece,
        manufacturer: 'Demo Works',
        partNumber: 'D-100',
        dimensionsMm: DimensionsMm(width: 100, height: 40),
      ),
    ],
    continuationLinks: const [ContinuationLink(id: 'link', label: 'SIG-A')],
    mountingLayouts: [
      MountingLayout(
        id: 'surface',
        name: 'Zkušební montážní plocha',
        widthMm: 200,
        heightMm: 120,
        placements: const [
          MountingPlacement(
            id: 'placement',
            componentId: 'coil',
            centerMm: Vec2(100, 60),
          ),
        ],
      ),
    ],
    pages: [
      Sheet(
        id: 'electric',
        name: 'Zapojení',
        number: '01',
        devices: [
          seed.device,
          Device(
            id: 'block_view',
            componentId: 'block',
            functionId: 'interface',
            position: const Vec2(500, 350),
            symbol: PortBlockSpec(
              width: 160,
              height: 120,
              ports: const [
                BlockPort(
                  id: 'left',
                  terminalId: 'power',
                  side: PortSide.left,
                  fraction: 0.5,
                ),
                BlockPort(
                  id: 'right',
                  terminalId: 'output',
                  side: PortSide.right,
                  fraction: 0.5,
                ),
              ],
            ),
          ),
        ],
        continuations: const [
          ContinuationMarker(
            id: 'source_marker',
            linkId: 'link',
            position: Vec2(850, 450),
            direction: PortSide.right,
          ),
        ],
        wires: [
          Wire(
            id: 'wire',
            from: const TerminalRef(deviceId: 'block_view', portId: 'right'),
            to: const ContinuationRef(markerId: 'source_marker'),
          ),
        ],
      ),
      Sheet(
        id: 'reference',
        name: 'Odkaz',
        number: '02',
        devices: [
          seed.device.copyWith(
            id: 'coil_reference',
            mode: OccurrenceMode.reference,
          ),
        ],
        continuations: const [
          ContinuationMarker(
            id: 'target_marker',
            linkId: 'link',
            position: Vec2(400, 220),
          ),
        ],
      ),
      Sheet(
        id: 'mounting',
        name: 'Výstavba',
        number: 'M01',
        type: SheetType.cabinetLayout,
        paperSizeMm: SizeMm.a4Landscape,
        mountingView: const MountingView(
          layoutId: 'surface',
          viewport: RectUnits(x: 100, y: 150, width: 800, height: 450),
          scaleDenominator: 2,
          showComponentDimensions: true,
        ),
      ),
      Sheet(
        id: 'detail',
        name: 'Druhý pohled',
        number: 'M02',
        type: SheetType.cabinetLayout,
        mountingView: const MountingView(
          layoutId: 'surface',
          originMm: Vec2(50, 30),
          viewport: RectUnits(x: 100, y: 150, width: 800, height: 450),
          scaleDenominator: 1,
          showSurfaceDimensions: false,
        ),
      ),
      Sheet(
        id: 'bom',
        name: 'Kusovník',
        number: 'B01',
        type: SheetType.billOfMaterials,
        report: const BomTableSpec(kind: BomReportKind.articles),
      ),
      Sheet(
        id: 'components',
        name: 'Komponenty',
        number: 'B02',
        type: SheetType.billOfMaterials,
        report: const BomTableSpec(kind: BomReportKind.components),
      ),
    ],
  );
}
