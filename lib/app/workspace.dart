import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../editor/schematic_canvas.dart';
import '../editor/drawing_cursor.dart';
import '../services/drawing_cursor_settings.dart';
import '../services/keyboard_shortcuts.dart';
import '../services/pointer_warp.dart';
import '../services/desktop_window.dart';
import '../widgets/drawing_cursor_dialog.dart';
import '../widgets/keyboard_shortcuts_dialog.dart';
import '../widgets/sheet_context_menu.dart';
import '../widgets/sheet_settings.dart';
import '../editor/mounting_canvas.dart';
import '../widgets/report_view.dart';
import '../widgets/recovery_dialog.dart';
import '../widgets/pdf_frame_import_dialog.dart';
import '../widgets/inventory.dart';
import '../widgets/diagnostic_text.dart';
import '../widgets/terminal_symbol_dialog.dart';
import '../widgets/continuation_editor.dart';
import '../widgets/continuation_picker.dart';
import '../widgets/edit_history.dart';
import '../widgets/occurrence_dialog.dart'
    show electricalSheet, showMountPlacementDialog;
import 'continuation_context.dart';
import 'workspace_controller.dart';
import '../widgets/assistant_panel.dart';
import '../widgets/components.dart';
import '../widgets/project_panel.dart';
import '../widgets/properties_panel.dart';
import 'controller.dart';
import 'dialogs.dart';
import 'theme.dart';

class OpenEcadApp extends StatefulWidget {
  const OpenEcadApp({super.key, required this.controller});
  final EditorController controller;
  @override
  State<OpenEcadApp> createState() => _OpenEcadAppState();
}

