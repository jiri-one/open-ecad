// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/services/project_import.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_ecad/services/pdf_frame_import.dart';
import 'package:open_ecad/widgets/pdf_frame_import_dialog.dart';

import 'pdf_import_fixtures.dart';

class _ImmediateImport extends ProjectImportService {
  @override
  Future<EcadProject?> importPdf() async => syntheticPdfProject();
}

Future<void> mountDialog(
  WidgetTester tester,
  EcadProject project, {
  required ValueChanged<EcadProject?> onComplete,
  bool Function()? isCurrent,
}) async {
  tester.view.physicalSize = const Size(1200, 850);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder:
            (context) => Scaffold(
              body: TextButton(
                onPressed:
                    () async => onComplete(
                      await showPdfFrameImportDialog(
                        context,
                        PdfImportReviewRequest(
                          project: project,
                          isCurrent: isCurrent ?? () => true,
                          warnings: ['Syntetické upozornění'],
                          reusableTemplates: [
                            FrameTemplates.builtin.copyWith(
                              name: 'Druhá šablona',
                            ),
                          ],
                        ),
                      ),
                    ),
                child: const Text('Importovat'),
              ),
            ),
      ),
    ),
  );
  await tester.tap(find.text('Importovat'));
  await tester.pumpAndSettle();
}

Future<void> replacement(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('pdf-frame-mode')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Použít naši šablonu').last);
  await tester.pumpAndSettle();
}

Offset sourcePoint(WidgetTester tester, Sheet sheet, Vec2 point) {
  final rect = tester.getRect(find.byKey(const ValueKey('pdf-page-artwork')));
  final paper = SheetTransform(sheet).paperBoundsUnits;
  final scale =
      math.min(rect.width / paper.width, rect.height / paper.height) * .92;
  return rect.topLeft +
      Offset(
        (rect.width - paper.width * scale) / 2 + (point.x - paper.x) * scale,
        (rect.height - paper.height * scale) / 2 + (point.y - paper.y) * scale,
      );
}

