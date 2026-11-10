import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import '../app/controller.dart';
import '../app/workspace_controller.dart';
import '../services/keyboard_shortcuts.dart';
import 'inventory.dart';
import 'sheet_navigator.dart';
import 'sheet_filter.dart';
import 'sheet_filter_dialog.dart';
import '../app/theme.dart';
import '../app/typography.dart';
import '../editor/schematic_canvas.dart';

class ProjectPanel extends StatefulWidget {
  const ProjectPanel({
    super.key,
    required this.controller,
    required this.onRenameSheet,
    required this.onAddSheet,
    this.workspace,
    this.onCloseProject,
    this.shortcuts = const KeyboardShortcuts.defaults(),
  });
  final EditorController controller;
  final KeyboardShortcuts shortcuts;
  final WorkspaceController? workspace;
  final ValueChanged<EditorController>? onCloseProject;
  final VoidCallback onRenameSheet;
  final VoidCallback onAddSheet;
  @override
  State<ProjectPanel> createState() => _ProjectPanelState();
}

class _ProjectPanelState extends State<ProjectPanel> {
  String search = '';
  final searchController = TextEditingController();
  final sheetSearchController = TextEditingController();
  ValueNotifier<SheetFilter>? _filterState;
  bool _changingQuery = false;

  Object get _filterOwner => widget.workspace ?? widget.controller;
  SheetFilter get sheetFilter => _filterState?.value ?? SheetFilter.empty;

  void _bindSheetFilter() {
    _filterState?.removeListener(_filterChanged);
    final bucket = PageStorage.maybeOf(context);
    final key = ('sheet-filter', _filterOwner);
    final saved = bucket?.readState(context, identifier: key);
    final state =
        saved is ValueNotifier<SheetFilter>
            ? saved
            : ValueNotifier(SheetFilter.empty);
    bucket?.writeState(context, state, identifier: key);
    _filterState = state;
    sheetSearchController.text = state.value.query;
    state.addListener(_filterChanged);
  }

  void _filterChanged() {
    if (!mounted) return;
    final query = sheetFilter.query;
    if (!_changingQuery && sheetSearchController.text != query) {
      sheetSearchController.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_filterState == null) _bindSheetFilter();
  }

