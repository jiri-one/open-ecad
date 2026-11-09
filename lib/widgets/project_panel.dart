import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app/controller.dart';
import '../app/workspace_controller.dart';
import '../services/sheet_navigation.dart';
import '../services/keyboard_shortcuts.dart';
import 'inventory.dart';
import 'structure_tree.dart';
import 'sheet_context_menu.dart';
import '../app/theme.dart';
import '../app/typography.dart';
import '../editor/schematic_canvas.dart';
import 'components.dart';
import 'sheet_types.dart';
import 'frame_settings.dart';
import 'frame_settings_draft.dart';

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
  String sheetSearch = '';
  final searchController = TextEditingController();
  final sheetSearchController = TextEditingController();
  @override
  void dispose() {
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
                          0 => _buildSheets(app, c),
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

  Widget _buildSheets(EditorController app, EcadColors c) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(10),
        child: TextField(
          controller: sheetSearchController,
          decoration: const InputDecoration(
            hintText: 'Najít list nebo typ…',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (v) => setState(() => sheetSearch = v),
        ),
      ),
      Expanded(
        child: ListView(
          children: [
            SectionCaption(
              'Otevřené projekty',
              trailing: IconButton(
                tooltip: 'Přidat list',
                onPressed: widget.onAddSheet,
                icon: const Icon(Icons.add, size: 18),
              ),
            ),
            for (final doc in widget.workspace?.documents ?? [app])
              ExpansionTile(
                key: PageStorageKey(doc.documentSessionId),
                initiallyExpanded: true,
                title: Text(
                  '${doc.project.name}${doc.dirty ? ' ●' : ''}',
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Tooltip(
                  message:
                      doc.currentFile?.path ?? doc.fileName ?? 'Bez souboru',
                  child: Text(
                    doc.fileName ?? 'Bez souboru',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                leading: Builder(
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
                      child: const Icon(Icons.folder_open, size: 18),
                    );
                  },
                ),
                children: [
                  StructureTree<Sheet>(
                    initialFirst:
                        widget.workspace?.sheetNavigationAspect(doc) ??
                        StructureAspect.function,
                    items:
                        doc.project.pages
                            .where(
                              (s) =>
                                  sheetMatchesSearch(s, sheetSearch) ||
                                  foldForSearch(
                                    fullPageDesignation(s),
                                  ).contains(foldForSearch(sheetSearch)),
                            )
                            .toList(),
                    contextFor: (s) => s.structure,
                    compare: compareSheetDesignations,
                    onFirstChanged:
                        (aspect) => widget.workspace?.setSheetNavigationAspect(
                          doc,
                          aspect,
                        ),
                    onRename:
                        (aspect, path) => renameStructureBranchDialog(
                          context,
                          doc,
                          aspect,
                          path,
                        ),
                    leaf:
                        (sheet) => SheetContextMenu(
                          controller: doc,
                          sheet: sheet,
                          workspace: widget.workspace,
                          onRenameSheet: widget.onRenameSheet,
                          child: ListTile(
                            dense: true,
                            selected:
                                doc == app && sheet.id == app.activeSheetId,
                            leading: Icon(sheetTypeIcon(sheet.type), size: 16),
                            title: Text(
                              '${fullPageDesignation(sheet)} · ${sheet.name}',
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(
                              sheet.type.label,
                              style: const TextStyle(fontSize: 12),
                            ),
                            onTap:
                                () =>
                                    widget.workspace == null
                                        ? app.setSheet(sheet.id)
                                        : widget.workspace!.openSheet(
                                          doc,
                                          sheet.id,
                                          newTab:
                                              HardwareKeyboard
                                                  .instance
                                                  .isControlPressed ||
                                              HardwareKeyboard
                                                  .instance
                                                  .isMetaPressed,
                                        ),
                            trailing: SheetContextMenu(
                              controller: doc,
                              sheet: sheet,
                              workspace: widget.workspace,
                              onRenameSheet: widget.onRenameSheet,
                              tooltip:
                                  doc == app && sheet.id == app.activeSheetId
                                      ? 'Vlastnosti listu'
                                      : null,
                            ),
                          ),
                        ),
                  ),
                ],
              ),
          ],
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