class _OpenEcadAppState extends State<OpenEcadApp> {
  late final workspace = WorkspaceController(widget.controller);
  @override
  void dispose() {
    workspace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: workspace,
    builder:
        (context, _) => MaterialApp(
          title: 'Open ECAD',
          debugShowCheckedModeBanner: false,
          theme: buildEcadTheme(workspace.active.appearance),
          themeAnimationDuration: Duration.zero,
          scrollBehavior: const _EditorScrollBehavior(),
          builder: (_, child) => DesktopWindowFrame(child: child!),
          home: EditorWorkspace(
            controller: workspace.active,
            workspace: workspace,
          ),
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
  const EditorWorkspace({super.key, required this.controller, this.workspace});
  final EditorController controller;
  final WorkspaceController? workspace;
  @override
  State<EditorWorkspace> createState() => _EditorWorkspaceState();
}

enum _ToolGroup {
  electrical('Elektro', Icons.electrical_services),
  drawing('Kreslení', Icons.draw_outlined),
  editing('Úpravy', Icons.edit_outlined);

  const _ToolGroup(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _EditorWorkspaceState extends State<EditorWorkspace> {
  _ToolGroup toolGroup = _ToolGroup.electrical;
  CanvasMode? _lastMode;
  final _activeTabKey = GlobalKey();
  SheetTab? _lastVisibleTab;
  final drawingCursor = DrawingCursorPreferences();
  final keyboardShortcuts = KeyboardShortcutPreferences();
  @override
  void initState() {
    super.initState();
    drawingCursor.addListener(_preferencesChanged);
    drawingCursor.load().catchError((Object _) {});
    keyboardShortcuts.addListener(_preferencesChanged);
    keyboardShortcuts.load().catchError((Object _) {});
  }

  void _preferencesChanged() {
    if (mounted) setState(() {});
  }

  final promptFocus = FocusNode(debugLabel: 'Assistant input');
  bool showProject = true, showAssistant = true;
  late final localWorkspace =
      widget.workspace == null ? WorkspaceController(widget.controller) : null;
  WorkspaceController get workspace => widget.workspace ?? localWorkspace!;
  EditorController get app => workspace.active;
  @override
  void dispose() {
    drawingCursor.removeListener(_preferencesChanged);
    drawingCursor.dispose();
    keyboardShortcuts.removeListener(_preferencesChanged);
    keyboardShortcuts.dispose();
    localWorkspace?.dispose();
    promptFocus.dispose();
    super.dispose();
  }

  SheetTab? _lastTabTap;
  DateTime? _lastTabTapAt;
  void activateTab(SheetTab tab) {
    final now = DateTime.now();
    final twice =
        _lastTabTap == tab &&
        _lastTabTapAt != null &&
        now.difference(_lastTabTapAt!).inMilliseconds < 350;
    _lastTabTap = tab;
    _lastTabTapAt = now;
    workspace.activate(tab);
    if (twice) {
      _lastTabTap = null;
      renameSheet();
    }
  }

  void focusAssistant() {
    _continuationNavigationRequest++;
    setState(() => showAssistant = true);
    app.setPanel(SidePanel.assistant);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) promptFocus.requestFocus();
    });
  }

  void editSelectedDevice() {
    _continuationNavigationRequest++;
    final owner = app;
    if (owner.showingProposal ||
        owner.pastePreview != null ||
        owner.mode != CanvasMode.select ||
        owner.viewport.hasActiveGesture) {
      return;
    }
    if (owner.selectedMarkers.length == 1 && owner.selectedIds.length == 1) {
      editContinuationMarker(owner.selectedMarkers.single.id);
    } else if (owner.selectedDevices.length == 1) {
      showDeviceProperties(context, owner, owner.selectedDevices.single.id);
    } else if (owner.selectedIds.length == 1 &&
        (owner.selectedGraphics.length == 1 ||
            owner.sheet.corners.any((c) => owner.selectedIds.contains(c.id)))) {
      editDrawingObject(owner.selectedIds.single);
    } else if (owner.selectedPlacements.length == 1) {
      editComponent(
        context,
        owner,
        component: owner.project.componentById(
          owner.selectedPlacements.single.componentId,
        ),
      );
    }
  }

  Future<void> editDrawingObject(String id) async {
    _continuationNavigationRequest++;
    if (!app.viewport.canInteract) return;
    final guard = continuationContext();
    final owner = guard.owner;
    if (owner.sheet.graphics.any((g) => g.id == id)) {
      owner.select({id});
      setState(() => showAssistant = true);
      owner.setPanel(SidePanel.properties);
      return;
    }
    final corner = owner.sheet.corners.where((c) => c.id == id).firstOrNull;
    if (corner == null) return;
    final edited = await showCornerEditor(context, corner);
    if (edited == null) return;
    if (!guard.current) {
      continuationStale();
      return;
    }
    if (edited.orientation != corner.orientation) {
      owner.execute(
        [UpdateConnectionCorner(guard.sheetId, edited)],
        'Upraven spojovací roh',
        expectedRevision: guard.revision,
      );
    }
  }

  ContinuationContext continuationContext({String? markerId}) {
    final owner = app;
    final navigation = workspace.navigationGeneration;
    return ContinuationContext(
      owner,
      markerId: markerId,
      isActive:
          () =>
              mounted &&
              workspace.navigationGeneration == navigation &&
              workspace.active == owner &&
              workspace.document(owner.documentSessionId) == owner &&
              workspace.activeTab ==
                  SheetTab(owner.documentSessionId, owner.activeSheetId),
    );
  }

  void editContinuationMarker(String id) {
    _continuationNavigationRequest++;
    if (!app.viewport.canInteract) return;
    final guard = continuationContext(markerId: id);
    final marker = guard.occurrence?.marker;
    if (marker == null) return;
    editContinuation(
      context,
      guard.owner,
      marker: marker,
      isActive: () => guard.current,
      onNavigate: (target) => followContinuation(id, target: target),
    );
  }

  void placeContinuation(Vec2 position) {
    final guard = continuationContext();
    if (!guard.current || app.showingProposal) return;
    editContinuation(
      context,
      guard.owner,
      position: position,
      initialLinkId: guard.owner.placingContinuationLinkId,
      initialGlyph: guard.owner.placingContinuationGlyph,
      initialLabel: guard.owner.placingContinuationLabel,
      isActive: () => guard.current,
    );
  }

  void startContinuation() {
    if (app.viewport.hasActiveGesture ||
        !electricalSheet(app.sheet) ||
        app.showingProposal) {
      return;
    }
    app.setContinuationTool();
  }

  Future<void> placeContinuationPeer(String markerId) async {
    if (!app.viewport.canInteract) return;
    final guard = continuationContext(markerId: markerId);
    final marker = guard.occurrence?.marker;
    if (marker == null) return;
    final sheetId = await showContinuationSheetPicker(
      context,
      project: guard.owner.project,
      isCurrent: () => guard.current,
    );
    if (sheetId == null) return;
    if (!guard.current) {
      continuationStale();
      return;
    }
    workspace.openSheet(guard.owner, sheetId);
    guard.owner.setContinuationTool(linkId: marker.linkId, glyph: marker.glyph);
  }

  void continuationStale() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Původní projekt, list nebo odkaz se změnil. Zopakujte akci z aktuálního výkresu.',
        ),
      ),
    );
  }

  int _continuationNavigationRequest = 0;

  Future<void> followContinuation(
    String markerId, {
    ContinuationTarget? target,
  }) async {
    if (!app.viewport.canInteract) return;
    final request = ++_continuationNavigationRequest;
    final guard = continuationContext(markerId: markerId);
    if (!guard.current) return;
    final owner = guard.owner;
    final targets = ContinuationIndex(
      owner.project,
    ).targets(sheetId: guard.sheetId, markerId: markerId);
    if (targets.isEmpty) {
      owner.reportStatus(
        'Tento odkaz nemá protějšek. Přidejte další marker do stejné sítě.',
      );
      return;
    }
    var chosen = target;
    if (chosen == null && targets.length == 1) chosen = targets.single;
    chosen ??= await showContinuationTargetPicker(
      context,
      targets: targets,
      linkLabels: {
        for (final link in owner.project.continuationLinks) link.id: link.label,
      },
      isCurrent:
          () => request == _continuationNavigationRequest && guard.current,
    );
    if (chosen == null) return;
    if (request != _continuationNavigationRequest ||
        !guard.current ||
        !owner.viewport.canInteract ||
        !targets.any(
          (t) =>
              t.sheet.id == chosen!.sheet.id && t.marker.id == chosen.marker.id,
        )) {
      continuationStale();
      return;
    }
    final destination = chosen;
    final zoom = owner.viewport.zoom;
    final changedSheet = destination.sheet.id != guard.sheetId;
    workspace.openSheet(owner, destination.sheet.id, fitViewport: false);
    owner.select({destination.marker.id});
    final arrival = continuationContext(markerId: destination.marker.id);
    var statusGeneration = owner.statusGeneration;
    bool current() =>
        request == _continuationNavigationRequest &&
        owner.statusGeneration == statusGeneration &&
        arrival.current &&
        owner.selectedIds.length == 1 &&
        owner.selectedIds.contains(destination.marker.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!current()) return;
      if (owner.viewport.revealContinuation(
        documentIdentity: owner,
        sheetId: destination.sheet.id,
        markerId: destination.marker.id,
        zoom: changedSheet ? zoom : null,
      )) {
        owner.reportStatus(
          'Cíl ${fullPageDesignation(destination.sheet)} · ${continuationLocation(destination)} · kreslicí fokus',
        );
        statusGeneration = owner.statusGeneration;
        // Reveal changes pan, layout and focus; only the following frame can supply the target.
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!current()) return;
          final target = owner.viewport.continuationPointerTarget(
            documentIdentity: owner,
            sheetId: destination.sheet.id,
            markerId: destination.marker.id,
            revision: arrival.revision,
          );
          if (target == null) return;
          final moved = await PointerWarp.move(target);
          if (!current()) return;
          final now = owner.viewport.continuationPointerTarget(
            documentIdentity: owner,
            sheetId: destination.sheet.id,
            markerId: destination.marker.id,
            revision: arrival.revision,
          );
          if (now == null ||
              now.viewId != target.viewId ||
              now.position != target.position ||
              now.physicalSize != target.physicalSize ||
              now.devicePixelRatio != target.devicePixelRatio) {
            return;
          }
          owner.reportStatus(
            'Cíl ${fullPageDesignation(destination.sheet)} · ${continuationLocation(destination)} · '
            '${moved ? 'ukazatel myši na cíli' : 'kreslicí fokus; přesun ukazatele myši nepotvrzen'}',
          );
        });
      }
    });
  }

  void followSelectedContinuation() {
    final id =
        app.viewport.hoveredContinuationId ??
        (app.selectedMarkers.length == 1
            ? app.selectedMarkers.single.id
            : null);
    if (id != null) followContinuation(id);
  }

  Future<void> openProject() => workspace.open();
  Future<void> importPdf() => workspace.open(
    importPdf: true,
    reviewPdf:
        (request) =>
            mounted
                ? showPdfFrameImportDialog(context, request)
                : Future.value(null),
  );
  Future<void> newProject({bool demo = false}) async =>
      workspace.create(demo: demo);
  Future<void> closeProject(EditorController doc) async {
    if (await confirmReplaceProject(context, doc)) workspace.closeDocument(doc);
  }

  Future<void> renameProject() async {
    final owner = app, sessionId = app.documentSessionId;
    final name = await editNameDialog(
      context,
      title: 'Název projektu',
      value: owner.project.name,
    );
    if (name != null && mounted && workspace.document(sessionId) == owner) {
      owner.renameProject(name);
    }
  }

  Future<void> renameSheet() async {
    final owner = app, sessionId = app.documentSessionId;
    final sheet = owner.sheet;
    final name = await editNameDialog(
      context,
      title: 'Název listu',
      value: sheet.name,
    );
    if (name != null &&
        mounted &&
        workspace.document(sessionId) == owner &&
        owner.project.sheetById(sheet.id) != null) {
      owner.renameSheet(name, sheetId: sheet.id);
    }
  }

  Future<void> addSheet([SheetType? type]) async {
    final owner = app, sessionId = app.documentSessionId;
    final request = await showNewSheetDialog(
      context,
      initialType: type ?? owner.sheet.type,
    );
    if (request != null && mounted && workspace.document(sessionId) == owner) {
      owner.addSheet(
        type: request.type,
        name: request.name,
        formStarter: request.formStarter,
      );
    }
  }

  void validate() {
    app.validate();
  }

  void commandPalette() {
    final markerId =
        app.viewport.hoveredContinuationId ??
        (app.selectedMarkers.length == 1
            ? app.selectedMarkers.single.id
            : null);
    final guard = continuationContext(markerId: markerId);
    void current(VoidCallback action) {
      if (guard.current) {
        action();
      } else {
        continuationStale();
      }
    }

    showCommandPalette(
      context,
      app,
      openProject: openProject,
      focusAssistant: focusAssistant,
      addSheet: addSheet,
      addContinuation: () => current(startContinuation),
      followContinuation:
          () => current(() {
            if (markerId != null) followContinuation(markerId);
          }),
      editHistory: () => current(editHistory),
      undoEdit: () => current(undoEdit),
      redoEdit: () => current(redoEdit),
      copySelection: () => current(copySelection),
      pasteSelection: () => current(pasteSelection),
      editSelection:
          () => current(() {
            if (markerId != null) {
              editContinuationMarker(markerId);
            } else {
              editSelectedDevice();
            }
          }),
      shortcuts: keyboardShortcuts.value,
    );
  }

  void undoEdit() {
    _continuationNavigationRequest++;
    app.undo();
  }

  void redoEdit() {
    _continuationNavigationRequest++;
    app.redo();
  }

  void editHistory() {
    _continuationNavigationRequest++;
    app.cancelClipboardPreview(notify: true);
    final guard = continuationContext();
    final owner = guard.owner;
    void apply(int count, {required bool redo}) {
      if (!guard.current || owner.showingProposal) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Historie už nepatří aktuálnímu stavu dokumentu. Otevřete ji znovu.',
              ),
            ),
          );
        }
        return;
      }
      _continuationNavigationRequest++;
      if (redo) {
        owner.redoSteps(count, expectedRevision: guard.revision);
      } else {
        owner.undoSteps(count, expectedRevision: guard.revision);
      }
    }

    showEditHistoryDialog(
      context: context,
      undoHistory: owner.undoHistory,
      redoHistory: owner.redoHistory,
      historyLimit: owner.historyLimit,
      shortcuts: keyboardShortcuts.value,
      onUndoSteps: (count) => apply(count, redo: false),
      onRedoSteps: (count) => apply(count, redo: true),
    );
  }

  bool get _editingText =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  bool _nativeTextShortcut(KeyEvent event) {
    var matches = false;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is DefaultTextEditingShortcuts) return false;
      if (widget is Shortcuts &&
          widget.shortcuts.keys.any(
            (activator) => activator.accepts(event, HardwareKeyboard.instance),
          )) {
        matches = true;
        return false;
      }
      return true;
    });
    return matches;
  }

  void copySelection() {
    final guard = continuationContext();
    guard.owner.copySelectionToClipboard(isActive: () => guard.current);
  }

  void pasteSelection() {
    app.viewport.focus();
    final guard = continuationContext();
    guard.owner.beginClipboardPaste(
      isActive:
          () =>
              guard.current &&
              ModalRoute.isCurrentOf(context) != false &&
              !_editingText,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final command = keyboardShortcuts.value.commandFor(event);
    if (command != EditorCommand.followContinuation) {
      _continuationNavigationRequest++;
    }
    if (command == null || ModalRoute.isCurrentOf(context) == false) {
      return KeyEventResult.ignored;
    }
    if (_editingText) {
      final keyboard = HardwareKeyboard.instance;
      // Native text editing keeps its standard chords even after remapping.
      if (!command.allowWhileEditingText ||
          !(keyboard.isControlPressed || keyboard.isMetaPressed) ||
          _nativeTextShortcut(event)) {
        return KeyEventResult.ignored;
      }
    }
    switch (command) {
      case EditorCommand.saveProject:
        app.saveProject();
      case EditorCommand.saveProjectAs:
        app.saveProjectAs();
      case EditorCommand.openProject:
        openProject();
      case EditorCommand.commandPalette:
        commandPalette();
      case EditorCommand.focusAssistant:
        focusAssistant();
      case EditorCommand.editProperties:
        editSelectedDevice();
      case EditorCommand.copy:
      case EditorCommand.paste:
        if (app.mode != CanvasMode.select ||
            app.viewport.hasActiveGesture ||
            app.ioBusy) {
          return KeyEventResult.ignored;
        }
        command == EditorCommand.copy ? copySelection() : pasteSelection();
      case EditorCommand.undo:
        undoEdit();
      case EditorCommand.redo:
        redoEdit();
      case EditorCommand.duplicate:
        app.duplicateSelection();
      case EditorCommand.selectAll:
        app.selectAll();
      case EditorCommand.cancelTool:
        app.cancelTool();
      case EditorCommand.temporaryPan:
        return KeyEventResult.ignored;
      default:
        if (app.viewport.hasActiveGesture || app.ioBusy) {
          return KeyEventResult.ignored;
        }
        switch (command) {
          case EditorCommand.selectTool:
            app.setMode(CanvasMode.select);
          case EditorCommand.lineTool:
            app.setMode(CanvasMode.drawLine);
          case EditorCommand.rectangleTool:
            app.setMode(CanvasMode.drawRectangle);
          case EditorCommand.textTool:
            app.setMode(CanvasMode.drawText);
          case EditorCommand.wireTool:
            app.setMode(CanvasMode.wire);
          case EditorCommand.panTool:
            app.setMode(CanvasMode.pan);
          case EditorCommand.followContinuation:
            followSelectedContinuation();
          case EditorCommand.fitSheet:
            app.viewport.fit();
          case EditorCommand.rotate:
            app.rotateSelection();
          case EditorCommand.deleteSelection:
            app.deleteSelection();
          case EditorCommand.previousSheet:
            workspace.navigateSheet(-1);
          case EditorCommand.nextSheet:
            workspace.navigateSheet(1);
          default:
            return KeyEventResult.ignored;
        }
    }
    return KeyEventResult.handled;
  }

  String actionLabel(String label, EditorCommand command) {
    final shortcut = keyboardShortcuts.value.labelFor(command);
    return shortcut.isEmpty ? label : '$label · $shortcut';
  }

  @override
  Widget build(BuildContext context) {
    final c = EcadColors.of(context);
    return PrimaryScrollController.none(child: _buildWorkspace(c));
  }

  Widget _buildWorkspace(EcadColors c) {
    final canvasOwner = app;
    final canvasGeneration = canvasOwner.documentGeneration;
    final canvasSheetId = canvasOwner.sheet.id;
    final canvasRevision = canvasOwner.project.revision;
    final navigationGeneration = workspace.navigationGeneration;

    bool canvasContextCurrent() =>
        mounted &&
        workspace.active == canvasOwner &&
        workspace.navigationGeneration == navigationGeneration &&
        canvasOwner.isDocumentCurrent(canvasGeneration) &&
        canvasOwner.project.revision == canvasRevision &&
        canvasOwner.activeSheetId == canvasSheetId;

    void followDevice(String sourceId, DeviceOccurrence target) {
      if (!canvasContextCurrent()) return;
      final source = canvasOwner.project
          .sheetById(canvasSheetId)
          ?.deviceById(sourceId);
      final destination = canvasOwner.project
          .sheetById(target.sheet.id)
          ?.deviceById(target.device.id);
      if (source == null ||
          destination == null ||
          source.id == destination.id ||
          source.componentId != destination.componentId) {
        return;
      }
      canvasOwner.navigateToDevice(target.sheet.id, target.device.id);
    }

    return Listener(
      onPointerDown: (_) => _continuationNavigationRequest++,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, bounds) {
                final compact = bounds.maxWidth < 1120;
                final projectVisible = showProject && bounds.maxWidth >= 950;
                final assistantVisible =
                    showAssistant && bounds.maxWidth >= 680;
                return Column(
                  children: [
                    _commandBar(c, bounds.maxWidth),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (projectVisible) ...[
                            SizedBox(
                              width: compact ? 240 : 285,
                              child: ProjectPanel(
                                controller: app,
                                workspace: workspace,
                                onCloseProject: closeProject,
                                onRenameSheet: renameSheet,
                                onAddSheet: addSheet,
                                shortcuts: keyboardShortcuts.value,
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
                                Expanded(
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child:
                                            workspace.activeTab == null
                                                ? const Center(
                                                  child: Text(
                                                    'Otevřete list ze stromu projektů',
                                                  ),
                                                )
                                                : app.sheet.type ==
                                                    SheetType.billOfMaterials
                                                ? ReportView(
                                                  key: ValueKey(
                                                    SheetTab(
                                                      app.documentSessionId,
                                                      app.sheet.id,
                                                    ),
                                                  ),
                                                  app: app,
                                                  showControls: false,
                                                  isNavigationCurrent:
                                                      canvasContextCurrent,
                                                )
                                                : app.sheet.type ==
                                                        SheetType
                                                            .cabinetLayout &&
                                                    (app.sheet.mountingView !=
                                                            null ||
                                                        app
                                                            .sheet
                                                            .graphics
                                                            .isEmpty)
                                                ? MountingCanvas(
                                                  key: ValueKey(
                                                    SheetTab(
                                                      app.documentSessionId,
                                                      app.sheet.id,
                                                    ),
                                                  ),
                                                  app: app,
                                                  showControls: false,
                                                  isNavigationCurrent:
                                                      canvasContextCurrent,
                                                  cursorSettings:
                                                      drawingCursor.value,
                                                )
                                                : DrawingCursorRegion(
                                                  settings: drawingCursor.value,
                                                  backgroundColor:
                                                      c
                                                          .canvasPalette
                                                          .background,
                                                  resetKey: (
                                                    app.documentSessionId,
                                                    app.sheet.id,
                                                  ),
                                                  child: SchematicCanvas(
                                                    key: ValueKey(
                                                      SheetTab(
                                                        app.documentSessionId,
                                                        app.sheet.id,
                                                      ),
                                                    ),
                                                    documentIdentity: app,
                                                    project: app.displayProject,
                                                    sheet: app.displaySheet,
                                                    readOnly:
                                                        app.showingProposal,
                                                    selectedIds:
                                                        app.selectedIds,
                                                    mode: app.mode,
                                                    placingKind:
                                                        app.placingKind,
                                                    terminalSides:
                                                        app.terminalSides,
                                                    cornerOrientation:
                                                        app.cornerOrientation,
                                                    onPlaceCorner:
                                                        app.placeCorner,
                                                    showGrid: app.showGrid,
                                                    palette: c.canvasPalette,
                                                    controller: app.viewport,
                                                    shortcuts:
                                                        keyboardShortcuts.value,
                                                    onSelectionChanged: (ids) {
                                                      if (!app
                                                          .showingProposal) {
                                                        app.select(ids);
                                                        if (ids.isNotEmpty) {
                                                          app.setPanel(
                                                            SidePanel
                                                                .properties,
                                                          );
                                                        }
                                                      }
                                                    },
                                                    onMoveDevices:
                                                        app.moveDevices,
                                                    onMoveSelection:
                                                        app.moveSelection,
                                                    onCreateGraphic:
                                                        app.createGraphic,
                                                    onPlaceDevice:
                                                        app.placeDevice,
                                                    onConnect: app.connect,
                                                    onDeleteWire:
                                                        app.deleteWire,
                                                    onEditDevice:
                                                        (id) =>
                                                            showDeviceProperties(
                                                              context,
                                                              app,
                                                              id,
                                                            ),
                                                    onEditDrawingObject:
                                                        editDrawingObject,
                                                    onFollowDevice:
                                                        followDevice,
                                                    onEditContinuation:
                                                        editContinuationMarker,
                                                    onFollowContinuation: (id) {
                                                      if (canvasContextCurrent()) {
                                                        followContinuation(id);
                                                      }
                                                    },
                                                    onPlaceContinuation:
                                                        placeContinuation,
                                                    pastePreview:
                                                        app.pastePreview,
                                                    onPlacePaste:
                                                        app.placeClipboard,
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
                                              borderRadius:
                                                  BorderRadius.circular(4),
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
                                      if (app.mode == CanvasMode.corner ||
                                          app.mode == CanvasMode.place ||
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
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              app.mode == CanvasMode.wire
                                                  ? 'Klikněte na první a druhý připojovací bod'
                                                  : 'Klikněte do výkresu · ${keyboardShortcuts.value.labelFor(EditorCommand.cancelTool)} ukončí vkládání',
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
                                if (app.diagnosticsVisible)
                                  _diagnosticsPanel(c),
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
                                                () => showAiSettings(
                                                  context,
                                                  app,
                                                ),
                                            inputFocus: promptFocus,
                                          ),
                                          PropertiesPanel(
                                            controller: app,
                                            shortcuts: keyboardShortcuts.value,
                                            onEditContinuation:
                                                editContinuationMarker,
                                            onAddContinuation:
                                                startContinuation,
                                            onAddContinuationPeer:
                                                placeContinuationPeer,
                                            onFollowContinuation:
                                                (id, target) =>
                                                    followContinuation(
                                                      id,
                                                      target: target,
                                                    ),
                                          ),
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
      ),
    );
  }

  Widget _commandBar(EcadColors c, double width) {
    final mounting =
        app.sheet.type == SheetType.cabinetLayout &&
        (app.sheet.mountingView != null || app.sheet.graphics.isEmpty);
    final report = app.sheet.type == SheetType.billOfMaterials;
    if (_lastMode != app.mode) {
      _lastMode = app.mode;
      toolGroup = switch (app.mode) {
        CanvasMode.drawLine ||
        CanvasMode.drawRectangle ||
        CanvasMode.drawText => _ToolGroup.drawing,
        CanvasMode.wire ||
        CanvasMode.continuation ||
        CanvasMode.corner ||
        CanvasMode.place => _ToolGroup.electrical,
        _ => toolGroup,
      };
    }
    if (_lastVisibleTab != workspace.activeTab) {
      _lastVisibleTab = workspace.activeTab;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final tabContext = _activeTabKey.currentContext;
        if (mounted && tabContext != null) {
          Scrollable.ensureVisible(
            tabContext,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          );
        }
      });
    }
    return Container(
      key: const ValueKey('workspace-command-bar'),
      height: 40,
      decoration: BoxDecoration(
        color: c.panel,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 4),
          _fileMenu(),
          _barButton(
            Icons.save_outlined,
            actionLabel(
              app.dirty ? 'Uložit · neuložené změny' : 'Uložit',
              EditorCommand.saveProject,
            ),
            app.ioBusy ? null : app.saveProject,
            selected: app.dirty,
          ),
          if (width >= 680) ...[
            _barButton(
              Icons.undo,
              '${actionLabel('Vrátit', EditorCommand.undo)}${app.undoLabel == null ? '' : '\n${app.undoLabel}'}',
              app.canUndo ? undoEdit : null,
            ),
            _barButton(
              Icons.redo,
              '${actionLabel('Obnovit', EditorCommand.redo)}${app.redoLabel == null ? '' : '\n${app.redoLabel}'}',
              app.canRedo ? redoEdit : null,
            ),
            _barButton(Icons.history, 'Historie úprav', editHistory),
          ],
          _toolbarDivider(c),
          _tool(
            Icons.near_me_outlined,
            'Výběr',
            EditorCommand.selectTool,
            CanvasMode.select,
          ),
          if (width >= 680)
            _tool(
              Icons.pan_tool_outlined,
              'Posun',
              EditorCommand.panTool,
              CanvasMode.pan,
            ),
          if (mounting) ...[
            _barButton(
              Icons.view_quilt_outlined,
              'Pohled a měřítko',
              () => editMountingView(context, app),
            ),
            _barButton(
              Icons.add_box_outlined,
              'Umístit komponentu',
              () => showMountPlacementDialog(context, app),
            ),
          ] else if (report)
            _barButton(
              Icons.table_chart_outlined,
              'Vlastnosti reportu',
              () => editSheetSettings(context, app),
            )
          else ...[
            _toolGroupMenu(),
            if (width >= 1120) ..._groupTools(),
          ],
          _toolbarDivider(c),
          Expanded(child: _sheetTabs(c)),
          if (DesktopWindow.enabled)
            DesktopWindow.dragArea(const SizedBox(width: 24, height: 40)),
          _barButton(
            Icons.content_paste,
            actionLabel('Vložit ze schránky', EditorCommand.paste),
            pasteSelection,
          ),
          if (width >= 800)
            _barButton(
              Icons.search,
              actionLabel('Příkazy', EditorCommand.commandPalette),
              commandPalette,
            ),
          _barButton(
            Icons.vertical_split_outlined,
            'Zobrazit projekt a knihovnu',
            () => setState(() => showProject = !showProject),
            selected: showProject,
          ),
          _barButton(Icons.tune, 'Zobrazit vlastnosti', () {
            setState(() => showAssistant = true);
            app.setPanel(SidePanel.properties);
          }, selected: showAssistant && app.sidePanel == SidePanel.properties),
          _barButton(Icons.auto_awesome_outlined, 'Zobrazit asistenta', () {
            if (showAssistant && app.sidePanel == SidePanel.assistant) {
              setState(() => showAssistant = false);
            } else {
              setState(() => showAssistant = true);
              app.setPanel(SidePanel.assistant);
            }
          }, selected: showAssistant && app.sidePanel == SidePanel.assistant),
          _settingsMenu(),
          if (width >= 680)
            _barButton(
              Icons.help_outline,
              'Ovládání a klávesové zkratky',
              () => showHelpDialog(context, shortcuts: keyboardShortcuts.value),
            ),
          const DesktopWindowControls(),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _fileMenu() => PopupMenuButton<String>(
    tooltip: 'Soubor',
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 280),
    offset: const Offset(0, 40),
    onSelected: (value) {
      switch (value) {
        case 'new':
          newProject();
        case 'demo':
          newProject(demo: true);
        case 'open':
          openProject();
        case 'recovery':
          showRecoveryDialog(context, workspace);
        case 'importPdf':
          importPdf();
        case 'save':
          app.saveProject();
        case 'saveAs':
          app.saveProjectAs();
        case 'rename':
          renameProject();
        case 'close':
          closeProject(app);
        case 'pdf':
          app.exportProject(pdf: true);
        case 'svg':
          app.exportProject(pdf: false);
        case 'validate':
          validate();
        case 'commands':
          commandPalette();
      }
    },
    itemBuilder:
        (_) => [
          PopupMenuItem<String>(
            enabled: false,
            child: Tooltip(
              message: app.fileName ?? 'Projekt bez souboru',
              child: Text(
                app.project.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'new', child: Text('Nový projekt')),
          PopupMenuItem(
            value: 'open',
            enabled: !app.ioBusy,
            child: Text(
              actionLabel('Otevřít projekt…', EditorCommand.openProject),
            ),
          ),
          const PopupMenuItem(
            value: 'recovery',
            child: Text('Obnovit pracovní kopii…'),
          ),
          PopupMenuItem(
            value: 'importPdf',
            enabled: !app.ioBusy,
            child: const Text('Importovat PDF jako grafiku…'),
          ),
          PopupMenuItem(
            value: 'save',
            enabled: !app.ioBusy,
            child: Text(
              actionLabel('Uložit projekt', EditorCommand.saveProject),
            ),
          ),
          PopupMenuItem(
            value: 'saveAs',
            enabled: !app.ioBusy,
            child: Text(
              actionLabel('Uložit jako…', EditorCommand.saveProjectAs),
            ),
          ),
          const PopupMenuItem(
            value: 'rename',
            child: Text('Přejmenovat projekt…'),
          ),
          const PopupMenuItem(
            value: 'close',
            child: Text('Zavřít aktivní projekt…'),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'pdf',
            enabled: !app.ioBusy,
            child: const Text('Exportovat všechny listy do PDF…'),
          ),
          PopupMenuItem(
            value: 'svg',
            enabled: !app.ioBusy,
            child: const Text('Exportovat aktuální list do SVG…'),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'validate',
            child: Text('Zkontrolovat projekt'),
          ),
          PopupMenuItem(
            value: 'commands',
            child: Text(actionLabel('Příkazy…', EditorCommand.commandPalette)),
          ),
          const PopupMenuItem(
            value: 'demo',
            child: Text('Otevřít ukázkový projekt'),
          ),
        ],
    child: const SizedBox(
      width: 32,
      height: 36,
      child: Center(child: BrandMark(size: 21)),
    ),
  );

  Future<void> _terminalTool() async {
    final owner = app, generation = app.documentGeneration;
    final sides = await showTerminalSymbolDialog(
      context,
      initialSides: owner.terminalSides,
      title: 'Vložit průchozí svorku',
    );
    if (sides != null && owner.isDocumentCurrent(generation)) {
      owner.setTerminalTool(sides);
    }
  }

  Widget _toolGroupMenu() => PopupMenuButton<Object>(
    tooltip: 'Sada nástrojů',
    padding: EdgeInsets.zero,
    offset: const Offset(0, 36),
    onSelected: (value) {
      if (value is _ToolGroup) {
        setState(() => toolGroup = value);
      } else if (value is CanvasMode) {
        app.setMode(value);
      } else if (value is CornerOrientation) {
        app.setCornerTool(value);
      } else {
        switch (value) {
          case 'terminal':
            _terminalTool();
          case 'continuation':
            startContinuation();
          case 'follow':
            followSelectedContinuation();
          case 'rotate':
            app.rotateSelection();
          case 'duplicate':
            app.duplicateSelection();
          case 'copy':
            copySelection();
          case 'paste':
            pasteSelection();
          case 'delete':
            app.deleteSelection();
          case 'edit':
            editSelectedDevice();
          case 'history':
            editHistory();
        }
      }
    },
    itemBuilder:
        (_) => [
          for (final group in _ToolGroup.values)
            CheckedPopupMenuItem(
              value: group,
              checked: toolGroup == group,
              child: Text(group.label),
            ),
          const PopupMenuDivider(),
          if (toolGroup == _ToolGroup.electrical) ...[
            PopupMenuItem(
              value: CanvasMode.wire,
              child: Text(actionLabel('Vodič', EditorCommand.wireTool)),
            ),
            PopupMenuItem(
              value: 'continuation',
              enabled: electricalSheet(app.sheet),
              child: const Text('Vložit pokračovací odkaz'),
            ),
            const PopupMenuItem(
              value: 'follow',
              child: Text('Přejít na protějšek'),
            ),
            const PopupMenuItem(
              value: 'terminal',
              child: Text('Svorka · 1–4 směry'),
            ),
            for (final orientation in CornerOrientation.values)
              PopupMenuItem(
                value: orientation,
                child: Text('Spojovací roh ${orientation.glyph}'),
              ),
          ],
          if (toolGroup == _ToolGroup.drawing) ...[
            PopupMenuItem(
              value: CanvasMode.drawLine,
              child: Text(actionLabel('Čára', EditorCommand.lineTool)),
            ),
            PopupMenuItem(
              value: CanvasMode.drawRectangle,
              child: Text(actionLabel('Obdélník', EditorCommand.rectangleTool)),
            ),
            PopupMenuItem(
              value: CanvasMode.drawText,
              child: Text(actionLabel('Text', EditorCommand.textTool)),
            ),
          ],
          if (toolGroup == _ToolGroup.editing) ...[
            PopupMenuItem(
              value: 'rotate',
              enabled:
                  app.selectedIds.isNotEmpty || app.mode == CanvasMode.corner,
              child: Text(actionLabel('Otočit výběr', EditorCommand.rotate)),
            ),
            PopupMenuItem(
              value: 'duplicate',
              enabled: app.selectedIds.isNotEmpty,
              child: Text(
                actionLabel('Duplikovat výběr', EditorCommand.duplicate),
              ),
            ),
            PopupMenuItem(
              value: 'copy',
              enabled: app.selectedIds.isNotEmpty,
              child: Text(actionLabel('Kopírovat výběr', EditorCommand.copy)),
            ),
            PopupMenuItem(
              value: 'paste',
              child: Text(
                actionLabel('Vložit ze schránky', EditorCommand.paste),
              ),
            ),
            PopupMenuItem(
              value: 'delete',
              enabled: app.selectedIds.isNotEmpty,
              child: Text(
                actionLabel('Odstranit výběr', EditorCommand.deleteSelection),
              ),
            ),
            PopupMenuItem(
              value: 'edit',
              enabled: _canEditSelection,
              child: Text(
                actionLabel(
                  'Upravit vybraný objekt',
                  EditorCommand.editProperties,
                ),
              ),
            ),
            const PopupMenuItem(
              value: 'history',
              child: Text('Historie úprav'),
            ),
          ],
        ],
    child: Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(toolGroup.icon, size: 15),
          const SizedBox(width: 5),
          Text(toolGroup.label, style: const TextStyle(fontSize: 11)),
          const SizedBox(width: 3),
          const Icon(Icons.expand_more, size: 14),
        ],
      ),
    ),
  );

  bool get _canEditSelection =>
      !app.showingProposal &&
      (app.selectedDevices.length == 1 ||
          app.selectedPlacements.length == 1 ||
          app.selectedMarkers.length == 1 ||
          app.selectedGraphics.length == 1 ||
          (app.selectedIds.length == 1 &&
              app.sheet.corners.any((c) => app.selectedIds.contains(c.id))));

  List<Widget> _groupTools() => switch (toolGroup) {
    _ToolGroup.electrical => [
      _tool(
        Icons.polyline_outlined,
        'Vodič',
        EditorCommand.wireTool,
        CanvasMode.wire,
      ),
      _barButton(
        Icons.arrow_forward,
        'Vložit pokračovací odkaz',
        electricalSheet(app.sheet) ? startContinuation : null,
        selected: app.mode == CanvasMode.continuation,
      ),
      _barButton(
        Icons.subdirectory_arrow_right,
        actionLabel('Přejít na protějšek', EditorCommand.followContinuation),
        followSelectedContinuation,
      ),
      _barButton(
        Icons.radio_button_unchecked,
        'Svorka · 1–4 směry',
        _terminalTool,
        selected:
            app.mode == CanvasMode.place &&
            app.placingKind == DeviceKind.terminal,
      ),
      SizedBox(
        width: 30,
        height: 30,
        child: PopupMenuButton<CornerOrientation>(
          tooltip: 'Spojovací roh',
          padding: EdgeInsets.zero,
          icon: Icon(
            Icons.turn_right,
            size: 18,
            color:
                app.mode == CanvasMode.corner
                    ? EcadColors.of(context).accent
                    : null,
          ),
          onSelected: app.setCornerTool,
          itemBuilder:
              (_) => [
                for (final orientation in CornerOrientation.values)
                  PopupMenuItem(
                    value: orientation,
                    child: Text('Spojovací roh ${orientation.glyph}'),
                  ),
              ],
        ),
      ),
    ],
    _ToolGroup.drawing => [
      _tool(
        Icons.horizontal_rule,
        'Čára',
        EditorCommand.lineTool,
        CanvasMode.drawLine,
      ),
      _tool(
        Icons.crop_square,
        'Obdélník',
        EditorCommand.rectangleTool,
        CanvasMode.drawRectangle,
      ),
      _tool(
        Icons.text_fields,
        'Text',
        EditorCommand.textTool,
        CanvasMode.drawText,
      ),
    ],
    _ToolGroup.editing => [
      _barButton(
        Icons.rotate_right,
        actionLabel('Otočit výběr', EditorCommand.rotate),
        app.selectedIds.isEmpty && app.mode != CanvasMode.corner
            ? null
            : app.rotateSelection,
      ),
      _barButton(
        Icons.copy_all_outlined,
        actionLabel('Duplikovat výběr', EditorCommand.duplicate),
        app.selectedIds.isEmpty ? null : app.duplicateSelection,
      ),
      _barButton(
        Icons.content_copy,
        actionLabel('Kopírovat výběr', EditorCommand.copy),
        app.selectedIds.isEmpty ? null : copySelection,
      ),
      _barButton(
        Icons.delete_outline,
        actionLabel('Odstranit výběr', EditorCommand.deleteSelection),
        app.selectedIds.isEmpty ? null : app.deleteSelection,
      ),
      _barButton(
        Icons.edit_outlined,
        actionLabel('Upravit vybraný objekt', EditorCommand.editProperties),
        _canEditSelection ? editSelectedDevice : null,
      ),
    ],
  };

  Widget _settingsMenu() => SizedBox(
    width: 30,
    height: 30,
    child: PopupMenuButton<String>(
      tooltip: 'Nastavení programu',
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.settings_outlined, size: 18),
      onSelected: (value) {
        switch (value) {
          case 'keyboard':
            showKeyboardShortcutsDialog(
              context,
              preferences: keyboardShortcuts,
            );
          case 'cursor':
            showDrawingCursorDialog(context, preferences: drawingCursor);
          case 'grid':
            app.toggleGrid();
          default:
            app.setAppearance(EcadAppearance.values.byName(value));
        }
      },
      itemBuilder:
          (_) => [
            const PopupMenuItem(
              value: 'keyboard',
              child: Text('Klávesové zkratky…'),
            ),
            const PopupMenuItem(
              value: 'cursor',
              child: Text('Kreslicí kurzor…'),
            ),
            CheckedPopupMenuItem(
              value: 'grid',
              checked: app.showGrid,
              child: const Text('Zobrazit mřížku'),
            ),
            const PopupMenuDivider(),
            for (final appearance in EcadAppearance.values)
              CheckedPopupMenuItem(
                value: appearance.name,
                checked: app.appearance == appearance,
                child: Text(appearance.label),
              ),
          ],
    ),
  );

  Widget _toolbarDivider(EcadColors c) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: SizedBox(
      height: 18,
      child: VerticalDivider(width: 1, color: c.border),
    ),
  );

  Widget _barButton(
    IconData icon,
    String label,
    VoidCallback? action, {
    bool selected = false,
  }) => EcadIconButton(
    icon: icon,
    label: label,
    onPressed: action,
    selected: selected,
    size: 30,
    iconSize: 17,
  );

  Widget _tool(
    IconData icon,
    String name,
    EditorCommand command,
    CanvasMode mode,
  ) => _barButton(
    icon,
    actionLabel(name, command),
    () => app.setMode(mode),
    selected: app.mode == mode,
  );

  Widget _sheetTabs(EcadColors c) => SizedBox(
    height: 39,
    child: Row(
      children: [
        _pageButton(
          Icons.chevron_left,
          actionLabel('Předchozí list', EditorCommand.previousSheet),
          workspace.adjacentSheet(-1) == null || app.ioBusy
              ? null
              : () {
                if (!app.viewport.hasActiveGesture && !app.ioBusy) {
                  workspace.navigateSheet(-1);
                }
              },
        ),
        _pageButton(
          Icons.chevron_right,
          actionLabel('Následující list', EditorCommand.nextSheet),
          workspace.adjacentSheet(1) == null || app.ioBusy
              ? null
              : () {
                if (!app.viewport.hasActiveGesture && !app.ioBusy) {
                  workspace.navigateSheet(1);
                }
              },
        ),
        Expanded(
          child: LayoutBuilder(
            builder:
                (context, bounds) => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: bounds.maxWidth),
                    child: IntrinsicWidth(
                      child: Row(
                        children: [
                          for (final tab in workspace.tabs)
                            Builder(
                              builder: (context) {
                                final doc = workspace.document(tab.sessionId)!;
                                final sheet =
                                    doc.project.sheetById(tab.sheetId)!;
                                final title =
                                    '${doc.project.name}${doc.dirty ? ' ●' : ''} · ${fullPageDesignation(sheet)} ${sheet.name}';
                                final label =
                                    '${fullPageDesignation(sheet)} ${sheet.name}'
                                    '${workspace.documents.length > 1 ? ' · ${doc.project.name}' : ''}'
                                    '${doc.dirty ? ' ●' : ''}';
                                return SheetContextMenu(
                                  key:
                                      workspace.activeTab == tab
                                          ? _activeTabKey
                                          : null,
                                  controller: doc,
                                  sheet: sheet,
                                  workspace: workspace,
                                  onRenameSheet: renameSheet,
                                  child: Container(
                                    width: 210,
                                    height: 39,
                                    decoration: BoxDecoration(
                                      color:
                                          workspace.activeTab == tab
                                              ? c.canvasPalette.background
                                              : null,
                                      border: Border(
                                        bottom: BorderSide(
                                          color:
                                              workspace.activeTab == tab
                                                  ? c.accent
                                                  : c.border,
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Tooltip(
                                            message: title,
                                            child: InkWell(
                                              onTap: () => activateTab(tab),
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 10,
                                                    ),
                                                child: Text(
                                                  label,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight:
                                                        workspace.activeTab ==
                                                                tab
                                                            ? FontWeight.w600
                                                            : FontWeight.w400,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        EcadIconButton(
                                          icon: Icons.close,
                                          label:
                                              'Zavřít tab ${fullPageDesignation(sheet)}',
                                          onPressed:
                                              () => workspace.closeTab(tab),
                                          size: 26,
                                          iconSize: 13,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          Expanded(
                            child: DesktopWindow.dragArea(
                              const SizedBox(height: 39),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
          ),
        ),
        _barButton(Icons.add, 'Přidat list', addSheet),
      ],
    ),
  );

  Widget _pageButton(IconData icon, String label, VoidCallback? action) =>
      IconButton(
        tooltip: label,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
        visualDensity: VisualDensity.compact,
        onPressed: action,
        icon: Icon(icon, size: 17),
      );

  Widget _zoomControls(EcadColors c) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      EcadIconButton(
        icon: Icons.remove,
        label: 'Oddálit',
        onPressed: app.viewport.zoomOut,
        size: 25,
        iconSize: 16,
      ),
      ListenableBuilder(
        listenable: app.viewport,
        builder:
            (_, _) => SizedBox(
              width: 45,
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
        size: 25,
        iconSize: 16,
      ),
      EcadIconButton(
        icon: Icons.fit_screen,
        label: actionLabel('Celý list', EditorCommand.fitSheet),
        onPressed: app.viewport.fit,
        size: 25,
        iconSize: 16,
      ),
    ],
  );

  Widget _statusBar(EcadColors c, bool compact) => Container(
    height: 30,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: BoxDecoration(
      color: c.panel,
      border: Border(top: BorderSide(color: c.border)),
    ),
    child: Row(
      children: [
        Icon(app.ioBusy ? Icons.hourglass_top : Icons.check, size: 12),
        const SizedBox(width: 6),
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
        if (app.sheet.sourcePage != null) ...[
          const SizedBox(width: 8),
          Tooltip(
            message:
                'Grafika z PDF · ${app.sheet.graphics.length} objektů · elektrické vazby nejsou obnovené',
            child: Icon(Icons.info_outline, size: 14, color: c.muted),
          ),
        ],
        const SizedBox(width: 12),
        Tooltip(
          message: app.sheet.type.label,
          child: Text(
            fullPageDesignation(app.sheet),
            style: const TextStyle(fontSize: 10),
          ),
        ),
        if (!compact) ...[
          const SizedBox(width: 12),
          Text(
            app.sheet.graphics.isEmpty
                ? '${app.sheet.devices.length} přístrojů · ${AutoConnect.wires(app.sheet).length} vodičů'
                : '${app.sheet.graphics.length} grafických objektů · ${app.selectedIds.length} vybráno',
            style: const TextStyle(fontSize: 9),
          ),
          const SizedBox(width: 12),
          Tooltip(
            message: app.fileName ?? 'Projekt bez souboru',
            child: Text(
              app.autosaveStatus,
              style: TextStyle(fontSize: 9, color: c.muted),
            ),
          ),
        ],
        const SizedBox(width: 8),
        _zoomControls(c),
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
                      key: const ValueKey('diagnostics-list'),
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
                            diagnosticText(app.project, issue),
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () {
                            if (issue.sheetId != null) {
                              app.setSheet(issue.sheetId!);
                            }
                            if (issue.deviceId != null) {
                              app.select({issue.deviceId!});
                            }
                            if (issue.componentId case final id?) {
                              editComponent(
                                context,
                                app,
                                component: app.project.componentById(id),
                              );
                            } else if (issue.articleId case final id?) {
                              editArticle(
                                context,
                                app,
                                article: app.project.articleById(id),
                              );
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