void main() {
  setUpAll(() async {
    final fonts =
        FontLoader('NotoSans')
          ..addFont(rootBundle.load('assets/fonts/NotoSans-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/NotoSans-SemiBold.ttf'));
    await fonts.load();
  });

  testWidgets(
    'workspace menu reviews before opening and cancellation opens no partial document',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = EditorController(
        startEmpty: true,
        importer: _ImmediateImport(),
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(OpenEcadApp(controller: app));
      await tester.pumpAndSettle();
      final workspace =
          tester
              .widget<EditorWorkspace>(find.byType(EditorWorkspace))
              .workspace!;
      for (final cancel in [true, false]) {
        await tester.tap(find.byTooltip('Soubor'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Importovat PDF jako grafiku…'));
        await tester.pumpAndSettle();
        expect(find.byType(PdfFrameImportDialog), findsOneWidget);
        expect(workspace.documents, hasLength(1));
        await tester.tap(find.text('Zkontrolovat výsledek'));
        await tester.pumpAndSettle();
        expect(workspace.documents, hasLength(1));
        await tester.tap(
          find.text(cancel ? 'Zrušit import' : 'Přijmout celý import'),
        );
        await tester.pumpAndSettle();
        expect(workspace.documents, hasLength(cancel ? 1 : 2));
      }
      expect(workspace.active.project.id, 'pdf-import-test');
      expect(workspace.active.dirty, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'preserve reviews all pages, displays warnings and returns explicit none',
    (tester) async {
      final original = syntheticPdfProject(pages: 2);
      EcadProject? accepted;
      await mountDialog(
        tester,
        original,
        onComplete: (result) => accepted = result,
      );
      await tester.tap(find.text('Zkontrolovat výsledek'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Přijmout celý import'),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Prohlédnuto 1 z 2 stran'), findsOneWidget);
      await tester.tap(find.byTooltip('Další strana'));
      await tester.pumpAndSettle();
      expect(find.text('Prohlédnuto 2 z 2 stran'), findsOneWidget);
      await tester.tap(find.text('Upozornění převodu (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Syntetické upozornění'), findsOneWidget);
      await tester.tap(find.text('Přijmout celý import'));
      await tester.pumpAndSettle();
      expect(accepted!.toJson(), original.toJson());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit object selection, deselect, undo, result and back use original graphics',
    (tester) async {
      final original = syntheticPdfProject();
      EcadProject? accepted;
      await mountDialog(
        tester,
        original,
        onComplete: (result) => accepted = result,
      );
      await replacement(tester);
      final border = find.byKey(const ValueKey('pdf-object-page1-border1'));
      await tester.tap(border);
      await tester.pumpAndSettle();
      expect(find.text('K odstranění: 1 z 3'), findsOneWidget);
      expect(
        tester
            .widget<PdfImportPagePreview>(find.byType(PdfImportPagePreview))
            .selectedIds,
        {'border1'},
      );
      await tester.tap(border);
      await tester.pumpAndSettle();
      expect(find.text('K odstranění: 0 z 3'), findsOneWidget);
      await tester.tap(find.byTooltip('Vrátit poslední výběr'));
      await tester.pumpAndSettle();
      expect(find.text('K odstranění: 1 z 3'), findsOneWidget);
      await tester.tap(find.text('Zkontrolovat výsledek'));
      await tester.pumpAndSettle();
      final first =
          tester
              .widget<PdfImportPagePreview>(find.byType(PdfImportPagePreview))
              .sheet;
      expect(first.graphics.map((g) => g.id), ['text1', 'image1']);
      final frame =
          tester
              .widget<PdfImportPagePreview>(find.byType(PdfImportPagePreview))
              .frame!;
      expect(frame.source.geometry.titleBlockRectMm, isNotNull);
      await tester.tap(find.text('Zpět k výběru'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PdfImportPagePreview>(find.byType(PdfImportPagePreview))
            .sheet,
        same(original.pages.single),
      );
      await tester.tap(find.text('Zkontrolovat výsledek'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PdfImportPagePreview>(find.byType(PdfImportPagePreview))
            .sheet
            .toJson(),
        first.toJson(),
      );
      await tester.tap(find.text('Přijmout celý import'));
      await tester.pumpAndSettle();
      expect(accepted!.pages.single.toJson(), first.toJson());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'navigation retains per page choice and reset only resets one page',
    (tester) async {
      await mountDialog(
        tester,
        syntheticPdfProject(pages: 2),
        onComplete: (_) {},
      );
      await replacement(tester);
      await tester.tap(find.byKey(const ValueKey('pdf-object-page1-border1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Další strana'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButton<bool>>(
              find.byKey(const ValueKey('pdf-frame-mode')),
            )
            .value,
        isFalse,
      );
      await replacement(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('pdf-object-page2-image2')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pdf-object-page2-image2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Předchozí strana'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PdfImportPagePreview>(find.byType(PdfImportPagePreview))
            .selectedIds,
        {'border1'},
      );
      await tester.tap(find.byTooltip('Obnovit stranu'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButton<bool>>(
              find.byKey(const ValueKey('pdf-frame-mode')),
            )
            .value,
        isFalse,
      );
      await tester.tap(find.byTooltip('Další strana'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PdfImportPagePreview>(find.byType(PdfImportPagePreview))
            .selectedIds,
        {'image2'},
      );
      await tester.tap(find.text('Zrušit import'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stroke hit testing leaves frame interior clear and overlaps expose every object',
    (tester) async {
      final initial = syntheticPdfProject();
      final page = initial.pages.single;
      final overlay = DrawingElement(
        id: 'overlay',
        kind: DrawingKind.path,
        position: Vec2.zero,
        width: 420,
        height: 297,
        fill: '#ffffff',
        opacity: .15,
        path: [
          PathSegment(verb: PathVerb.moveTo, points: [Vec2.zero]),
          PathSegment(verb: PathVerb.lineTo, points: [const Vec2(420, 0)]),
          PathSegment(verb: PathVerb.lineTo, points: [const Vec2(420, 297)]),
          PathSegment(verb: PathVerb.lineTo, points: [const Vec2(0, 297)]),
          PathSegment(verb: PathVerb.close),
        ],
      );
      final original = initial.copyWith(
        pages: [
          page.copyWith(graphics: [...page.graphics, overlay]),
        ],
      );
      await mountDialog(tester, original, onComplete: (_) {});
      await replacement(tester);
      await tester.tapAt(sourcePoint(tester, page, const Vec2(90, 95)));
      await tester.pumpAndSettle();
      expect(find.text('V místě kliknutí (2)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pdf-object-page1-text1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('pdf-object-page1-overlay')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('pdf-object-page1-border1')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('pdf-object-page1-text1')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PdfImportPagePreview>(find.byType(PdfImportPagePreview))
            .selectedIds,
        {'text1'},
      );
      await tester.tap(find.byTooltip('Přiblížit náhled'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        greaterThan(1),
      );
      await tester.tap(find.byTooltip('Celá strana'));
      await tester.pumpAndSettle();
      await tester.tapAt(sourcePoint(tester, page, const Vec2(10, 160)));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('pdf-object-page1-border1')),
        findsOneWidget,
      );
      await tester.tap(find.text('Zrušit import'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unframed page needs no deletion and current template is reusable',
    (tester) async {
      EcadProject? accepted;
      await mountDialog(
        tester,
        syntheticPdfProject(border: false),
        onComplete: (result) => accepted = result,
      );
      await replacement(tester);
      await tester.tap(find.byKey(const ValueKey('pdf-frame-template')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Aktuální projekt · Druhá šablona').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zkontrolovat výsledek'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Přijmout celý import'));
      await tester.pumpAndSettle();
      expect(accepted!.pages.single.graphics.map((g) => g.id), [
        'text1',
        'image1',
      ]);
      expect(
        accepted!.pages.single.frame.templateId,
        isNot(FrameTemplates.builtinId),
      );
      expect(accepted!.frameTemplates.last.name, 'Druhá šablona');
      expect(tester.takeException(), isNull);
    },
  );

  for (final reviewing in [false, true]) {
    testWidgets(
      'cancel at ${reviewing ? 'result' : 'selection'} discards all changes',
      (tester) async {
        var completed = false;
        EcadProject? accepted;
        await mountDialog(
          tester,
          syntheticPdfProject(),
          onComplete: (result) {
            completed = true;
            accepted = result;
          },
        );
        await replacement(tester);
        await tester.tap(
          find.byKey(const ValueKey('pdf-object-page1-border1')),
        );
        await tester.pumpAndSettle();
        if (reviewing) {
          await tester.tap(find.text('Zkontrolovat výsledek'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Zrušit import'));
        await tester.pumpAndSettle();
        expect(completed, isTrue);
        expect(accepted, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('selection controls remain usable in smaller desktop windows', (
    tester,
  ) async {
    await mountDialog(tester, syntheticPdfProject(), onComplete: (_) {});
    await replacement(tester);
    for (final size in [const Size(960, 768), const Size(800, 600)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('pdf-object-page1-image1')),
        150,
        scrollable:
            find
                .descendant(
                  of: find.byKey(const ValueKey('pdf-object-list-page1-true')),
                  matching: find.byType(Scrollable),
                )
                .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pdf-object-page1-image1')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('Zrušit import'));
    await tester.pumpAndSettle();
  });

  testWidgets('stale result cannot be confirmed', (tester) async {
    var active = true;
    var completed = false;
    await mountDialog(
      tester,
      syntheticPdfProject(),
      isCurrent: () => active,
      onComplete: (_) => completed = true,
    );
    await tester.tap(find.text('Zkontrolovat výsledek'));
    await tester.pumpAndSettle();
    active = false;
    await tester.tap(find.text('Přijmout celý import'));
    await tester.pumpAndSettle();
    expect(completed, isFalse);
    expect(
      find.textContaining('Původní projekt se během importu změnil'),
      findsOneWidget,
    );
    await tester.tap(find.text('Zrušit import'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'preview paints vector, image, text and all segments of selected combined path',
    (tester) async {
      final sheet = syntheticPdfProject().pages.single;
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 700,
                height: 550,
                child: PdfImportPagePreview(
                  sheet: sheet,
                  selectedIds: {'border1'},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final data =
          (await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            image.dispose();
            return bytes;
          }))!;
      final paper = SheetTransform(sheet).paperBoundsUnits;
      final scale = math.min(700 / paper.width, 550 / paper.height) * .92;
      final origin = Offset(
        (700 - paper.width * scale) / 2 - paper.x * scale,
        (550 - paper.height * scale) / 2 - paper.y * scale,
      );
      bool redAt(Vec2 point) {
        final pos = origin + Offset(point.x, point.y) * scale;
        for (var dy = -2; dy <= 2; dy++) {
          for (var dx = -2; dx <= 2; dx++) {
            final index =
                ((pos.dy.round() + dy) * 700 + pos.dx.round() + dx) * 4;
            if (data.getUint8(index) > 150 &&
                data.getUint8(index + 1) < 100 &&
                data.getUint8(index + 2) < 100) {
              return true;
            }
          }
        }
        return false;
      }

      expect(redAt(const Vec2(10, 150)), isTrue);
      expect(redAt(const Vec2(340, 265)), isTrue);
      expect(redAt(const Vec2(210, 110)), isTrue);
      final textBox = Rect.fromLTWH(
        origin.dx + 70 * scale,
        origin.dy + 90 * scale,
        80 * scale,
        12 * scale,
      );
      var textPixels = 0;
      for (var y = textBox.top.ceil(); y < textBox.bottom.floor(); y++) {
        for (var x = textBox.left.ceil(); x < textBox.right.floor(); x++) {
          final i = (y * 700 + x) * 4;
          if (data.getUint8(i) < 120 &&
              data.getUint8(i + 1) < 120 &&
              data.getUint8(i + 2) < 120) {
            textPixels++;
          }
        }
      }
      expect(textPixels, greaterThan(20));
      expect(tester.takeException(), isNull);
    },
  );
}
