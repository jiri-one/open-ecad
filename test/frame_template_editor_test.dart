// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/widgets/frame_template_editor.dart';
import 'package:open_ecad/widgets/frame_template_preview.dart';

FrameTemplate template() => FrameTemplate(
  id: 'synthetic',
  name: 'Vlastní',
  titleBlock: FrameTitleBlock(
    widthMm: 160,
    heightMm: 40,
    fields: const [
      FrameField(
        id: 'movable',
        rectMm: RectMm(x: 10, y: 5, width: 35, height: 10),
        text: '{{project.name}}',
      ),
      FrameField(
        id: 'other',
        rectMm: RectMm(x: 100, y: 22, width: 40, height: 10),
        text: 'Druhé pole',
      ),
    ],
    lines: const [FrameLine(Vec2(0, 20), Vec2(160, 20))],
  ),
);
EcadProject project(FrameTemplate t) => EcadProject(
  id: 'editor-test',
  name: 'Zkouška',
  frameTemplates: [t],
  defaultFrame: FrameChoice.template(t.id),
  pages: [Sheet(id: 'page', name: 'List', number: '01')],
);

Future<void> openEditor(
  WidgetTester tester,
  ValueChanged<FrameTemplate?> onResult, {
  FrameTemplate? initial,
  Size size = const Size(1180, 800),
  bool Function()? canCommit,
  EcadProject? projectData,
}) async {
  final t = initial ?? template();
  final p = projectData ?? project(t);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder:
              (context) => TextButton(
                onPressed: () async {
                  onResult(
                    await editFrameTemplate(
                      context,
                      template: t,
                      project: p,
                      sheet: p.pages.first,
                      canCommit: canCommit ?? () => true,
                    ),
                  );
                },
                child: const Text('Otevřít'),
              ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Otevřít'));
  await tester.pumpAndSettle();
}

Future<void> click(WidgetTester tester, String label) async {
  final finder = find.text(label).last;
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder input(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(TextField),
);
Future<void> number(WidgetTester tester, String key, String value) async {
  final finder = input(key);
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Offset fieldPoint(WidgetTester tester, String id) {
  final widget = tester.widget<FrameTemplatePreview>(
    find.byType(FrameTemplatePreview),
  );
  final rect = widget.frame.source.geometry.titleBlockRectMm!;
  final bounds = Rect.fromLTWH(
    rect.x,
    rect.y,
    rect.width,
    rect.height,
  ).inflate(4);
  final box = tester.getRect(
    find.byKey(const ValueKey('frame-preview-canvas')),
  );
  final scale = math.min(
    (box.width - 16) / bounds.width,
    (box.height - 16) / bounds.height,
  );
  final field =
      widget.frame.source.geometry.titleFieldSlots
          .firstWhere((f) => f.id == id)
          .rectMm;
  final offset =
      Offset(
        (box.width - bounds.width * scale) / 2,
        (box.height - bounds.height * scale) / 2,
      ) -
      bounds.topLeft * scale;
  return box.topLeft +
      offset +
      Offset(field.x + field.width / 2, field.y + field.height / 2) * scale;
}

void main() {
  testWidgets('zones-off template saves narrow margins', (tester) async {
    final t = template();
    final p = project(
      t,
    ).copyWith(defaultFrame: FrameChoice.template(t.id, zones: false));
    FrameTemplate? result;
    await openEditor(tester, (v) => result = v, initial: t, projectData: p);
    await number(tester, 'margin-left', '3');
    await click(tester, 'Použít v návrhu');
    expect(result!.marginsMm.left, 3);
    requireValidProject(p.copyWith(frameTemplates: [result!]));
  });

  testWidgets('unused template can save despite incompatible preview paper', (
    tester,
  ) async {
    final t = template().copyWith(
      titleBlock: FrameTitleBlock(widthMm: 400, heightMm: 40),
    );
    final p = project(t).copyWith(defaultFrame: const FrameChoice.none());
    FrameTemplate? result;
    await openEditor(tester, (v) => result = v, initial: t, projectData: p);
    await click(tester, 'Použít v návrhu');
    expect(result!.titleBlock.widthMm, 400);
  });

  testWidgets('preview paper does not constrain saving actual sheet geometry', (
    tester,
  ) async {
    final t = template().copyWith(
      titleBlock: FrameTitleBlock(widthMm: 300, heightMm: 40),
    );
    FrameTemplate? result;
    await openEditor(tester, (v) => result = v, initial: t);
    await tester.tap(find.byTooltip('Papír náhledu'));
    await tester.pumpAndSettle();
    await click(tester, 'A4 na šířku');
    await click(tester, 'Použít v návrhu');
    expect(result!.titleBlock.widthMm, 300);
  });

  testWidgets('save validates other sheets actually using the template', (
    tester,
  ) async {
    final t = template();
    final p = project(t).copyWith(
      pages: [
        project(t).pages.single,
        Sheet(
          id: 'small',
          name: 'A4',
          number: '2',
          paperSizeMm: SizeMm.a4Landscape,
        ),
      ],
    );
    FrameTemplate? result;
    await openEditor(tester, (v) => result = v, initial: t, projectData: p);
    await number(tester, 'title-width', '300');
    await click(tester, 'Použít v návrhu');
    expect(result, isNull);
    expect(find.byKey(const ValueKey('frame-error')), findsOneWidget);
  });

  testWidgets(
    'preview selects fields and dragging changes saved local geometry',
    (tester) async {
      FrameTemplate? result;
      await openEditor(tester, (v) => result = v);
      await tester.tapAt(fieldPoint(tester, 'other'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FrameTemplatePreview>(find.byType(FrameTemplatePreview))
            .selectedFieldId,
        'other',
      );
      await tester.dragFrom(
        fieldPoint(tester, 'movable'),
        const Offset(60, 25),
      );
      await tester.pumpAndSettle();
      final preview = tester.widget<FrameTemplatePreview>(
        find.byType(FrameTemplatePreview),
      );
      expect(preview.selectedFieldId, 'movable');
      final abs =
          preview.frame.source.geometry.titleFieldSlots
              .firstWhere((f) => f.id == 'movable')
              .rectMm;
      final origin = preview.frame.source.geometry.titleBlockRectMm!;
      expect(abs.x - origin.x, greaterThan(10));
      expect(abs.y - origin.y, greaterThan(5));
      await click(tester, 'Pole');
      await number(tester, 'field-movable-x', '21,5');
      await number(tester, 'field-movable-width', '50');
      await click(tester, 'Použít v návrhu');
      expect(result, isNotNull);
      expect(result!.titleBlock.fields.first.rectMm.x, 21.5);
      expect(result!.titleBlock.fields.first.rectMm.width, 50);
      expect(result!.titleBlock.fields.first.rectMm.y, greaterThan(5));
      expect(
        result!.titleBlock.fields.last.toJson(),
        template().titleBlock.fields.last.toJson(),
      );
    },
  );

  testWidgets('invalid binding and unfinished numbers do not crash or save', (
    tester,
  ) async {
    FrameTemplate? result;
    await openEditor(tester, (v) => result = v);
    await number(tester, 'margin-left', '-');
    await click(tester, 'Použít v návrhu');
    expect(result, isNull);
    expect(find.textContaining('Doplňte platná čísla'), findsOneWidget);
    await number(tester, 'margin-left', '10');
    await click(tester, 'Pole');
    await tester.enterText(
      find.byKey(const ValueKey('frame-field-text')),
      '{{project.password}}',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await click(tester, 'Použít v návrhu');
    expect(find.byType(FrameTemplateEditor), findsOneWidget);
    expect(result, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('frame-field-text')),
      '{{document.customer}}',
    );
    await tester.pumpAndSettle();
    await click(tester, 'Použít v návrhu');
    expect(result!.titleBlock.fields.first.text, '{{document.customer}}');
  });

  testWidgets(
    'add remove and coordinate editing make actual field and separator definitions',
    (tester) async {
      FrameTemplate? result;
      await openEditor(tester, (v) => result = v);
      await click(tester, 'Pole');
      await click(tester, 'Přidat pole');
      await tester.enterText(
        find.byKey(const ValueKey('frame-field-text')),
        'Vlastní text',
      );
      await click(tester, 'Čáry');
      await click(tester, 'Přidat oddělovač');
      await number(tester, 'line-1-x1', '4');
      await number(tester, 'line-1-y1', '30');
      await number(tester, 'line-1-x2', '155');
      await number(tester, 'line-1-y2', '30');
      await tester.ensureVisible(find.byTooltip('Odstranit oddělovač 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Odstranit oddělovač 1'));
      await tester.pumpAndSettle();
      await click(tester, 'Použít v návrhu');
      expect(result!.titleBlock.fields, hasLength(3));
      expect(result!.titleBlock.fields.last.text, 'Vlastní text');
      expect(result!.titleBlock.lines, hasLength(1));
      expect(result!.titleBlock.lines.single.from, const Vec2(4, 30));
      expect(result!.titleBlock.lines.single.to, const Vec2(155, 30));
    },
  );

  testWidgets(
    'binding picker inserts documented binding and rejects invalid custom key',
    (tester) async {
      FrameTemplate? result;
      await openEditor(tester, (v) => result = v);
      await click(tester, 'Pole');
      await tester.enterText(
        find.byKey(const ValueKey('frame-field-text')),
        'Autor: ',
      );
      await click(tester, 'Vložit údaj…');
      await tester.ensureVisible(find.text('Kreslil').last);
      await tester.tap(find.text('Kreslil').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('frame-field-text')))
            .controller!
            .text,
        'Autor: {{document.drawnBy}}',
      );
      await tester.enterText(
        find.byKey(const ValueKey('frame-custom-binding')),
        'bad.key',
      );
      await tester.tap(find.byTooltip('Vložit vlastní údaj'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Klíč musí začínat'), findsOneWidget);
      await click(tester, 'Použít v návrhu');
      expect(
        result!.titleBlock.fields.first.text,
        'Autor: {{document.drawnBy}}',
      );
    },
  );

  testWidgets(
    'visible overflow and invalid title size; cancel keeps source untouched',
    (tester) async {
      final t = template().copyWith(
        titleBlock: template().titleBlock.copyWith(
          fields: [
            template().titleBlock.fields.first.copyWith(
              text: 'DLOUHÝ TEXT ' * 40,
            ),
          ],
        ),
      );
      FrameTemplate? result;
      await openEditor(tester, (v) => result = v, initial: t);
      expect(find.byKey(const ValueKey('frame-overflow')), findsOneWidget);
      await number(tester, 'title-width', '3');
      expect(tester.takeException(), isNull);
      expect(find.byType(FrameTemplatePreview), findsNothing);
      await click(tester, 'Zrušit');
      expect(result, isNull);
      expect(t.titleBlock.widthMm, 160);
    },
  );

  testWidgets('stale ownership rejects template result at save', (
    tester,
  ) async {
    var current = true;
    FrameTemplate? result;
    await openEditor(tester, (v) => result = v, canCommit: () => current);
    current = false;
    await click(tester, 'Použít v návrhu');
    expect(result, isNull);
    expect(
      find.textContaining('Projekt nebo list se mezitím změnil'),
      findsOneWidget,
    );
    await click(tester, 'Zrušit');
  });

  for (final size in [const Size(1024, 640), const Size(760, 600)]) {
    testWidgets('editor keeps Save Cancel at $size with all control tabs', (
      tester,
    ) async {
      await openEditor(tester, (_) {}, size: size);
      for (final tab in ['Pole', 'Čáry', 'Rámeček']) {
        await click(tester, tab);
        expect(tester.takeException(), isNull);
        expect(find.text('Použít v návrhu').hitTestable(), findsOneWidget);
        expect(find.text('Zrušit').hitTestable(), findsOneWidget);
      }
      await click(tester, 'Zrušit');
    });
  }
  testWidgets(
    'unfinished geometry survives field and tab switching until corrected',
    (tester) async {
      FrameTemplate? result;
      await openEditor(tester, (v) => result = v);
      await click(tester, 'Pole');
      await number(tester, 'field-movable-x', '-');
      await tester.tapAt(fieldPoint(tester, 'other'));
      await tester.pumpAndSettle();
      await click(tester, 'Čáry');
      await click(tester, 'Pole');
      await tester.tapAt(fieldPoint(tester, 'movable'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input('field-movable-x')).controller!.text,
        '-',
      );
      await click(tester, 'Použít v návrhu');
      expect(result, isNull);
      await number(tester, 'field-movable-x', '12');
      await click(tester, 'Použít v návrhu');
      expect(result!.titleBlock.fields.first.rectMm.x, 12);
    },
  );
  testWidgets('preview bindings count physical report continuation pages', (
    tester,
  ) async {
    final t = template().copyWith(
      titleBlock: template().titleBlock.copyWith(
        fields: [
          template().titleBlock.fields.first.copyWith(
            text: '{{page.count}} / {{page.sheetCount}}',
          ),
        ],
      ),
    );
    final p = project(t).copyWith(
      pages: [
        Sheet(
          id: 'report',
          name: 'Kusovník',
          number: '01',
          type: SheetType.billOfMaterials,
          paperSizeMm: SizeMm.a4Landscape,
          report: const BomTableSpec(kind: BomReportKind.articles),
        ),
        Sheet(id: 'tail', name: 'Poslední', number: '02'),
      ],
      articles: [
        for (var i = 0; i < 100; i++)
          Article(id: 'a$i', name: 'Součást $i', unit: QuantityUnit.piece),
      ],
      components: [
        for (var i = 0; i < 100; i++)
          Component(
            id: 'c$i',
            kind: ComponentKind.material,
            articleId: 'a$i',
            quantity: const Quantity.pieces(1),
          ),
      ],
    );
    await openEditor(tester, (_) {}, initial: t, projectData: p);
    final prepared =
        tester
            .widget<FrameTemplatePreview>(find.byType(FrameTemplatePreview))
            .frame;
    final counts =
        prepared.source.texts
            .firstWhere((f) => f.id == 'movable')
            .text
            .split(' / ')
            .map(int.parse)
            .toList();
    expect(counts.first, greaterThan(2));
    expect(counts.last, counts.first - 1);
    await click(tester, 'Zrušit');
  });
}
