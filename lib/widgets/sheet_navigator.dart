// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../app/typography.dart';
import '../app/workspace_controller.dart';
import '../services/sheet_navigation.dart';
import 'components.dart';
import 'frame_settings.dart';
import 'frame_settings_draft.dart';
import 'sheet_context_menu.dart';
import 'sheet_filter.dart';
import 'sheet_types.dart';
import 'structure_tree.dart';

String _sheetTitle(Sheet sheet) =>
    '${fullPageDesignation(sheet)} · ${sheet.name}';
String _singleLine(String text) =>
    text.replaceAll(RegExp(r'[\r\n\u2028\u2029]+'), ' ');
StructureContext _sheetStructure(Sheet sheet) => sheet.structure;
Object _sheetKey(Sheet sheet) => sheet.id;

typedef _TextMetrics =
    ({TextStyle style, TextScaler scaler, TextDirection direction});

class _SheetTreeData {
  _SheetTreeData(this.project, this.filter, {_SheetTreeData? previous})
    : items =
          !filter.isActive
              ? project.pages
              : project.pages.where(filter.matches).toList() {
    _metrics = previous?._metrics;
    _widths = previous?._widths ?? {};
  }

  final EcadProject project;
  final SheetFilter filter;
  final List<Sheet> items;
  _TextMetrics? _metrics;
  Map<(String, double), double> _widths = {};
  double? _width;

  double width(_TextMetrics metrics) {
    if (_metrics == metrics && _width != null) return _width!;
    final previous =
        _metrics == metrics ? _widths : <(String, double), double>{};
    final measured = <(String, double), double>{};
    final painter = TextPainter(
      textDirection: metrics.direction,
      textScaler: metrics.scaler,
      maxLines: 1,
    );
    double measure(String text, double size) {
      final key = (text, size);
      final cached = previous[key];
      if (cached != null) return measured[key] = cached;
      painter.text = TextSpan(
        text: text,
        style: metrics.style.copyWith(fontSize: size),
      );
      painter.layout();
      return measured[key] = painter.width;
    }

    var width = measure('${_singleLine(project.name)} ●', 14) + 92;
    for (final sheet in items) {
      final depth = sheet.structure.paths.fold(
        0,
        (sum, path) => sum + path.length,
      );
      width = math.max(
        width,
        measure(_singleLine(_sheetTitle(sheet)), 13) +
            (depth + 1) * structureTreeIndent +
            100,
      );
    }
    painter.dispose();
    _metrics = metrics;
    _widths = measured;
    return _width = width;
  }
}

class SheetNavigator extends StatefulWidget {
  const SheetNavigator({
    super.key,
    required this.controller,
    required this.onAddSheet,
    required this.onRenameSheet,
    this.workspace,
    this.filter,
    this.onCloseProject,
  });

  final EditorController controller;
  final WorkspaceController? workspace;
  final SheetFilter? filter;
  final VoidCallback onAddSheet, onRenameSheet;
  final ValueChanged<EditorController>? onCloseProject;

  @override
  State<SheetNavigator> createState() => _SheetNavigatorState();
}

class _SheetNavigatorState extends State<SheetNavigator> {
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  final _data = <EditorController, _SheetTreeData>{};
  final _expanded = <String, bool>{};

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  _SheetTreeData _items(EditorController doc, SheetFilter filter) {
    final previous = _data[doc];
    if (identical(previous?.project, doc.project) &&
        previous?.filter == filter) {
      return previous!;
    }
    return _data[doc] = _SheetTreeData(doc.project, filter, previous: previous);
  }

  bool _isExpanded(EditorController doc) =>
      _expanded.putIfAbsent(doc.documentSessionId, () {
        final saved = PageStorage.maybeOf(context)?.readState(
          context,
          identifier: ('sheet-project', doc.documentSessionId),
        );
        return saved is bool ? saved : true;
      });

  void _toggle(EditorController doc) {
    final next = !_isExpanded(doc);
    setState(() => _expanded[doc.documentSessionId] = next);
    PageStorage.maybeOf(context)?.writeState(
      context,
      next,
      identifier: ('sheet-project', doc.documentSessionId),
    );
  }

