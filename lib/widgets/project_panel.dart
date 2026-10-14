import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import '../app/controller.dart';
import '../app/theme.dart';
import '../editor/schematic_canvas.dart';
import 'components.dart';

class ProjectPanel extends StatefulWidget {
  const ProjectPanel({
    super.key,
    required this.controller,
    required this.onRenameSheet,
  });
  final EditorController controller;
  final VoidCallback onRenameSheet;
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
    return DefaultTabController(
      length: 2,
      animationDuration: Duration.zero,
      child: Builder(
        builder: (context) {
          final tabs = DefaultTabController.of(context);
          return Container(
            color: c.panel,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 46,
                  child: TabBar(
                    labelColor: c.foreground,
                    unselectedLabelColor: c.muted,
                    labelStyle: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                    unselectedLabelStyle: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                    labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                    indicatorColor: c.foreground,
                    indicatorSize: TabBarIndicatorSize.tab,
                    dividerColor: c.border,
                    tabs: const [
                      Tab(text: 'Listy projektu'),
                      Tab(text: 'Přístroje'),
                    ],
                  ),
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: tabs,
                    builder:
                        (context, _) =>
                            tabs.index == 0
                                ? _buildSheets(app, c)
                                : _buildLibrary(app, c),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSheets(EditorController app, EcadColors c) {
    final count = app.project.pages.length;
    final visibleSheets =
        app.project.pages
            .where(
              (sheet) => '${sheet.number} ${sheet.name}'.toLowerCase().contains(
                sheetSearch.toLowerCase(),
              ),
            )
            .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCaption(
          '$count ${count == 1
              ? 'list'
              : count < 5
              ? 'listy'
              : 'listů'}',
          trailing: EcadIconButton(
            icon: Icons.add,
            label: 'Přidat list',
            onPressed: app.addSheet,
            size: 24,
            iconSize: 16,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: TextField(
            controller: sheetSearchController,
            onChanged: (value) => setState(() => sheetSearch = value),
            style: const TextStyle(fontSize: 11),
            decoration: const InputDecoration(
              hintText: 'Najít list…',
              prefixIcon: Icon(Icons.search, size: 17),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            key: const PageStorageKey('project-sheets'),
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            itemCount: visibleSheets.length,
            itemBuilder: (context, index) {
              final sheet = visibleSheets[index];
              final active = app.activeSheetId == sheet.id;
              return Semantics(
                selected: active,
                button: true,
                child: InkWell(
                  onTap: () => app.setSheet(sheet.id),
                  onDoubleTap: active ? widget.onRenameSheet : null,
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: active ? c.accent : c.panel,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.description_outlined,
                          size: 16,
                          color: active ? c.onAccent : c.foreground,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          sheet.number,
                          style: TextStyle(
                            fontSize: 10,
                            color: active ? c.onAccent : c.muted,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            sheet.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight:
                                  active ? FontWeight.w600 : FontWeight.w400,
                              color: active ? c.onAccent : c.foreground,
                            ),
                          ),
                        ),
                      ],
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
            style: const TextStyle(fontSize: 11),
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
                    itemCount: kinds.length,
                    itemBuilder: (context, index) {
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
                              height: 51,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          definition.label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          '${definition.prefix} · ${definition.ports.length} ${definition.ports.length == 1 ? 'připojovací bod' : 'připojovací body'}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 9,
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
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.border)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.keyboard_outlined, size: 16),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Klikněte na symbol a umístěte ho do výkresu. Esc ukončí vkládání.',
                  style: TextStyle(fontSize: 10, color: c.muted, height: 1.6),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