  @override
  void didUpdateWidget(covariant ProjectPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspace ?? oldWidget.controller, _filterOwner)) {
      _bindSheetFilter();
    }
  }

  void _setSheetFilter(SheetFilter filter, {bool fromQuery = false}) {
    _changingQuery = fromQuery;
    try {
      _filterState!.value = filter;
    } finally {
      _changingQuery = false;
    }
  }

  @override
  void dispose() {
    _filterState?.removeListener(_filterChanged);
    searchController.dispose();
    sheetSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = EcadColors.of(context);
    final app = widget.controller;
    final tabHeight = interfaceRowHeight(context, minimum: 46);
    return DefaultTabController(
      length: 4,
      animationDuration: Duration.zero,
      child: Builder(
        builder: (context) {
          final tabs = DefaultTabController.of(context);
          return Material(
            color: c.panel,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: tabHeight,
                  child: TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelColor: c.foreground,
                    unselectedLabelColor: c.muted,
                    labelStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    unselectedLabelStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                    ),
                    labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                    indicatorColor: c.foreground,
                    indicatorSize: TabBarIndicatorSize.tab,
                    dividerColor: c.border,
                    tabs: [
                      for (final label in const [
                        'Listy',
                        'Značky',
                        'Přístroje',
                        'Artikly',
                      ])
                        Tab(text: label, height: tabHeight - 2),
                    ],
                  ),
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: tabs,
                    builder:
                        (context, _) => switch (tabs.index) {
                          0 => _buildSheets(app),
                          1 => _buildLibrary(app, c),
                          2 => InventoryPanel(app: app),
                          _ => InventoryPanel(app: app, articles: true),
                        },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _editSheetFilter() async {
    final state = _filterState!;
    final workspace = widget.workspace;
    final controller = widget.controller;
    final result = await showSheetFilterDialog(
      context,
      initial: state.value,
      changes: workspace ?? controller,
      sheets:
          () => (workspace?.documents ?? [controller]).expand(
            (doc) => doc.project.pages,
          ),
    );
    if (result != null) state.value = result;
  }

  void _clearSheetFilter() {
    sheetSearchController.clear();
    _setSheetFilter(SheetFilter.empty);
  }

  Widget _buildSheets(EditorController app) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(10),
        child: TextField(
          controller: sheetSearchController,
          decoration: InputDecoration(
            hintText: 'Najít list nebo typ…',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (sheetFilter.isActive)
                  IconButton(
                    tooltip: 'Zrušit filtr listů',
                    onPressed: _clearSheetFilter,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                IconButton(
                  key: const ValueKey('sheet-filter-button'),
                  tooltip:
                      sheetFilter.isActive
                          ? 'Upravit filtr listů…'
                          : 'Filtrovat listy…',
                  onPressed: _editSheetFilter,
                  isSelected: sheetFilter.isActive,
                  selectedIcon: const Icon(Icons.filter_alt, size: 20),
                  icon: const Icon(Icons.filter_alt_outlined, size: 20),
                ),
              ],
            ),
          ),
          onChanged:
              (v) => _setSheetFilter(sheetFilter.withQuery(v), fromQuery: true),
        ),
      ),
      Expanded(
        child: SheetNavigator(
          controller: app,
          workspace: widget.workspace,
          filter: sheetFilter,
          onAddSheet: widget.onAddSheet,
          onRenameSheet: widget.onRenameSheet,
          onCloseProject: widget.onCloseProject,
        ),
      ),
    ],
  );

  Widget _buildLibrary(EditorController app, EcadColors c) {
    final kinds =
        DeviceKind.values
            .where(
              (kind) => SymbolCatalog.definitionFor(
                kind,
              ).label.toLowerCase().contains(search.toLowerCase()),
            )
            .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
          child: TextField(
            controller: searchController,
            onChanged: (value) => setState(() => search = value),
            cursorOpacityAnimates: false,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'Najít symbol…',
              prefixIcon: Icon(Icons.search, size: 17),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
          ),
        ),
        Expanded(
          child:
              kinds.isEmpty
                  ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Žádný odpovídající symbol.'),
                  )
                  : ListView.builder(
                    key: const PageStorageKey('device-library'),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: kinds.length + 1,
                    itemBuilder: (context, index) {
                      if (index == kinds.length) return _libraryHelp(c);
                      final kind = kinds[index];
                      final definition = SymbolCatalog.definitionFor(kind);
                      final active =
                          app.mode == CanvasMode.place &&
                          app.placingKind == kind;
                      return Tooltip(
                        message: 'Vložit: ${definition.label}',
                        child: Semantics(
                          button: true,
                          selected: active,
                          child: InkWell(
                            onTap:
                                () => app.setMode(CanvasMode.place, kind: kind),
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              constraints: const BoxConstraints(minHeight: 51),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              margin: const EdgeInsets.only(bottom: 3),
                              decoration: BoxDecoration(
                                color: active ? c.subtle : Colors.transparent,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color:
                                      active
                                          ? c.foreground
                                          : Colors.transparent,
                                ),
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 34,
                                    child: SymbolPreview(
                                      kind: kind,
                                      palette: c.canvasPalette,
                                      size: 30,
                                    ),
                                  ),
                                  const SizedBox(width: 11),
                                  Expanded(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          definition.label,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          '${definition.prefix} · ${definition.ports.length} ${switch (definition.ports.length) {
                                            1 => 'připojovací bod',
                                            < 5 => 'připojovací body',
                                            _ => 'připojovacích bodů',
                                          }}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: c.muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.add, size: 14),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
        ),
      ],
    );
  }

  Widget _libraryHelp(EcadColors c) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.keyboard_outlined, size: 16),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            'Značka vytvoří nový fyzický kus. Další zobrazení existujícího kusu přidejte přes Přístroje. PE je pokračování bez kusu. ${widget.shortcuts.labelFor(EditorCommand.cancelTool)} ukončí vkládání.',
            style: TextStyle(fontSize: 12, color: c.muted, height: 1.35),
          ),
        ),
      ],
    ),
  );
}
