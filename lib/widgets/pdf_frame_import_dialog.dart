// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';

import '../editor/drawing_graphics.dart';
import '../services/frame_layout.dart';
import '../services/pdf_frame_import.dart';

Future<EcadProject?> showPdfFrameImportDialog(
  BuildContext context,
  PdfImportReviewRequest request,
) {
  if (!request.isCurrent()) return Future.value(null);
  return showDialog<EcadProject>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PdfFrameImportDialog(request: request),
  );
}

enum _ObjectFilter { all, selected, hit }

class PdfFrameImportDialog extends StatefulWidget {
  const PdfFrameImportDialog({super.key, required this.request});
  final PdfImportReviewRequest request;

  @override
  State<PdfFrameImportDialog> createState() => _PdfFrameImportDialogState();
}

class _PdfFrameImportDialogState extends State<PdfFrameImportDialog> {
  late final draft = PdfFrameImportDraft(
    widget.request.project,
    reusableTemplates: widget.request.reusableTemplates,
  );
  int pageIndex = 0;
  EcadProject? result;
  final prepared = <String, PreparedFrameLayout>{};
  final reviewed = <String>{};
  List<String> hits = [];
  String? highlighted;
  _ObjectFilter filter = _ObjectFilter.all;
  final search = TextEditingController();
  String? error;
  bool stale = false;

  Sheet get sourcePage => draft.source.pages[pageIndex];
  PdfImportPageChoice get choice => draft.choice(sourcePage.id);

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  bool current() {
    if (widget.request.isCurrent()) return true;
    setState(() => stale = true);
    return false;
  }

  void change(VoidCallback action) {
    if (!current()) return;
    setState(() {
      action();
      error = null;
    });
  }

  void goToPage(int index) => change(() {
    pageIndex = index;
    hits = [];
    highlighted = null;
    filter = _ObjectFilter.all;
    search.clear();
    if (result != null) reviewed.add(sourcePage.id);
  });

  void showResult() {
    if (!current()) return;
    try {
      final candidate = draft.previewProject();
      final frames = <String, PreparedFrameLayout>{};
      for (final (index, sheet) in candidate.pages.indexed) {
        frames[sheet.id] = prepareFrameLayout(
          bindFrame(
            layoutFrameGeometry(
              sheet.paperSizeMm,
              resolveSheetFrame(candidate, sheet),
            ),
            candidate,
            sheet,
            FramePageContext(
              number: fullPageDesignation(sheet),
              documentIndex: index + 1,
              documentCount: candidate.pages.length,
            ),
          ),
        );
      }
      setState(() {
        result = candidate;
        prepared.addAll(frames);
        reviewed.clear();
        reviewed.add(sourcePage.id);
        highlighted = null;
        error = null;
      });
    } catch (failure) {
      setState(
        () =>
            error =
                'Náhled nelze připravit. Zkontrolujte šablonu a výběr objektů. $failure',
      );
    }
  }

