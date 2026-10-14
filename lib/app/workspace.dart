import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../editor/schematic_canvas.dart';
import '../widgets/assistant_panel.dart';
import '../widgets/components.dart';
import '../widgets/project_panel.dart';
import '../widgets/properties_panel.dart';
import '../widgets/sheet_types.dart';
import 'controller.dart';
import 'dialogs.dart';
import 'theme.dart';

class OpenEcadApp extends StatelessWidget {
  const OpenEcadApp({super.key, required this.controller});
  final EditorController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder:
        (context, _) => MaterialApp(
          title: 'Open ECAD',
          debugShowCheckedModeBanner: false,
          theme: buildEcadTheme(controller.appearance),
          themeAnimationDuration: Duration.zero,
          scrollBehavior: const _EditorScrollBehavior(),
          home: EditorWorkspace(controller: controller),
        ),
  );
}

class _EditorScrollBehavior extends MaterialScrollBehavior {
  const _EditorScrollBehavior();
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

class EditorWorkspace extends StatefulWidget {
  const EditorWorkspace({super.key, required this.controller});
  final EditorController controller;
  @override
  State<EditorWorkspace> createState() => _EditorWorkspaceState();
}

class _EditorWorkspaceState extends State<EditorWorkspace> {
  final promptFocus = FocusNode(debugLabel: 'Assistant input');
  bool showProject = true, showAssistant = true;
  EditorController get app => widget.controller;
  @override
  void dispose() {
    promptFocus.dispose();
    super.dispose();
  }

