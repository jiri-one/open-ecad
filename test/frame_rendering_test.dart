import 'dart:io';
import 'dart:ui' as ui;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/theme.dart';
import 'package:open_ecad/editor/mounting_canvas.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/document_layout.dart';
import 'package:open_ecad/services/export_fonts.dart';
import 'package:open_ecad/services/frame_layout.dart';
import 'package:open_ecad/services/project_export.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/services/report_layout.dart';
import 'package:open_ecad/widgets/report_view.dart';

class _MemoryPersistence extends ProjectPersistence {
  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async => 'memory';
}

EcadProject _project({SizeMm paper = SizeMm.a4Landscape, int rows = 85}) =>
    EcadProject(
      id: 'frame-synthetic',
      name: 'Žluťoučký kůň & <rozváděč> „Příliš“',
      documentFields: const {
        'drawnBy': 'Jiří Černý',
        'drawingRevision': 'Vydání B',
      },
      pages: [
        for (final (i, type) in SheetType.values.indexed)
          Sheet(
            id: 'sheet-$i',
            name: 'Část ${type.label}',
            number: '${i + 1}',
            type: type,
            paperSizeMm: paper,
            report:
                type == SheetType.billOfMaterials
                    ? const BomTableSpec(kind: BomReportKind.articles)
                    : null,
          ),
      ],
      articles: [
        for (var i = 0; i < rows; i++)
          Article(
            id: 'a-$i',
            name: 'Přepěťová ochrana číslo $i',
            unit: QuantityUnit.piece,
            manufacturer: 'Český výrobce',
            partNumber: 'SYN-$i',
          ),
      ],
      components: [
        for (var i = 0; i < rows; i++)
          Component(
            id: 'c-$i',
            kind: ComponentKind.material,
            articleId: 'a-$i',
            quantity: const Quantity.pieces(1),
          ),
      ],
    );