  void accept() {
    if (!current() ||
        result == null ||
        reviewed.length != draft.source.pages.length) {
      return;
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final reviewing = result != null;
    final page = reviewing ? result!.pages[pageIndex] : sourcePage;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: SizedBox(
        width: math.min(1280, screen.width - 40),
        height: math.min(860, screen.height - 40),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                reviewing
                    ? 'Import PDF · kontrola výsledku'
                    : 'Import PDF · vzhled stran',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                reviewing
                    ? 'Prohlédněte všechny strany. Projekt se otevře až po přijetí celého importu.'
                    : 'Zachovejte původní vzhled, nebo vyberte rámeček a označte celé původní objekty k odstranění.',
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    tooltip: 'Předchozí strana',
                    onPressed:
                        pageIndex > 0 ? () => goToPage(pageIndex - 1) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: DropdownButton<int>(
                      key: const ValueKey('pdf-import-page'),
                      isExpanded: true,
                      value: pageIndex,
                      items: [
                        for (final (index, sheet) in draft.source.pages.indexed)
                          DropdownMenuItem(
                            value: index,
                            child: Text(
                              '${index + 1}/${draft.source.pages.length} · ${sheet.name} · '
                              '${draft.choice(sheet.id).replace ? 'Nový rámeček' : 'Původní vzhled'}'
                              '${reviewed.contains(sheet.id) && reviewing ? ' · Prohlédnuto' : ''}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (index) {
                        if (index != null) goToPage(index);
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: 'Další strana',
                    onPressed:
                        pageIndex + 1 < draft.source.pages.length
                            ? () => goToPage(pageIndex + 1)
                            : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              if (stale || error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    stale
                        ? 'Původní projekt se během importu změnil. Zrušte import a spusťte jej znovu.'
                        : error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: PdfImportPagePreview(
                        key: ValueKey('${page.id}-$reviewing'),
                        sheet: page,
                        frame: reviewing ? prepared[page.id] : null,
                        selectedIds:
                            !reviewing && choice.replace
                                ? choice.removedIds
                                : const {},
                        highlightedId: highlighted,
                        onHit:
                            !reviewing && choice.replace && !stale
                                ? (ids) => change(() {
                                  hits = ids;
                                  if (ids.length == 1) {
                                    draft.toggleRemoved(
                                      sourcePage.id,
                                      ids.single,
                                    );
                                  } else if (ids.length > 1) {
                                    filter = _ObjectFilter.hit;
                                    search.clear();
                                  }
                                })
                                : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: screen.width < 1000 ? 270 : 320,
                      child: reviewing ? resultControls() : selectionControls(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Zrušit import'),
                  ),
                  if (reviewing)
                    OutlinedButton(
                      onPressed:
                          stale
                              ? null
                              : () => change(() {
                                result = null;
                                prepared.clear();
                                reviewed.clear();
                              }),
                      child: const Text('Zpět k výběru'),
                    ),
                  if (!reviewing)
                    FilledButton(
                      onPressed: stale ? null : showResult,
                      child: const Text('Zkontrolovat výsledek'),
                    )
                  else
                    FilledButton(
                      onPressed:
                          !stale && reviewed.length == draft.source.pages.length
                              ? accept
                              : null,
                      child: const Text('Přijmout celý import'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget warningList() =>
      widget.request.warnings.isEmpty
          ? const SizedBox.shrink()
          : ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              'Upozornění převodu (${widget.request.warnings.length})',
            ),
            children: [
              for (final warning in widget.request.warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(warning),
                ),
            ],
          );

  Widget selectionControls() => CustomScrollView(
    key: ValueKey('pdf-object-list-${sourcePage.id}-${choice.replace}'),
    slivers: [
      SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButton<bool>(
              key: const ValueKey('pdf-frame-mode'),
              isExpanded: true,
              value: choice.replace,
              items: const [
                DropdownMenuItem(
                  value: false,
                  child: Text('Zachovat původní vzhled'),
                ),
                DropdownMenuItem(
                  value: true,
                  child: Text('Použít naši šablonu'),
                ),
              ],
              onChanged:
                  stale
                      ? null
                      : (replace) => change(() {
                        choice.replace = replace!;
                        highlighted = null;
                      }),
            ),
            if (!choice.replace) ...[
              const Text(
                'Všechny původní objekty zůstanou beze změny. K této straně se nepřidá další rámeček.',
              ),
              warningList(),
            ] else ...[
              DropdownButton<String>(
                key: const ValueKey('pdf-frame-template'),
                isExpanded: true,
                value: choice.templateId,
                items: [
                  for (final template in draft.templates)
                    DropdownMenuItem(
                      value: template.definition.id,
                      child: Text(
                        template.label,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged:
                    stale ? null : (id) => change(() => choice.templateId = id),
              ),
              const Text(
                'Kliknutím označte starý rámeček a popisové pole. Červeně jsou celé objekty k odstranění. Spojené cesty a obrázky nelze rozdělit.',
              ),
              const SizedBox(height: 6),
              Text(
                'K odstranění: ${choice.removedIds.length} z ${sourcePage.graphics.length}',
                key: const ValueKey('pdf-removed-count'),
              ),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Vrátit poslední výběr',
                    onPressed:
                        !stale && choice.canUndo
                            ? () => change(choice.undoSelection)
                            : null,
                    icon: const Icon(Icons.undo),
                  ),
                  TextButton(
                    onPressed:
                        !stale && choice.removedIds.isNotEmpty
                            ? () => change(choice.clearSelection)
                            : null,
                    child: const Text('Zrušit výběr'),
                  ),
                  IconButton(
                    tooltip: 'Obnovit stranu',
                    onPressed:
                        stale
                            ? null
                            : () =>
                                change(() => draft.resetPage(sourcePage.id)),
                    icon: const Icon(Icons.restart_alt),
                  ),
                ],
              ),
              const Text(
                'Strana bez starého rámečku: nevybírejte žádný objekt.',
                style: TextStyle(fontSize: 12),
              ),
              DropdownButton<_ObjectFilter>(
                isExpanded: true,
                value: filter,
                items: [
                  const DropdownMenuItem(
                    value: _ObjectFilter.all,
                    child: Text('Všechny objekty'),
                  ),
                  const DropdownMenuItem(
                    value: _ObjectFilter.selected,
                    child: Text('Vybrané k odstranění'),
                  ),
                  DropdownMenuItem(
                    value: _ObjectFilter.hit,
                    child: Text('V místě kliknutí (${hits.length})'),
                  ),
                ],
                onChanged: (value) => setState(() => filter = value!),
              ),
              if (filter == _ObjectFilter.hit && hits.length > 1)
                const Text(
                  'Objekty se překrývají. Vyberte je jednotlivě v seznamu.',
                  style: TextStyle(fontSize: 12),
                ),
              TextField(
                controller: search,
                decoration: const InputDecoration(
                  labelText: 'Hledat text nebo ID objektu',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 6),
            ],
          ],
        ),
      ),
      if (choice.replace) objectList(),
    ],
  );

  Widget objectList() {
    final query = search.text.toLowerCase();
    final removed = choice.removedIds;
    final graphics =
        sourcePage.graphics
            .where(
              (g) =>
                  (filter != _ObjectFilter.selected ||
                      removed.contains(g.id)) &&
                  (filter != _ObjectFilter.hit || hits.contains(g.id)) &&
                  (query.isEmpty ||
                      '${g.id} ${g.text}'.toLowerCase().contains(query)),
            )
            .toList();
    return SliverList.builder(
      itemCount: graphics.length,
      itemBuilder: (context, index) {
        final graphic = graphics[index];
        final kind = switch (graphic.kind) {
          DrawingKind.path => 'Cesta',
          DrawingKind.text => 'Text',
          DrawingKind.image => 'Obrázek',
        };
        return MouseRegion(
          onEnter: (_) => setState(() => highlighted = graphic.id),
          onExit: (_) => setState(() => highlighted = null),
          child: CheckboxListTile(
            key: ValueKey('pdf-object-${sourcePage.id}-${graphic.id}'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              '$kind · ${graphic.kind == DrawingKind.text ? graphic.text : graphic.id}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle:
                graphic.kind == DrawingKind.text
                    ? Text(
                      graphic.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                    : null,
            value: removed.contains(graphic.id),
            onChanged:
                stale
                    ? null
                    : (_) => change(
                      () => draft.toggleRemoved(sourcePage.id, graphic.id),
                    ),
          ),
        );
      },
    );
  }

  Widget resultControls() => ListView(
    children: [
      Text(
        'Prohlédnuto ${reviewed.length} z ${draft.source.pages.length} stran',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 16),
      Text(
        choice.replace ? 'Nový rámeček' : 'Původní vzhled',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (choice.replace) ...[
        Text('Odstraněno celých objektů: ${choice.removedIds.length}'),
        Text('Zachováno objektů: ${result!.pages[pageIndex].graphics.length}'),
        const SizedBox(height: 8),
        const Text(
          'Zbývající grafika je rovnoměrně přizpůsobena volné ploše nové šablony.',
        ),
        if (prepared[sourcePage.id]!.overflowFieldIds.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Některý text v rámečku se nevejde do svého pole. Zkontrolujte jej nebo zvolte jinou šablonu.',
              style: TextStyle(color: Color(0xffb45309)),
            ),
          ),
      ] else
        const Text('Původní grafika a její umístění zůstávají beze změny.'),
      const SizedBox(height: 16),
      const Text(
        'Zpět k výběru umožní změnit šablonu i vrátit odstraněné objekty.',
      ),
      warningList(),
    ],
  );
}

class PdfImportPagePreview extends StatefulWidget {
  const PdfImportPagePreview({
    super.key,
    required this.sheet,
    this.frame,
    this.selectedIds = const {},
    this.highlightedId,
    this.onHit,
  });
  final Sheet sheet;
  final PreparedFrameLayout? frame;
  final Set<String> selectedIds;
  final String? highlightedId;
  final ValueChanged<List<String>>? onHit;

  @override
  State<PdfImportPagePreview> createState() => _PdfImportPagePreviewState();
}

class _PdfImportPagePreviewState extends State<PdfImportPagePreview> {
  final transformation = TransformationController();
  final images = DrawingImageCache();
  List<DrawingVisual> visuals = [];

  @override
  void initState() {
    super.initState();
    updateGraphics();
  }

  @override
  void didUpdateWidget(PdfImportPagePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.sheet, widget.sheet)) updateGraphics();
  }

  void updateGraphics() {
    for (final visual in visuals) {
      visual.dispose();
    }
    visuals = [
      for (final graphic in widget.sheet.graphics) DrawingVisual(graphic),
    ];
    images.update(widget.sheet.graphics);
  }

  @override
  void dispose() {
    for (final visual in visuals) {
      visual.dispose();
    }
    images.dispose();
    transformation.dispose();
    super.dispose();
  }

  void zoom(double factor, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final scene = transformation.toScene(center);
    final scale = (transformation.value.getMaxScaleOnAxis() * factor).clamp(
      .5,
      16.0,
    );
    transformation.value =
        Matrix4.identity()
          ..translateByDouble(
            center.dx - scene.dx * scale,
            center.dy - scene.dy * scale,
            0,
            1,
          )
          ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      final paper = SheetTransform(widget.sheet).paperBoundsUnits;
      final scale =
          math.min(size.width / paper.width, size.height / paper.height) * .92;
      final origin = Offset(
        (size.width - paper.width * scale) / 2 - paper.x * scale,
        (size.height - paper.height * scale) / 2 - paper.y * scale,
      );
      return ColoredBox(
        color: const Color(0xffd8dde4),
        child: Stack(
          children: [
            InteractiveViewer(
              transformationController: transformation,
              minScale: .5,
              maxScale: 16,
              boundaryMargin: const EdgeInsets.all(600),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp:
                    widget.onHit == null
                        ? null
                        : (details) {
                          final point =
                              (details.localPosition - origin) / scale;
                          final tolerance =
                              4 /
                              (scale *
                                  transformation.value.getMaxScaleOnAxis());
                          widget.onHit!([
                            for (final visual in visuals.reversed)
                              if (visual.hitTest(point, tolerance))
                                visual.element.id,
                          ]);
                        },
                child: ListenableBuilder(
                  listenable: Listenable.merge([images, transformation]),
                  builder:
                      (context, _) => CustomPaint(
                        key: const ValueKey('pdf-page-artwork'),
                        size: size,
                        painter: _PdfImportPainter(
                          sheet: widget.sheet,
                          visuals: visuals,
                          images: images,
                          origin: origin,
                          scale: scale,
                          zoom: transformation.value.getMaxScaleOnAxis(),
                          selectedIds: widget.selectedIds,
                          highlightedId: widget.highlightedId,
                          frame: widget.frame,
                        ),
                      ),
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: Card(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Oddálit náhled',
                      onPressed: () => zoom(1 / 1.5, size),
                      icon: const Icon(Icons.remove),
                    ),
                    IconButton(
                      tooltip: 'Celá strana',
                      onPressed:
                          () => transformation.value = Matrix4.identity(),
                      icon: const Icon(Icons.fit_screen),
                    ),
                    IconButton(
                      tooltip: 'Přiblížit náhled',
                      onPressed: () => zoom(1.5, size),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
              ),
            ),
            const Positioned(
              bottom: 4,
              left: 4,
              child: IgnorePointer(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(6),
                    child: Text(
                      'Kolečko: přiblížení · tažení: posun',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _PdfImportPainter extends CustomPainter {
  _PdfImportPainter({
    required this.sheet,
    required this.visuals,
    required this.images,
    required this.origin,
    required this.scale,
    required this.zoom,
    required this.selectedIds,
    required this.highlightedId,
    required this.frame,
  });
  final Sheet sheet;
  final List<DrawingVisual> visuals;
  final DrawingImageCache images;
  final Offset origin;
  final double scale, zoom;
  final Set<String> selectedIds;
  final String? highlightedId;
  final PreparedFrameLayout? frame;

  @override
  void paint(Canvas canvas, Size size) {
    final transform = SheetTransform(sheet);
    final paper = transform.paperBoundsUnits;
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(scale);
    canvas.drawRect(
      Rect.fromLTWH(paper.x, paper.y, paper.width, paper.height),
      Paint()..color = Colors.white,
    );
    if (frame != null) {
      canvas.save();
      canvas.translate(paper.x, paper.y);
      canvas.scale(1 / transform.mmPerUnit);
      paintFrameLayout(canvas, frame!);
      canvas.restore();
    }
    for (final visual in visuals) {
      visual.paint(
        canvas,
        ink: const Color(0xff1e293b),
        paper: Colors.white,
        displayScale: scale * zoom,
        image: images.imageFor(visual.element),
      );
    }
    for (final visual in visuals) {
      final selected = selectedIds.contains(visual.element.id);
      if (!selected && visual.element.id != highlightedId) continue;
      final graphic = visual.element;
      final color =
          selected ? const Color(0xffdc2626) : const Color(0xff2563eb);
      canvas.save();
      canvas.translate(graphic.position.x, graphic.position.y);
      canvas.rotate(graphic.rotation * math.pi / 180);
      final path =
          visual.path ??
          (Path()..addRect(Rect.fromLTWH(0, 0, graphic.width, graphic.height)));
      if (graphic.fill != null || graphic.kind != DrawingKind.path) {
        canvas.drawPath(path, Paint()..color = color.withValues(alpha: .2));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: .85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(graphic.strokeWidth, 2.5 / (scale * zoom)),
      );
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PdfImportPainter oldDelegate) => true;
}