  void focusAssistant() {
    setState(() => showAssistant = true);
    app.setPanel(SidePanel.assistant);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) promptFocus.requestFocus();
    });
  }

  Future<void> openProject() async {
    if (await confirmReplaceProject(context, app)) await app.openProject();
  }

  Future<void> importPdf() async {
    if (await confirmReplaceProject(context, app)) {
      await app.openProject(importPdf: true);
    }
  }

  Future<void> newProject({bool demo = false}) async {
    if (await confirmReplaceProject(context, app)) app.newProject(demo: demo);
  }

  Future<void> renameProject() async {
    final name = await editNameDialog(
      context,
      title: 'Název projektu',
      value: app.project.name,
    );
    if (name != null && mounted) app.renameProject(name);
  }

  Future<void> renameSheet() async {
    final name = await editNameDialog(
      context,
      title: 'Název listu',
      value: app.sheet.name,
    );
    if (name != null && mounted) app.renameSheet(name);
  }

  Future<void> addSheet([SheetType? type]) async {
    final request = await showNewSheetDialog(
      context,
      initialType: type ?? app.sheet.type,
    );
    if (request != null && mounted) {
      app.addSheet(
        type: request.type,
        name: request.name,
        formStarter: request.formStarter,
      );
    }
  }

  void validate() {
    app.validate();
  }

  void commandPalette() => showCommandPalette(
    context,
    app,
    openProject: openProject,
    focusAssistant: focusAssistant,
    addSheet: addSheet,
  );
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final ctrl = keyboard.isControlPressed || keyboard.isMetaPressed;
    final key = event.logicalKey;
    if (ctrl) {
      if (key == LogicalKeyboardKey.keyS) {
        app.saveProject();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyO) {
        openProject();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyK) {
        commandPalette();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyL) {
        focusAssistant();
        return KeyEventResult.handled;
      }
    }
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    if (ctrl) {
      if (key == LogicalKeyboardKey.keyZ) {
        keyboard.isShiftPressed ? app.redo() : app.undo();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyY) {
        app.redo();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyD) {
        app.duplicateSelection();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyA) {
        app.selectAll();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.escape) {
      app.cancelTool();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyV) {
      app.setMode(CanvasMode.select);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyL) {
      app.setMode(CanvasMode.drawLine);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyB) {
      app.setMode(CanvasMode.drawRectangle);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyT) {
      app.setMode(CanvasMode.drawText);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyW) {
      app.setMode(CanvasMode.wire);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyH) {
      app.setMode(CanvasMode.pan);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      app.viewport.fit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyR) {
      app.rotateSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      app.deleteSelection();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = EcadColors.of(context);
    return Focus(
      onKeyEvent: _onKey,
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, bounds) {
              final compact = bounds.maxWidth < 1120;
              final projectVisible = showProject && bounds.maxWidth >= 950;
              final assistantVisible = showAssistant && bounds.maxWidth >= 680;
              return Column(
                children: [
                  _header(c, compact),
                  _toolbar(c, compact),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (projectVisible) ...[
                          SizedBox(
                            width: compact ? 202 : 230,
                            child: ProjectPanel(
                              controller: app,
                              onRenameSheet: renameSheet,
                              onAddSheet: addSheet,
                            ),
                          ),
                          VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: c.border,
                          ),
                        ],
                        Expanded(
                          child: Column(
                            children: [
                              _sheetTabs(c),
                              if (app.sheet.sourcePage != null)
                                Container(
                                  width: double.infinity,
                                  color: c.panel,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 6,
                                  ),
                                  child: Text(
                                    'Grafika z PDF · ${app.sheet.graphics.length} objektů · elektrické vazby nejsou obnovené',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: c.muted,
                                    ),
                                  ),
                                ),
                              Expanded(
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: SchematicCanvas(
                                        sheet: app.displaySheet,
                                        readOnly: app.showingProposal,
                                        selectedIds: app.selectedIds,
                                        mode: app.mode,
                                        placingKind: app.placingKind,
                                        showGrid: app.showGrid,
                                        palette: c.canvasPalette,
                                        controller: app.viewport,
                                        onSelectionChanged: (ids) {
                                          if (!app.showingProposal) {
                                            app.select(ids);
                                          }
                                        },
                                        onMoveDevices: app.moveDevices,
                                        onMoveSelection: app.moveSelection,
                                        onCreateGraphic: app.createGraphic,
                                        onPlaceDevice: app.placeDevice,
                                        onConnect: app.connect,
                                        onDeleteWire: app.deleteWire,
                                      ),
                                    ),
                                    Positioned(
                                      left: 16,
                                      top: 16,
                                      child: IgnorePointer(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: c.panel,
                                            border: Border.all(color: c.border),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                sheetTypeIcon(app.sheet.type),
                                                size: 12,
                                              ),
                                              const SizedBox(width: 7),
                                              Text(
                                                '${app.sheet.number} / ${app.project.pages.length.toString().padLeft(2, '0')} · ${app.sheet.type.label}',
                                                style: const TextStyle(
                                                  fontSize: 10,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (app.showingProposal)
                                      Positioned(
                                        right: 16,
                                        top: 16,
                                        child: Container(
                                          padding: const EdgeInsets.fromLTRB(
                                            10,
                                            3,
                                            3,
                                            3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: c.accent,
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.visibility_outlined,
                                                color: c.onAccent,
                                                size: 14,
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                'NÁHLED NÁVRHU',
                                                style: TextStyle(
                                                  fontSize: 9,
                                                  letterSpacing: 0.6,
                                                  color: c.onAccent,
                                                ),
                                              ),
                                              const SizedBox(width: 5),
                                              IconButton(
                                                onPressed:
                                                    app.toggleProposalPreview,
                                                tooltip:
                                                    'Zobrazit původní schéma',
                                                icon: Icon(
                                                  Icons.close,
                                                  color: c.onAccent,
                                                  size: 15,
                                                ),
                                                constraints:
                                                    const BoxConstraints.tightFor(
                                                      width: 28,
                                                      height: 26,
                                                    ),
                                                padding: EdgeInsets.zero,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    Positioned(
                                      right: 16,
                                      bottom: 16,
                                      child: _zoomControls(c),
                                    ),
                                    if (app.mode == CanvasMode.place ||
                                        app.mode == CanvasMode.wire)
                                      Positioned(
                                        left: 16,
                                        bottom: 16,
                                        child: Container(
                                          constraints: const BoxConstraints(
                                            maxWidth: 250,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: c.accent,
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Text(
                                            app.mode == CanvasMode.wire
                                                ? 'Klikněte na první a druhý připojovací bod'
                                                : 'Klikněte do výkresu · Esc ukončí vkládání',
                                            style: TextStyle(
                                              color: c.onAccent,
                                              fontSize: 10,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (app.diagnosticsVisible) _diagnosticsPanel(c),
                            ],
                          ),
                        ),
                        if (assistantVisible) ...[
                          VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: c.border,
                          ),
                          SizedBox(
                            width: compact ? 300 : 330,
                            child: Material(
                              color: c.panel,
                              child: Column(
                                children: [
                                  Container(
                                    decoration: BoxDecoration(
                                      border: Border(
                                        bottom: BorderSide(color: c.border),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        PanelTab(
                                          label: 'Asistent',
                                          icon: Icons.auto_awesome_outlined,
                                          selected:
                                              app.sidePanel ==
                                              SidePanel.assistant,
                                          onTap:
                                              () => app.setPanel(
                                                SidePanel.assistant,
                                              ),
                                        ),
                                        PanelTab(
                                          label: 'Vlastnosti',
                                          icon: Icons.tune,
                                          selected:
                                              app.sidePanel ==
                                              SidePanel.properties,
                                          count: app.selectedIds.length,
                                          onTap:
                                              () => app.setPanel(
                                                SidePanel.properties,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    child: IndexedStack(
                                      index: app.sidePanel.index,
                                      children: [
                                        AssistantPanel(
                                          controller: app,
                                          onSettings:
                                              () =>
                                                  showAiSettings(context, app),
                                          inputFocus: promptFocus,
                                        ),
                                        PropertiesPanel(controller: app),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  _statusBar(c, compact),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _header(EcadColors c, bool compact) => Container(
    height: 60,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: c.panel,
      border: Border(bottom: BorderSide(color: c.border)),
    ),
    child: Row(
      children: [
        const BrandMark(),
        const SizedBox(width: 10),
        const Text(
          'open',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w400,
            letterSpacing: -0.6,
          ),
        ),
        const Text(
          'ecad',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(width: 14),
        if (!compact)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: c.border),
              borderRadius: BorderRadius.circular(3),
            ),
            child: const Text(
              '0.1',
              style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600),
            ),
          ),
        const SizedBox(width: 20),
        SizedBox(height: 22, child: VerticalDivider(width: 1, color: c.border)),
        const SizedBox(width: 18),
        Expanded(
          child: InkWell(
            onTap: renameProject,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  app.project.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  app.dirty
                      ? 'Neuložené změny · místní pracovní kopie'
                      : 'Projekt · otevřený formát .oecad',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9, color: c.muted),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              for (final appearance in EcadAppearance.values)
                EcadIconButton(
                  icon: switch (appearance) {
                    EcadAppearance.paper => Icons.light_mode_outlined,
                    EcadAppearance.ink => Icons.dark_mode_outlined,
                    EcadAppearance.studio => Icons.palette_outlined,
                  },
                  label: appearance.label,
                  selected: app.appearance == appearance,
                  onPressed: () => app.setAppearance(appearance),
                  size: 28,
                  iconSize: 16,
                ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        if (!compact) ...[
          OutlinedButton.icon(
            onPressed: commandPalette,
            icon: const Icon(Icons.search, size: 15),
            label: const Row(
              children: [
                Text('Příkazy'),
                SizedBox(width: 14),
                Keycap('Ctrl K'),
              ],
            ),
          ),
          const SizedBox(width: 12),
        ],
        FilledButton.icon(
          onPressed: app.ioBusy ? null : app.saveProject,
          icon: const Icon(Icons.save_outlined, size: 16),
          label: const Text('Uložit'),
        ),
      ],
    ),
  );

  Widget _toolbar(EcadColors c, bool compact) => Container(
    height: 46,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: c.panel,
      border: Border(bottom: BorderSide(color: c.border)),
    ),
    child: Row(
      children: [
        PopupMenuButton<String>(
          tooltip: 'Soubor',
          offset: const Offset(0, 36),
          onSelected: (value) {
            switch (value) {
              case 'new':
                newProject();
              case 'demo':
                newProject(demo: true);
              case 'open':
                openProject();
              case 'importPdf':
                importPdf();
              case 'save':
                app.saveProject();
              case 'pdf':
                app.exportProject(pdf: true);
              case 'svg':
                app.exportProject(pdf: false);
            }
          },
          itemBuilder:
              (_) => const [
                PopupMenuItem(value: 'new', child: Text('Nový projekt')),
                PopupMenuItem(value: 'open', child: Text('Otevřít projekt…')),
                PopupMenuItem(
                  value: 'importPdf',
                  child: Text('Importovat PDF jako grafiku…'),
                ),
                PopupMenuItem(value: 'save', child: Text('Uložit projekt…')),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 'pdf',
                  child: Text('Exportovat všechny listy do PDF…'),
                ),
                PopupMenuItem(
                  value: 'svg',
                  child: Text('Exportovat aktuální list do SVG…'),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 'demo',
                  child: Text('Otevřít ukázkový projekt'),
                ),
              ],
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Icon(Icons.folder_open_outlined, size: 17),
                SizedBox(width: 7),
                Text('Soubor', style: TextStyle(fontSize: 11)),
                SizedBox(width: 5),
                Icon(Icons.keyboard_arrow_down, size: 14),
              ],
            ),
          ),
        ),
        _toolbarDivider(c),
        EcadIconButton(
          icon: Icons.undo,
          label: 'Vrátit · Ctrl Z',
          onPressed: app.canUndo ? app.undo : null,
        ),
        EcadIconButton(
          icon: Icons.redo,
          label: 'Obnovit · Ctrl Y',
          onPressed: app.canRedo ? app.redo : null,
        ),
        _toolbarDivider(c),
        _tool(Icons.near_me_outlined, 'Výběr', 'V', CanvasMode.select, compact),
        _tool(Icons.polyline_outlined, 'Vodič', 'W', CanvasMode.wire, compact),
        _tool(Icons.pan_tool_outlined, 'Posun', 'H', CanvasMode.pan, compact),
        PopupMenuButton<CanvasMode>(
          tooltip: 'Kreslit grafiku',
          icon: const Icon(Icons.draw_outlined, size: 18),
          onSelected: app.setMode,
          itemBuilder:
              (_) => const [
                PopupMenuItem(
                  value: CanvasMode.drawLine,
                  child: Text('Čára · L'),
                ),
                PopupMenuItem(
                  value: CanvasMode.drawRectangle,
                  child: Text('Obdélník · B'),
                ),
                PopupMenuItem(
                  value: CanvasMode.drawText,
                  child: Text('Text · T'),
                ),
              ],
        ),
        _toolbarDivider(c),
        EcadIconButton(
          icon: Icons.rotate_right,
          label: 'Otočit výběr · R',
          onPressed: app.selectedIds.isEmpty ? null : app.rotateSelection,
        ),
        EcadIconButton(
          icon: Icons.copy_outlined,
          label: 'Duplikovat výběr · Ctrl D',
          onPressed: app.selectedIds.isEmpty ? null : app.duplicateSelection,
        ),
        EcadIconButton(
          icon: Icons.delete_outline,
          label: 'Odstranit výběr · Delete',
          onPressed: app.selectedIds.isEmpty ? null : app.deleteSelection,
        ),
        _toolbarDivider(c),
        EcadIconButton(
          icon: Icons.grid_4x4_outlined,
          label: 'Zobrazit mřížku',
          selected: app.showGrid,
          onPressed: app.toggleGrid,
        ),
        const SizedBox(width: 5),
        if (!compact)
          OutlinedButton.icon(
            onPressed: validate,
            icon: const Icon(Icons.fact_check_outlined, size: 15),
            label: const Text('Kontrola'),
          )
        else
          EcadIconButton(
            icon: Icons.fact_check_outlined,
            label: 'Zkontrolovat projekt',
            onPressed: validate,
          ),
        const Spacer(),
        EcadIconButton(
          icon: Icons.vertical_split_outlined,
          label: 'Zobrazit projekt a knihovnu',
          selected: showProject,
          onPressed: () => setState(() => showProject = !showProject),
        ),
        EcadIconButton(
          icon: Icons.auto_awesome_outlined,
          label: 'Zobrazit asistenta',
          selected: showAssistant,
          onPressed: () => setState(() => showAssistant = !showAssistant),
        ),
        const SizedBox(width: 4),
        EcadIconButton(
          icon: Icons.help_outline,
          label: 'Ovládání a klávesové zkratky',
          onPressed: () => showHelpDialog(context),
        ),
      ],
    ),
  );
  Widget _toolbarDivider(EcadColors c) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: SizedBox(
      height: 20,
      child: VerticalDivider(width: 1, color: c.border),
    ),
  );
  Widget _tool(
    IconData icon,
    String name,
    String key,
    CanvasMode mode,
    bool compact,
  ) {
    final selected = app.mode == mode;
    final c = EcadColors.of(context);
    if (compact) {
      return EcadIconButton(
        icon: icon,
        label: '$name · $key',
        selected: selected,
        onPressed: () => app.setMode(mode),
      );
    }
    return Tooltip(
      message: '$name · $key',
      child: Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          onTap: () => app.setMode(mode),
          borderRadius: BorderRadius.circular(4),
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(
              color: selected ? c.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: selected ? c.onAccent : c.foreground,
                ),
                const SizedBox(width: 7),
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 11,
                    color: selected ? c.onAccent : c.foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sheetTabs(EcadColors c) => Container(
    height: 46,
    decoration: BoxDecoration(
      color: c.panel,
      border: Border(bottom: BorderSide(color: c.border)),
    ),
    child: Row(
      children: [
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final sheet in app.project.pages)
                Semantics(
                  button: true,
                  selected: sheet.id == app.activeSheetId,
                  child: InkWell(
                    onTap: () => app.setSheet(sheet.id),
                    onDoubleTap: () {
                      app.setSheet(sheet.id);
                      renameSheet();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      constraints: const BoxConstraints(minWidth: 140),
                      decoration: BoxDecoration(
                        border: Border(
                          right: BorderSide(color: c.border),
                          bottom: BorderSide(
                            color:
                                sheet.id == app.activeSheetId
                                    ? c.foreground
                                    : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Tooltip(
                            message: sheet.type.label,
                            child: Icon(sheetTypeIcon(sheet.type), size: 13),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            sheet.number,
                            style: TextStyle(fontSize: 10, color: c.muted),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            sheet.name,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight:
                                  sheet.id == app.activeSheetId
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: EcadIconButton(
            icon: Icons.add,
            label: 'Nový list',
            onPressed: addSheet,
            size: 28,
            iconSize: 17,
          ),
        ),
      ],
    ),
  );
  Widget _zoomControls(EcadColors c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
    decoration: BoxDecoration(
      color: c.panel,
      border: Border.all(color: c.border),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        EcadIconButton(
          icon: Icons.remove,
          label: 'Oddálit',
          onPressed: app.viewport.zoomOut,
          size: 27,
          iconSize: 17,
        ),
        ListenableBuilder(
          listenable: app.viewport,
          builder:
              (_, _) => SizedBox(
                width: 48,
                child: Text(
                  '${(app.viewport.zoom * 100).round()} %',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 10),
                ),
              ),
        ),
        EcadIconButton(
          icon: Icons.add,
          label: 'Přiblížit',
          onPressed: app.viewport.zoomIn,
          size: 27,
          iconSize: 17,
        ),
        Container(
          width: 1,
          height: 17,
          color: c.border,
          margin: const EdgeInsets.symmetric(horizontal: 4),
        ),
        EcadIconButton(
          icon: Icons.fit_screen,
          label: 'Celý list · F',
          onPressed: app.viewport.fit,
          size: 27,
          iconSize: 17,
        ),
      ],
    ),
  );
  Widget _statusBar(EcadColors c, bool compact) => Container(
    height: 30,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: BoxDecoration(
      color: c.panel,
      border: Border(top: BorderSide(color: c.border)),
    ),
    child: Row(
      children: [
        Icon(app.ioBusy ? Icons.hourglass_top : Icons.check, size: 12),
        const SizedBox(width: 7),
        Expanded(
          child: Tooltip(
            message: app.status,
            child: Text(
              app.status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          app.sheet.graphics.isEmpty
              ? '${app.sheet.devices.length} přístrojů · ${app.sheet.wires.length} vodičů'
              : '${app.sheet.graphics.length} grafických objektů · ${app.selectedIds.length} vybráno',
          style: const TextStyle(fontSize: 9),
        ),
        if (!compact) ...[
          const SizedBox(width: 18),
          SizedBox(
            height: 12,
            child: VerticalDivider(width: 1, color: c.border),
          ),
          const SizedBox(width: 14),
          const Icon(Icons.save_outlined, size: 12),
          const SizedBox(width: 6),
          Text(
            app.autosaveStatus,
            style: TextStyle(fontSize: 9, color: c.muted),
          ),
        ],
        const SizedBox(width: 16),
        Text(
          app.appearance == EcadAppearance.studio ? 'STUDIO' : 'E-INK',
          style: const TextStyle(
            fontSize: 9,
            letterSpacing: 1,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
  Widget _diagnosticsPanel(EcadColors c) => SizedBox(
    height: 166,
    child: Material(
      color: c.panel,
      shape: Border(top: BorderSide(color: c.border)),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 5, 8, 5),
            child: Row(
              children: [
                const Icon(Icons.fact_check_outlined, size: 15),
                const SizedBox(width: 8),
                Text(
                  'Kontrola projektu · ${app.diagnostics.length}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                EcadIconButton(
                  icon: Icons.close,
                  label: 'Zavřít kontrolu',
                  onPressed: app.hideDiagnostics,
                  size: 25,
                  iconSize: 16,
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child:
                app.diagnostics.isEmpty
                    ? const Center(
                      child: Text(
                        'Struktura projektu je v pořádku. Kontrola neposuzuje návrh elektrické instalace.',
                        style: TextStyle(fontSize: 11),
                      ),
                    )
                    : ListView.builder(
                      itemCount: app.diagnostics.length,
                      itemBuilder: (context, index) {
                        final issue = app.diagnostics[index];
                        return ListTile(
                          dense: true,
                          minLeadingWidth: 18,
                          leading: Icon(
                            issue.severity == DiagnosticSeverity.error
                                ? Icons.error_outline
                                : Icons.info_outline,
                            size: 15,
                          ),
                          title: Text(
                            issue.message,
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () {
                            if (issue.sheetId != null) {
                              app.setSheet(issue.sheetId!);
                            }
                            if (issue.deviceId != null) {
                              app.select({issue.deviceId!});
                            }
                            app.setPanel(SidePanel.properties);
                          },
                        );
                      },
                    ),
          ),
        ],
      ),
    ),
  );
}