  Widget _projectHeader(EditorController doc) => ListTile(
    dense: true,
    minLeadingWidth: 50,
    horizontalTitleGap: 8,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
    title: Tooltip(
      message: doc.project.name,
      child: Text(
        '${_singleLine(doc.project.name)}${doc.dirty ? ' ●' : ''}',
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium!.copyWith(fontSize: 14),
      ),
    ),
    subtitle: Tooltip(
      message: doc.currentFile?.path ?? doc.fileName ?? 'Bez souboru',
      child: Text(
        doc.fileName ?? 'Bez souboru',
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
    ),
    leading: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _isExpanded(doc) ? Icons.expand_more : Icons.chevron_right,
          size: 18,
        ),
        const SizedBox(width: 4),
        Builder(
          builder: (context) {
            FrameEditGuard? menuGuard;
            return PopupMenuButton<String>(
              onOpened: () => menuGuard = FrameEditGuard(doc),
              tooltip: 'Projekt ${doc.project.name}',
              onSelected: (action) {
                if (!(menuGuard?.current ?? false)) return;
                if (action == 'frame') {
                  editFrameSettings(context, doc);
                } else {
                  widget.onCloseProject?.call(doc);
                }
              },
              itemBuilder:
                  (_) => const [
                    PopupMenuItem(
                      value: 'frame',
                      child: Text('Rámečky a údaje projektu…'),
                    ),
                    PopupMenuItem(
                      value: 'close',
                      child: Text('Zavřít projekt…'),
                    ),
                  ],
              child: const SizedBox.square(
                dimension: 28,
                child: Icon(Icons.folder_open, size: 18),
              ),
            );
          },
        ),
      ],
    ),
    onTap: () => _toggle(doc),
  );

  Widget _sheet(EditorController doc, Sheet sheet) => SheetContextMenu(
    controller: doc,
    sheet: sheet,
    workspace: widget.workspace,
    onRenameSheet: widget.onRenameSheet,
    child: ListTile(
      dense: true,
      minTileHeight: interfaceRowHeight(context, minimum: 36, fontSize: 13),
      minVerticalPadding: 0,
      minLeadingWidth: 20,
      horizontalTitleGap: 8,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      selected: doc == widget.controller && sheet.id == doc.activeSheetId,
      leading: Tooltip(
        message: sheet.type.label,
        child: Icon(sheetTypeIcon(sheet.type), size: 16),
      ),
      title: Tooltip(
        message: _sheetTitle(sheet),
        child: Text(
          _singleLine(_sheetTitle(sheet)),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium!.copyWith(fontSize: 13),
        ),
      ),
      onTap:
          () =>
              widget.workspace == null
                  ? doc.setSheet(sheet.id)
                  : widget.workspace!.openSheet(
                    doc,
                    sheet.id,
                    newTab:
                        HardwareKeyboard.instance.isControlPressed ||
                        HardwareKeyboard.instance.isMetaPressed,
                  ),
      trailing: SheetContextMenu(
        controller: doc,
        sheet: sheet,
        workspace: widget.workspace,
        onRenameSheet: widget.onRenameSheet,
        tooltip:
            doc == widget.controller && sheet.id == doc.activeSheetId
                ? 'Vlastnosti listu'
                : null,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final docs = widget.workspace?.documents ?? [widget.controller];
    final filter = widget.filter ?? SheetFilter.empty;
    _data.removeWhere((doc, _) => !docs.contains(doc));
    _expanded.removeWhere(
      (id, _) => !docs.any((doc) => doc.documentSessionId == id),
    );
    final metrics = (
      style: Theme.of(context).textTheme.bodyMedium!,
      scaler: MediaQuery.textScalerOf(context),
      direction: Directionality.of(context),
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        var width = bounds.maxWidth;
        for (final doc in docs) {
          width = math.max(width, _items(doc, filter).width(metrics));
        }
        final overflow = width > bounds.maxWidth + .5;
        final footer = overflow ? 12.0 : 0.0;
        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: Scrollbar(
            key: const ValueKey('sheet-tree-horizontal-scrollbar'),
            controller: _horizontal,
            thumbVisibility: overflow,
            trackVisibility: overflow,
            interactive: true,
            thickness: 8,
            scrollbarOrientation: ScrollbarOrientation.bottom,
            notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
            child: Padding(
              padding: EdgeInsets.only(bottom: footer),
              child: Scrollbar(
                controller: _vertical,
                thumbVisibility: true,
                interactive: true,
                notificationPredicate: (n) => n.metrics.axis == Axis.vertical,
                child: SingleChildScrollView(
                  key: const PageStorageKey('sheet-tree-horizontal'),
                  controller: _horizontal,
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  child: SizedBox(
                    width: width,
                    height: math.max(0, bounds.maxHeight - footer),
                    child: CustomScrollView(
                      key: const PageStorageKey('sheet-tree-vertical'),
                      controller: _vertical,
                      slivers: [
                        SliverToBoxAdapter(
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: SizedBox(
                              width: bounds.maxWidth,
                              child: SectionCaption(
                                'Otevřené projekty',
                                trailing: IconButton(
                                  tooltip: 'Přidat list',
                                  onPressed: widget.onAddSheet,
                                  icon: const Icon(Icons.add, size: 18),
                                ),
                              ),
                            ),
                          ),
                        ),
                        for (final doc in docs) ...[
                          SliverToBoxAdapter(
                            key: ValueKey((
                              'sheet-project-header',
                              doc.documentSessionId,
                            )),
                            child: _projectHeader(doc),
                          ),
                          if (_isExpanded(doc))
                            SliverPadding(
                              key: ValueKey((
                                'sheet-project-tree',
                                doc.documentSessionId,
                              )),
                              padding: const EdgeInsets.only(
                                left: structureTreeIndent,
                              ),
                              sliver: StructureTree<Sheet>(
                                key: PageStorageKey(
                                  'sheet-tree/${doc.documentSessionId}',
                                ),
                                sliver: true,
                                controlsWidth: math.max(
                                  0,
                                  bounds.maxWidth - structureTreeIndent,
                                ),
                                initialFirst:
                                    widget.workspace?.sheetNavigationAspect(
                                      doc,
                                    ) ??
                                    StructureAspect.function,
                                items: _items(doc, filter).items,
                                contextFor: _sheetStructure,
                                keyFor: _sheetKey,
                                compare: compareSheetDesignations,
                                onFirstChanged:
                                    (aspect) => widget.workspace
                                        ?.setSheetNavigationAspect(doc, aspect),
                                onRename:
                                    (aspect, path) =>
                                        renameStructureBranchDialog(
                                          context,
                                          doc,
                                          aspect,
                                          path,
                                        ),
                                leaf: (sheet) => _sheet(doc, sheet),
                              ),
                            ),
                          if (_isExpanded(doc) &&
                              filter.isActive &&
                              _items(doc, filter).items.isEmpty)
                            SliverToBoxAdapter(
                              child: Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: SizedBox(
                                  width: bounds.maxWidth,
                                  child: const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Text(
                                      'Žádný list neodpovídá filtru.',
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