PreparedFrameLayout _textFrame(List<FrameField> fields) {
  final sheet = Sheet(id: 'sheet', name: 'Pole', number: '1');
  final template = FrameTemplates.builtin.copyWith(
    titleBlock: FrameTitleBlock(widthMm: 180, heightMm: 36, fields: fields),
  );
  final project = EcadProject(id: 'text', name: 'Projekt', pages: [sheet]);
  return prepareFrameLayout(
    bindFrame(
      layoutFrameGeometry(sheet.paperSizeMm, ResolvedFrame(template)),
      project,
      sheet,
      const FramePageContext(number: '1', documentIndex: 1, documentCount: 1),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ExportFonts.load);

  test('one measured Unicode layout wraps, shrinks, clips and escapes XML', () {
    final frame = _textFrame([
      const FrameField(
        id: 'literal',
        rectMm: RectMm(x: 2, y: 1, width: 170, height: 6),
        text: 'Příliš žluťoučký kůň & <pole> "číslo"',
        fontSizeMm: 3,
      ),
      FrameField(
        id: 'wrap',
        rectMm: const RectMm(x: 2, y: 8, width: 42, height: 25),
        text: List.filled(60, 'ěščřžýáíé').join(' '),
        overflow: FrameTextOverflow.wrap,
      ),
      const FrameField(
        id: 'shrink',
        rectMm: RectMm(x: 45, y: 8, width: 80, height: 10),
        text: 'Řízení a elektrická zařízení',
        fontSizeMm: 8,
        minFontSizeMm: 2,
      ),
      FrameField(
        id: 'zone.top.0',
        rectMm: const RectMm(x: 126, y: 8, width: 10, height: 3),
        text: 'Ře\u030cz' * 100,
        minFontSizeMm: 3,
      ),
    ]);
    expect(frame.overflowFieldIds, containsAll(['wrap', 'zone.top.0']));
    final slot = frame.source.texts.indexWhere((t) => t.id == 'shrink');
    expect(
      frame.lines.where((l) => l.slotIndex == slot).first.fontSize,
      lessThan(8),
    );
    expect(frame.lines.any((l) => l.text.endsWith('…')), isTrue);
    final svg = frameLayoutSvg(frame, idPrefix: 'a"& b');
    expect(svg, contains('&amp; &lt;pole&gt; &quot;číslo&quot;'));
    expect(svg, isNot(contains('lengthAdjust')));
    expect(svg, isNot(contains('scale(')));
    final pair = svg + frameLayoutSvg(frame, idPrefix: 'a_ b');
    final ids =
        RegExp(
          'clipPath id="([^"]+)"',
        ).allMatches(pair).map((m) => m[1]).toList();
    expect(ids.toSet().length, ids.length);
    for (final line in frame.lines) {
      expect(line.offset.dy, greaterThanOrEqualTo(line.clip.top));
      expect(line.fontSize, greaterThanOrEqualTo(2));
    }
  });

  for (final paper in [SizeMm.a3Landscape, SizeMm.a4Landscape]) {
    test(
      'all sheet types share full-document fields and content bounds on $paper',
      () {
        final project = _project(paper: paper);
        final layout = layoutDocument(project);
        expect(identical(layoutDocument(project), layout), isTrue);
        expect(layout.pages.length, greaterThan(5));
        final svg = ProjectExportService().svg(project);
        final clips =
            RegExp(
              'clipPath id="([^"]+)"',
            ).allMatches(svg).map((m) => m[1]).toList();
        expect(clips.toSet().length, clips.length);
        for (final page in layout.pages) {
          expect(page.frame.source.geometry.strokesMm, isNotEmpty);
          final value =
              page.frame.source.texts.firstWhere((f) => f.id == 'page').text;
          expect(
            value,
            '${page.number} · ${page.index + 1} / ${layout.pages.length}',
          );
          if (page.report case final report?) {
            final content = page.frame.source.geometry.contentRectMm;
            for (final box in report.boxes) {
              expect(box.rect.left, greaterThanOrEqualTo(content.x));
              expect(box.rect.right, lessThanOrEqualTo(content.right + 1e-6));
              expect(box.rect.bottom, lessThanOrEqualTo(content.bottom));
            }
            expect(
              report.texts.any((t) => t.text.startsWith('Revize ')),
              isFalse,
            );
          }
        }
        final reportSheet = project.pages.firstWhere((s) => s.report != null);
        final subset = ProjectExportService().svg(
          project,
          sheetId: reportSheet.id,
        );
        for (final page in layout.pages.where(
          (p) => p.sheet.id == reportSheet.id,
        )) {
          expect(
            subset,
            contains(
              '${page.number} · ${page.index + 1} / ${layout.pages.length}',
            ),
          );
        }
        final noFrames = project.copyWith(
          defaultFrame: const FrameChoice.none(),
        );
        for (final page in layoutDocument(noFrames).pages) {
          expect(page.frame.source.geometry.strokesMm, isEmpty);
          expect(page.frame.lines, isEmpty);
        }
      },
    );
  }

  test(
    'independent frame parts and explicit none respect project overrides',
    () {
      final seed = _project(rows: 0);
      for (final part in ['border', 'title', 'zones']) {
        final project = seed.copyWith(
          defaultFrame: FrameChoice.template(
            FrameTemplates.builtinId,
            border: part == 'border',
            titleBlock: part == 'title',
            zones: part == 'zones',
          ),
        );
        final frame = layoutDocument(project).pages.first.frame;
        expect(
          frame.source.texts.any((t) => t.id == 'project'),
          part == 'title',
        );
        expect(
          frame.source.texts.any((t) => t.id.startsWith('zone.')),
          part == 'zones',
        );
        final none = project.copyWith(
          pages: [
            project.pages.first.copyWith(frame: const FrameChoice.none()),
          ],
        );
        expect(layoutDocument(none).pages.single.frame.lines, isEmpty);
        expect(
          layoutDocument(none).pages.single.frame.source.geometry.strokesMm,
          isEmpty,
        );
      }
    },
  );

  test(
    'too-small report content fails export cleanly and preserves a layout diagnostic',
    () {
      final original = _project(rows: 1);
      final template = FrameTemplates.builtin.copyWith(
        titleBlock: FrameTitleBlock(widthMm: 180, heightMm: 160),
      );
      final project = original.copyWith(frameTemplates: [template]);
      final sheet = project.pages.firstWhere((s) => s.report != null);
      expect(() => layoutReport(project, sheet), throwsFormatException);
      final layout = layoutDocument(project);
      expect(
        layout.firstPageFor(sheet.id).layoutError,
        contains('příliš malá'),
      );
      expect(() => ProjectExportService().svg(project), throwsFormatException);
    },
  );

  test('binding limit is a visible diagnostic and a clean export failure', () {
    final template = FrameTemplates.builtin.copyWith(
      titleBlock: FrameTitleBlock(
        widthMm: 180,
        heightMm: 36,
        fields: [
          FrameField(
            id: 'huge',
            rectMm: const RectMm(x: 2, y: 2, width: 176, height: 32),
            text: '{{document.long}}' * 17,
          ),
        ],
      ),
    );
    final project = _project(rows: 0).copyWith(
      frameTemplates: [template],
      documentFields: {'long': 'ž' * 2048},
    );
    expect(
      layoutDocument(project).pages.first.layoutError,
      contains('Text rámu nelze připravit'),
    );
    expect(() => ProjectExportService().svg(project), throwsFormatException);
  });

  test(
    'custom margins shift report rows and independent page bindings remain physical',
    () {
      final template = FrameTemplates.builtin.copyWith(
        marginsMm: const FrameMargins(left: 28, right: 8, top: 22, bottom: 12),
        titleBlock: FrameTitleBlock(
          widthMm: 150,
          heightMm: 32,
          fields: const [
            FrameField(
              id: 'counts',
              rectMm: RectMm(x: 2, y: 2, width: 146, height: 28),
              text:
                  '{{page.index}}/{{page.count}} · {{page.inSheet}}/{{page.sheetCount}}',
            ),
          ],
        ),
      );
      final project = _project().copyWith(frameTemplates: [template]);
      final layout = layoutDocument(project);
      final pages = layout.pages.where((p) => p.report != null).toList();
      expect(pages.length, greaterThan(1));
      for (final (i, page) in pages.indexed) {
        final area = page.frame.source.geometry.contentRectMm;
        expect(page.report!.boxes.first.rect.left, closeTo(area.x, 1e-6));
        expect(area.x, greaterThan(28));
        final text =
            page.frame.source.texts.firstWhere((t) => t.id == 'counts').text;
        expect(
          text,
          '${page.index + 1}/${layout.pages.length} · ${i + 1}/${pages.length}',
        );
      }
    },
  );

  test(
    'frame changes diagnose overlap without moving drawings; new content uses frame bounds',
    () {
      final original = _project(rows: 0);
      final sheet = original.pages.first.copyWith(
        graphics: [
          DrawingElement(
            id: 'outside',
            kind: DrawingKind.text,
            text: 'Mimo rám',
            position: const Vec2(0, 0),
            width: 40,
            height: 40,
          ),
        ],
      );
      final project = original.copyWith(pages: [sheet]);
      expect(layoutDocument(project).pages.single.diagnostics, isNotEmpty);
      final app = EditorController(
        initialProject: project,
        persistence: _MemoryPersistence(),
      );
      addTearDown(app.dispose);
      app.execute([
        const SetSheetFrame('sheet-0', FrameChoice.none()),
      ], 'Bez rámu');
      expect(app.sheet.graphics.single.position, const Vec2(0, 0));
      expect(app.showGrid, isTrue);
      app.addSheet(type: SheetType.form, formStarter: true);
      final area = frameContentUnits(
        app.sheet,
        layoutFrameGeometry(
          app.sheet.paperSizeMm,
          resolveSheetFrame(app.project, app.sheet),
        ),
      );
      for (final graphic in app.sheet.graphics) {
        expect(graphic.position.x, greaterThanOrEqualTo(area.x));
        expect(graphic.position.y, greaterThanOrEqualTo(area.y));
      }
      app.addSheet(type: SheetType.cabinetLayout);
      expect(app.configureMounting(width: 100, height: 100, scale: 2), isTrue);
      final content = frameContentUnits(
        app.sheet,
        layoutFrameGeometry(
          app.sheet.paperSizeMm,
          resolveSheetFrame(app.project, app.sheet),
        ),
      );
      final viewport = app.sheet.mountingView!.viewport;
      expect(viewport.x, content.x);
      expect(viewport.y, content.y);
      expect(viewport.width, content.width);
      expect(viewport.height, lessThan(content.height));
      expect(
        layoutDocument(app.project).firstPageFor(app.sheet.id).diagnostics,
        isEmpty,
      );
      final physical = MountingTransform(app.sheet, app.sheet.mountingView!);
      final distance =
          physical.paper.toPaperMm(physical.toSheet(const Vec2(100, 0))) -
          physical.paper.toPaperMm(physical.toSheet(Vec2.zero));
      expect(distance.x, closeTo(50, 1e-6));
      expect(
        layoutDocument(app.project)
            .firstPageFor(app.sheet.id)
            .frame
            .source
            .texts
            .firstWhere((f) => f.id == 'revision')
            .text,
        contains('1:2'),
      );
      app.showGrid = false;
      app.execute([
        SetSheetFrame(app.sheet.id, const FrameChoice.none()),
      ], 'Bez rámu');
      expect(app.showGrid, isFalse);
      expect(app.sheet.mountingView!.viewport.toJson(), viewport.toJson());
    },
  );

  for (final mounting in [false, true]) {
    testWidgets(
      '${mounting ? 'empty mounting' : 'schematic'} fits negative physical paper bounds',
      (tester) async {
        final sheet = Sheet(
          id: 'sheet',
          name: 'Nesouhlasný poměr stran',
          number: '1',
          width: 900,
          height: 900,
          paperSizeMm: SizeMm.a4Landscape,
          type: mounting ? SheetType.cabinetLayout : SheetType.multiLine,
        );
        final app = EditorController(
          initialProject: EcadProject(
            id: 'mismatch',
            name: 'Projekt',
            pages: [sheet],
          ),
          persistence: _MemoryPersistence(),
        );
        addTearDown(app.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body:
                  mounting
                      ? MountingCanvas(app: app)
                      : SchematicCanvas(
                        project: app.project,
                        sheet: sheet,
                        selectedIds: const {},
                        mode: CanvasMode.select,
                        showGrid: true,
                        palette:
                            EcadColors.forAppearance(
                              EcadAppearance.ink,
                            ).canvasPalette,
                        controller: app.viewport,
                        onSelectionChanged: (_) {},
                        onMoveDevices: (_) {},
                        onPlaceDevice: (_, _) {},
                        onConnect: (_, _) {},
                        onDeleteWire: (_) {},
                      ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final bounds = SheetTransform(sheet).paperBoundsUnits;
        expect(bounds.x, lessThan(0));
        if (mounting) {
          final size = tester.getSize(
            find.byKey(const ValueKey('mounting-surface')),
          );
          expect(size.width / size.height, closeTo(297 / 210, 1e-6));
          expect(find.text('Nastavit montážní pohled'), findsOneWidget);
        } else {
          final a = app.viewport.worldToLocal(bounds.topLeft)!;
          final b =
              app.viewport.worldToLocal(
                Vec2(bounds.x + bounds.width, bounds.y + bounds.height),
              )!;
          final size = tester.getSize(find.byType(SchematicCanvas));
          expect((a + b) / 2, size.center(Offset.zero));
          expect(a.dx, greaterThanOrEqualTo(8 - 1e-6));
          expect(a.dy, greaterThanOrEqualTo(8 - 1e-6));
          expect((b.dx - a.dx) / (b.dy - a.dy), closeTo(297 / 210, 1e-6));
        }
      },
    );
  }

  testWidgets('report canvas uses the same cached physical report pages', (
    tester,
  ) async {
    final app = EditorController(
      initialProject: _project(),
      persistence: _MemoryPersistence(),
    );
    addTearDown(app.dispose);
    app.setSheet(app.project.pages.firstWhere((s) => s.report != null).id);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ReportView(app: app))),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final pages =
        layoutDocument(
          app.project,
        ).pages.where((p) => p.sheet.id == app.sheet.id).toList();
    expect(
      find.text('${pages.first.number} · 1/${pages.length}'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Další strana reportu'));
    await tester.pumpAndSettle();
    expect(find.text('${pages[1].number} · 2/${pages.length}'), findsOneWidget);
  });

  test(
    'synthetic PDF and canvas evidence use the shared physical frame',
    () async {
      final project = _project();
      final pdf = await ProjectExportService().pdf(project);
      expect(pdf.length, greaterThan(10000));
      final directory = Platform.environment['ECAD_FRAME_EVIDENCE'];
      if (directory == null) return;
      expect(
        Directory(directory).absolute.path,
        startsWith('${Directory.current.path}/.ai/'),
      );
      Directory(directory).createSync(recursive: true);
      File('$directory/frames.pdf').writeAsBytesSync(pdf);
      File(
        '$directory/frames.svg',
      ).writeAsStringSync(ProjectExportService().svg(project));
      final page = layoutDocument(
        project,
      ).pages.firstWhere((p) => p.report != null);
      final recorder = ui.PictureRecorder();
      final drawing = Canvas(recorder)..scale(4);
      paintReportPage(drawing, page.report!, frame: page.frame);
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        (page.sizeMm.width * 4).round(),
        (page.sizeMm.height * 4).round(),
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '$directory/report-canvas.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    },
  );
}
