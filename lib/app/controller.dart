import 'dart:async';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../services/schematic_clipboard.dart';
import '../services/mounting_annotations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../editor/schematic_canvas.dart';
import '../widgets/diagnostic_text.dart';
import '../services/document_session.dart';
import '../services/ecad_services.dart';
import '../services/project_import.dart';
import 'theme.dart';

enum SidePanel { assistant, properties }

String defaultSheetName(SheetType type) => switch (type) {
  SheetType.multiLine => 'Nové schéma',
  SheetType.singleLine => 'Nové jednopólové schéma',
  SheetType.cabinetLayout => 'Nová výstavba rozvaděče',
  SheetType.form => 'Nový formulář',
  SheetType.billOfMaterials => 'Kusovník',
};

class ConversationEntry {
  const ConversationEntry(this.text, {this.isUser = false, this.detail});
  final String text;
  final bool isUser;
  final String? detail;
}

class EditorController extends ChangeNotifier {
  EditorController({
    EcadProject? initialProject,
    ProjectPersistence? persistence,
    AssistantService? assistant,
    ProjectImportService? importer,
    bool startEmpty = false,
  }) : persistence = persistence ?? ProjectPersistence(),
       assistant = assistant ?? AssistantService(),
       importer = importer ?? ProjectImportService(),
       _restoreAutosave = initialProject == null {
    _session = DocumentSession(
      initialProject ?? (startEmpty ? _emptyProject() : DemoProject.create()),
      persistence: this.persistence,
    );
    activeSheetId = project.pages.first.id;
    showGrid = project.pages.first.sourcePage == null;
  }

  static EcadProject _emptyProject() => EcadProject(
    id: newId('project'),
    name: 'Nový projekt',
    pages: [Sheet(id: newId('sheet'), name: 'První schéma', number: '01')],
  );

  late final DocumentSession _session;
  final bool _restoreAutosave;
  ProjectEngine get _engine => _session.engine;
  final ProjectPersistence persistence;
  final AssistantService assistant;
  final ProjectExportService exporter = ProjectExportService();
  final ProjectImportService importer;
  final SchematicViewportController viewport = SchematicViewportController();
  Timer? _autosaveTimer;
  bool _disposed = false;
  int _requestId = 0;
  int get _documentGeneration => _session.generation;
  String activeSheetId = '';
  Set<String> selectedIds = {};
  EcadAppearance appearance = EcadAppearance.paper;
  CanvasMode mode = CanvasMode.select;
  DeviceKind? placingKind;
  String? placingContinuationLinkId;
  ContinuationGlyph placingContinuationGlyph = ContinuationGlyph.arrow;
  String placingContinuationLabel = '';
  Set<PortSide> terminalSides = const {PortSide.top, PortSide.bottom};
  String? terminalStripId;
  CornerOrientation cornerOrientation = CornerOrientation.topLeft;
  bool showGrid = true;
  SidePanel sidePanel = SidePanel.assistant;
  bool busy = false;
  bool ioBusy = false;
  bool useOllama = false;
  String _status = 'Připraveno';
  int _statusGeneration = 0;
  String get status => _status;
  int get statusGeneration => _statusGeneration;
  set status(String value) {
    _status = value;
    _statusGeneration++;
  }

  String? get fileName => _session.fileName;
  DocumentFileHandle? get currentFile => _session.currentFile;
  String get documentSessionId => _session.sessionId;
  int get documentGeneration => _documentGeneration;
  bool isDocumentCurrent(int generation) => _isCurrentDocument(generation);
  int? get savedRevision => _session.savedRevision;
  String autosaveStatus = 'Pracovní kopie se ukládá místně';
  AiProviderSettings aiSettings = const AiProviderSettings();
  AssistantProposal? proposal;
  EcadProject? _proposalPreview;
  EcadProject? get proposalPreview => _proposalPreview;
  bool showingProposal = false;
  bool _applyingProposal = false;
  final List<ConversationEntry> conversation = [];
  List<Diagnostic> diagnostics = [];
  bool diagnosticsVisible = false;

  EcadProject get project => _engine.project;
  Sheet get sheet => project.pages.firstWhere(
    (p) => p.id == activeSheetId,
    orElse: () => project.pages.first,
  );
  EcadProject get displayProject =>
      showingProposal && proposalIsCurrent
          ? (_proposalPreview ?? project)
          : project;
  Sheet get displaySheet =>
      showingProposal && proposalIsCurrent
          ? (_proposalPreview?.pages.firstWhere(
                (p) => p.id == activeSheetId,
                orElse: () => sheet,
              ) ??
              sheet)
          : sheet;
  List<EditHistoryEntry> get undoHistory => _engine.undoHistory;
  List<EditHistoryEntry> get redoHistory => _engine.redoHistory;
  int get historyLimit => _engine.historyLimit;
  String? get undoLabel => _engine.undoLabel;
  String? get redoLabel => _engine.redoLabel;
  bool get canUndo => _engine.canUndo;
  bool get canRedo => _engine.canRedo;
  bool get dirty => _session.dirty;
  bool get proposalIsCurrent =>
      proposal != null && proposal!.baseRevision == project.revision;
  List<Device> get selectedDevices =>
      sheet.devices.where((d) => selectedIds.contains(d.id)).toList();
  List<DrawingElement> get selectedGraphics =>
      sheet.graphics.where((g) => selectedIds.contains(g.id)).toList();
  String get assistantLabel => useOllama ? aiSettings.model : 'Místní příkazy';

  Future<void> initialize({
    String? startupProjectPath,
    String? startupError,
  }) async {
    final generation = _documentGeneration;
    final revision = project.revision;
    try {
      final preferences = await SharedPreferences.getInstance();
      final theme = preferences.getString('open_ecad.appearance');
      appearance = EcadAppearance.values.firstWhere(
        (m) => m.name == theme,
        orElse: () => EcadAppearance.paper,
      );
      aiSettings =
          await persistence.loadAiSettings() ?? const AiProviderSettings();
    } catch (_) {
      // Preferences must not prevent an explicit file from opening.
    }
    if (!_isCurrentDocument(generation) || project.revision != revision) return;
    try {
      final result = await _session.initialize(
        startupProjectPath: startupProjectPath,
        startupError: startupError,
        restoreAutosave: _restoreAutosave,
      );
      if (result == DocumentIoResult.opened ||
          result == DocumentIoResult.restored) {
        if (!_isCurrentDocument(generation + 1)) return;
        _resetDocumentView();
        status =
            result == DocumentIoResult.opened
                ? 'Projekt otevřen'
                : 'Obnovena místní pracovní kopie';
        if (result == DocumentIoResult.opened) {
          _scheduleAutosave();
        } else {
          autosaveStatus = 'Obnoveno z tohoto zařízení';
        }
      }
    } catch (error) {
      if (!_isCurrentDocument(generation) || project.revision != revision) {
        return;
      }
      status =
          startupProjectPath != null || startupError != null
              ? 'Otevření při startu selhalo${startupProjectPath == null ? '' : ': $startupProjectPath'}: $error'
              : 'Pracovní kopii se nepodařilo obnovit: $error';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> setAppearance(EcadAppearance value) async {
    appearance = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('open_ecad.appearance', value.name);
    } catch (_) {
      /* A theme change is usable even if preferences are unavailable. */
    }
  }

  void setPanel(SidePanel panel) {
    sidePanel = panel;
    notifyListeners();
  }

  void select(Set<String> ids) {
    selectedIds = {...ids};
    notifyListeners();
  }

  void selectAll() => select({
    ...sheet.devices.map((d) => d.id),
    ...sheet.graphics.map((g) => g.id),
    ...sheet.continuations.map((m) => m.id),
    ...sheet.corners.map((c) => c.id),
    ...?activeLayout?.placements.map((p) => p.id),
  });
  void setMode(CanvasMode value, {DeviceKind? kind}) {
    cancelClipboardPreview();
    if (value == CanvasMode.place && kind == DeviceKind.earth) {
      setContinuationTool(glyph: ContinuationGlyph.earth, label: 'PE');
      return;
    }
    showingProposal = false;
    mode = value;
    placingKind = kind;
    if (value != CanvasMode.continuation) {
      placingContinuationLinkId = null;
      placingContinuationGlyph = ContinuationGlyph.arrow;
      placingContinuationLabel = '';
    }
    status = switch (value) {
      CanvasMode.select => 'Výběr · Shift přidá do výběru',
      CanvasMode.corner =>
        'Spojovací roh ${cornerOrientation.glyph} · klikněte do mřížky; orientaci změníte nástrojem Otočit',
      CanvasMode.wire => 'Vodič · klikněte na dva připojovací body',
      CanvasMode.continuation =>
        'Pokračovací odkaz · klikněte na místo ve výkrese',
      CanvasMode.pan => 'Posun · táhněte výkresem',
      CanvasMode.place =>
        '${SymbolCatalog.definitionFor(kind!).label} · klikněte do výkresu',
      CanvasMode.drawLine => 'Čára · tažením určete oba konce',
      CanvasMode.drawRectangle => 'Obdélník · tažením určete velikost',
      CanvasMode.drawText => 'Text · klikněte do výkresu a upravte vlastnosti',
    };
    notifyListeners();
  }

  /// A pending proposal survives; only [discardProposal] drops it.
  void cancelTool() => setMode(CanvasMode.select);

  void setContinuationTool({
    String? linkId,
    ContinuationGlyph glyph = ContinuationGlyph.arrow,
    String label = '',
  }) {
    if (linkId != null && project.continuationLinkById(linkId) == null) return;
    placingContinuationLinkId = linkId;
    placingContinuationGlyph = glyph;
    placingContinuationLabel = label;
    setMode(CanvasMode.continuation);
  }

  void reportStatus(String message) {
    if (_disposed) return;
    status = message;
    notifyListeners();
  }

  void toggleGrid() {
    showGrid = !showGrid;
    notifyListeners();
  }

  void setSheet(String id, {bool fitViewport = true}) {
    cancelClipboardPreview();
    if (activeSheetId == id) return;
    if (busy) {
      conversation.add(
        const ConversationEntry(
          'Požadavek byl zrušen přepnutím listu. Zadejte ho znovu.',
          detail: 'Návrh nebyl použit',
        ),
      );
    }
    _requestId++;
    busy = false;
    proposal = null;
    _proposalPreview = null;
    showingProposal = false;
    activeSheetId = id;
    terminalStripId = null;
    selectedIds = {};
    mode = CanvasMode.select;
    placingKind = null;
    placingContinuationLinkId = null;
    placingContinuationGlyph = ContinuationGlyph.arrow;
    placingContinuationLabel = '';
    notifyListeners();
    if (fitViewport) viewport.fit();
  }

  bool execute(
    List<EcadCommand> commands,
    String label, {
    int? expectedRevision,
  }) {
    if (_disposed) return false;
    if (showingProposal && !_applyingProposal) {
      status = 'Nejprve zavřete náhled nebo použijte navržené změny';
      notifyListeners();
      return false;
    }
    try {
      _engine.execute(
        commands,
        label: label,
        expectedRevision: expectedRevision,
      );
      status = label;
      _changed();
      return true;
    } catch (error) {
      status =
          error is EcadException
              ? diagnosticCodeText(error.code, error.message)
              : error.toString();
      notifyListeners();
      return false;
    }
  }

  void _changed() {
    cancelClipboardPreview();
    showingProposal = false;
    if (!project.pages.any((p) => p.id == activeSheetId)) {
      activeSheetId = project.pages.first.id;
    }
    selectedIds = selectedIds.intersection({
      ...sheet.devices.map((d) => d.id),
      ...sheet.graphics.map((g) => g.id),
      ...sheet.continuations.map((m) => m.id),
      ...sheet.corners.map((c) => c.id),
      ...?activeLayout?.placements.map((p) => p.id),
    });
    diagnostics = [];
    diagnosticsVisible = false;
    _scheduleAutosave();
    notifyListeners();
  }

  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    autosaveStatus = 'Ukládání pracovní kopie…';
    _autosaveTimer = Timer(const Duration(milliseconds: 400), _autosave);
  }

  Future<void> _autosave() async {
    final snapshot = project;
    final generation = _documentGeneration;
    var message = 'Pracovní kopie uložena místně';
    try {
      await persistence.saveWorkingCopy(_session.workingCopy);
    } on AutosaveTooLargeException {
      message = 'Velký projekt · ukládejte do souboru';
    } catch (_) {
      message = 'Automatické uložení selhalo — uložte soubor';
    }
    if (!_isCurrentDocument(generation) ||
        snapshot.revision != project.revision) {
      return;
    }
    autosaveStatus = message;
    notifyListeners();
  }

  void undo() {
    cancelClipboardPreview(notify: true);
    if (showingProposal) return;
    if (_engine.undo()) {
      status = 'Změna vrácena';
      _changed();
    }
  }

  void redo() {
    cancelClipboardPreview(notify: true);
    if (showingProposal) return;
    if (_engine.redo()) {
      status = 'Změna obnovena';
      _changed();
    }
  }

  bool undoSteps(int count, {required int expectedRevision}) =>
      _historySteps(count, expectedRevision: expectedRevision, redo: false);

  bool redoSteps(int count, {required int expectedRevision}) =>
      _historySteps(count, expectedRevision: expectedRevision, redo: true);

  bool _historySteps(
    int count, {
    required int expectedRevision,
    required bool redo,
  }) {
    if (_disposed || showingProposal) return false;
    cancelClipboardPreview();
    try {
      if (redo) {
        _engine.redoSteps(count, expectedRevision: expectedRevision);
      } else {
        _engine.undoSteps(count, expectedRevision: expectedRevision);
      }
      status = '${redo ? 'Obnoveno' : 'Vráceno'} kroků: $count';
      _changed();
      return true;
    } on EcadException catch (error) {
      reportStatus(
        error.code == 'invalid_history_count'
            ? 'Počet kroků neodpovídá dostupné historii.'
            : diagnosticCodeText(error.code, error.message),
      );
      return false;
    }
  }

  void moveDevices(Map<String, Vec2> positions) =>
      execute([MoveDevices(activeSheetId, positions)], 'Přesunutí přístrojů');

  void moveSelection({
    required Map<String, Vec2> devices,
    required Map<String, Vec2> graphics,
    Map<String, Vec2> markers = const {},
    Map<String, Vec2> corners = const {},
  }) {
    final original = sheet;
    final beforeDevices = {for (final d in original.devices) d.id: d};
    if (devices.keys.any((id) => !beforeDevices.containsKey(id))) {
      execute([MoveDevices(original.id, devices)], 'Přesunutí výběru');
      return;
    }
    final afterDevices = {
      for (final d in original.devices)
        d.id:
            devices.containsKey(d.id) ? d.copyWith(position: devices[d.id]) : d,
    };
    final beforeMarkers = {for (final m in original.continuations) m.id: m};
    final afterMarkers = {
      for (final m in original.continuations)
        m.id:
            markers.containsKey(m.id) ? m.copyWith(position: markers[m.id]) : m,
    };
    final beforeCorners = {for (final c in original.corners) c.id: c};
    final afterCorners = {
      for (final c in original.corners)
        c.id:
            corners.containsKey(c.id) ? c.copyWith(position: corners[c.id]) : c,
    };
    final commands = <EcadCommand>[
      if (devices.isNotEmpty || markers.isNotEmpty || corners.isNotEmpty)
        UpdateSheet(
          original.copyWith(
            devices: afterDevices.values.toList(),
            continuations: afterMarkers.values.toList(),
            corners: afterCorners.values.toList(),
            wires: [
              // A group drag must follow both ends in the same geometry step.
              for (final wire in original.wires)
                WireRouter.follow(
                  wire,
                  beforeDevices,
                  afterDevices,
                  beforeMarkers: beforeMarkers,
                  afterMarkers: afterMarkers,
                  beforeCorners: beforeCorners,
                  afterCorners: afterCorners,
                ),
            ],
          ),
        ),
      if (graphics.isNotEmpty) MoveGraphics(original.id, graphics),
    ];
    if (commands.isNotEmpty) execute(commands, 'Přesunutí výběru');
  }

  void createGraphic(DrawingElement graphic) {
    if (execute([
      AddGraphics(activeSheetId, [graphic]),
    ], 'Grafika vložena')) {
      selectedIds = {graphic.id};
      sidePanel = SidePanel.properties;
      setMode(CanvasMode.select);
    }
  }

  bool updateGraphic(DrawingElement graphic) => execute([
    UpdateGraphic(activeSheetId, graphic),
  ], 'Vlastnosti grafiky upraveny');

  void placeDevice(DeviceKind kind, Vec2 position) {
    final definition = SymbolCatalog.definitionFor(kind);
    if (kind == DeviceKind.earth) {
      setContinuationTool(glyph: ContinuationGlyph.earth, label: 'PE');
      return;
    }
    if (kind == DeviceKind.terminal) {
      placeTerminal(position);
      return;
    }
    final seed = createBuiltinComponent(
      componentId: newId('component'),
      deviceId: newId('device'),
      kind: kind,
      designation:
          '-${nextLocalDesignation(project, sheet.structure, definition.prefix)}',
      position: position,
    );
    if (execute([
      AddComponent(
        seed.component.copyWith(
          designation: null,
          reference: ComponentReference(
            context: sheet.structure,
            localDesignation: seed.component.designation!,
          ),
        ),
      ),
      AddDevice(activeSheetId, seed.device),
    ], 'Vložen ${definition.label.toLowerCase()}')) {
      selectedIds = {seed.device.id};
      sidePanel = SidePanel.properties;
      notifyListeners();
    }
  }

  void setCornerTool(CornerOrientation orientation) {
    cornerOrientation = orientation;
    setMode(CanvasMode.corner);
  }

  void setTerminalTool(Set<PortSide> sides, {String? stripId}) {
    terminalSides = Set.unmodifiable(sides);
    terminalStripId = stripId;
    setMode(CanvasMode.place, kind: DeviceKind.terminal);
  }

  void placeTerminal(Vec2 position) {
    var strip = project.terminalStripById(terminalStripId ?? '');
    strip ??=
        project.terminalStrips
            .where((s) => s.reference.context == sheet.structure)
            .firstOrNull;
    final creatingStrip = strip == null;
    strip ??= TerminalStrip(
      id: newId('strip'),
      reference: ComponentReference(
        context: sheet.structure,
        localDesignation: nextLocalDesignation(project, sheet.structure, 'X'),
      ),
    );
    final seed = createTerminalComponent(
      componentId: newId('component'),
      deviceId: newId('device'),
      stripId: strip.id,
      number: nextTerminalNumber(project, strip),
      position: position,
      sides: terminalSides,
    );
    if (execute([
      if (creatingStrip) AddTerminalStrip(strip),
      AddComponent(seed.component),
      AddDevice(sheet.id, seed.device),
    ], 'Svorka vložena')) {
      terminalStripId = strip.id;
      selectedIds = {seed.device.id};
      sidePanel = SidePanel.properties;
      notifyListeners();
    }
  }

  void placeCorner(Vec2 position) {
    final corner = ConnectionCorner(
      id: newId('corner'),
      position: position.snapped(SchematicCanvas.gridSpacing),
      orientation: cornerOrientation,
    );
    if (execute([
      AddConnectionCorner(sheet.id, corner),
    ], 'Spojovací roh vložen')) {
      selectedIds = {corner.id};
      notifyListeners();
    }
  }

  void connect(WireEndpoint from, WireEndpoint to) {
    if (sheet.wires.any(
      (w) => (w.from == from && w.to == to) || (w.from == to && w.to == from),
    )) {
      status = 'Tyto body již spojuje vodič';
      notifyListeners();
      return;
    }
    execute([
      AddWire(activeSheetId, Wire(id: newId('wire'), from: from, to: to)),
    ], 'Připojen vodič');
  }

  void deleteWire(String id) {
    if (!sheet.wires.any((w) => w.id == id)) {
      status =
          'Automatický spoj zanikne přesunutím nebo otočením připojeného prvku';
      notifyListeners();
      return;
    }
    execute([DeleteWire(activeSheetId, id)], 'Vodič odstraněn');
  }

  void deleteSelection() {
    final devices = selectedDevices.map((d) => d.id).toSet();
    final graphics = selectedGraphics.map((g) => g.id).toSet();
    final commands = <EcadCommand>[
      for (final c in sheet.corners.where((c) => selectedIds.contains(c.id)))
        DeleteConnectionCorner(sheet.id, c.id),
      for (final marker in selectedMarkers)
        DeleteContinuationMarker(sheet.id, marker.id),
      if (selectedPlacements.isNotEmpty)
        UpdateMountingLayout(
          activeLayout!.copyWith(
            placements:
                activeLayout!.placements
                    .where((p) => !selectedIds.contains(p.id))
                    .toList(),
          ),
        ),
      if (devices.isNotEmpty) DeleteDevices(activeSheetId, devices),
      if (graphics.isNotEmpty) DeleteGraphics(activeSheetId, graphics),
    ];
    if (commands.isNotEmpty) execute(commands, 'Výběr odstraněn');
  }

  void rotateSelection() {
    if (mode == CanvasMode.corner) {
      setCornerTool(cornerOrientation.rotated);
      return;
    }
    final commands = <EcadCommand>[
      for (final c in sheet.corners.where((c) => selectedIds.contains(c.id)))
        UpdateConnectionCorner(
          sheet.id,
          c.copyWith(orientation: c.orientation.rotated),
        ),
      if (selectedPlacements.isNotEmpty)
        UpdateMountingLayout(
          activeLayout!.copyWith(
            placements: [
              for (final p in activeLayout!.placements)
                selectedIds.contains(p.id)
                    ? p.copyWith(rotation: (p.rotation + 90) % 360)
                    : p,
            ],
          ),
        ),
      if (selectedDevices.isNotEmpty)
        UpdateDevices(
          activeSheetId,
          selectedDevices
              .map((d) => d.copyWith(rotation: (d.rotation + 90) % 360))
              .toList(),
        ),
      if (selectedGraphics.isNotEmpty)
        UpdateGraphics(
          activeSheetId,
          selectedGraphics
              .map((g) => g.copyWith(rotation: (g.rotation + 90) % 360))
              .toList(),
        ),
    ];
    if (commands.isNotEmpty) execute(commands, 'Výběr otočen o 90°');
  }

  bool updateDevice(Device device, {String? sheetId}) => execute([
    UpdateDevice(sheetId ?? activeSheetId, device),
  ], 'Vlastnosti přístroje upraveny');

  bool setMainFunction(String sheetId, String deviceId) => execute([
    SetMainFunction(sheetId, deviceId),
  ], 'Hlavní funkce přístroje změněna');

  void navigateToDevice(String sheetId, String deviceId) {
    if (showingProposal || viewport.hasActiveGesture) return;
    final destination = project.sheetById(sheetId)?.deviceById(deviceId);
    if (destination == null) return;
    final generation = documentGeneration;
    final revision = project.revision;
    final zoom = viewport.zoom;
    setSheet(sheetId, fitViewport: false);
    select({deviceId});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed ||
          !isDocumentCurrent(generation) ||
          project.revision != revision ||
          activeSheetId != sheetId ||
          selectedIds.length != 1 ||
          !selectedIds.contains(deviceId)) {
        return;
      }
      if (viewport.revealDevice(
        documentIdentity: this,
        sheetId: sheetId,
        deviceId: deviceId,
        zoom: zoom,
      )) {
        reportStatus(
          'Cíl ${fullPageDesignation(sheet)} · ${resolver.fullDesignation(componentFor(destination))} · X ${destination.position.x} / Y ${destination.position.y}',
        );
      }
    });
  }

  void renameProject(String name) {
    if (name.trim().isNotEmpty) {
      execute([RenameProject(name.trim())], 'Projekt přejmenován');
    }
  }

  void renameSheet(String name, {String? sheetId}) {
    if (name.trim().isNotEmpty) {
      execute([
        RenameSheet(sheetId ?? activeSheetId, name.trim()),
      ], 'List přejmenován');
    }
  }

  void setSheetType(SheetType type) {
    if (sheet.type == type) return;
    execute([
      UpdateSheet(
        sheet.copyWith(
          type: type,
          report:
              type == SheetType.billOfMaterials
                  ? const BomTableSpec(kind: BomReportKind.articles)
                  : null,
        ),
      ),
    ], 'Typ listu: ${type.label}');
  }

  void addSheet({
    SheetType type = SheetType.multiLine,
    String? name,
    bool formStarter = false,
  }) {
    var page = Sheet(
      id: newId('sheet'),
      name:
          name == null || name.trim().isEmpty
              ? defaultSheetName(type)
              : name.trim(),
      number: nextSheetNumber(),
      structure: sheet.structure,
      documentCode: sheet.documentCode,
      type: type,
      report:
          type == SheetType.billOfMaterials
              ? const BomTableSpec(kind: BomReportKind.articles)
              : null,
    );
    if (formStarter && type == SheetType.form) {
      page = page.copyWith(
        graphics: SheetTemplates.blankForm(
          contentBounds: frameContentUnits(
            page,
            layoutFrameGeometry(
              page.paperSizeMm,
              resolveSheetFrame(project, page),
            ),
          ),
        ),
      );
    }
    if (execute([AddSheet(page)], 'Přidán nový list · ${type.label}')) {
      setSheet(page.id);
    }
  }

  final String _clipboardInstanceId = newId('clipboard-owner');
  int _clipboardRequest = 0;
  ClipboardPlacement? _pastePreview;
  bool Function()? _pasteCurrent;
  ClipboardPlacement? get pastePreview =>
      (_pasteCurrent?.call() ?? false) ? _pastePreview : null;

  void cancelClipboardPreview({bool notify = false}) {
    _clipboardRequest++;
    _pastePreview = null;
    _pasteCurrent = null;
    if (notify && !_disposed) notifyListeners();
  }

  Future<void> copySelectionToClipboard({bool Function()? isActive}) async {
    if (showingProposal ||
        ioBusy ||
        mode != CanvasMode.select ||
        viewport.hasActiveGesture ||
        pastePreview != null) {
      return;
    }
    final generation = documentGeneration, revision = project.revision;
    final sheetId = activeSheetId;
    bool current() =>
        isDocumentCurrent(generation) &&
        project.revision == revision &&
        activeSheetId == sheetId &&
        (isActive?.call() ?? true);
    try {
      final fragment = SchematicFragment.capture(
        project: project,
        sheet: sheet,
        selectedIds: selectedIds,
        sessionId: documentSessionId,
        instanceId: _clipboardInstanceId,
        generation: generation,
      );
      await Clipboard.setData(ClipboardData(text: fragment.encode()));
      if (current()) {
        reportStatus('Výběr zkopírován do schránky');
      }
    } catch (error) {
      if (current()) {
        reportStatus('Kopírování selhalo: ${_clipboardError(error)}');
      }
    }
  }

  Future<void> beginClipboardPaste({bool Function()? isActive}) async {
    if (showingProposal ||
        ioBusy ||
        mode != CanvasMode.select ||
        viewport.hasActiveGesture) {
      return;
    }
    cancelClipboardPreview();
    final request = _clipboardRequest;
    final generation = documentGeneration, revision = project.revision;
    final sessionId = documentSessionId, sheetId = activeSheetId;
    bool current() =>
        request == _clipboardRequest &&
        isDocumentCurrent(generation) &&
        documentSessionId == sessionId &&
        project.revision == revision &&
        activeSheetId == sheetId &&
        !showingProposal &&
        !ioBusy &&
        mode == CanvasMode.select &&
        (isActive?.call() ?? true);
    notifyListeners();
    try {
      final content = await Clipboard.getData(Clipboard.kTextPlain);
      if (!current() || viewport.hasActiveGesture) return;
      final fragment = SchematicFragment.decode(content?.text ?? '');
      final placement = fragment.prepare(
        project: project,
        target: sheet,
        sessionId: sessionId,
        instanceId: _clipboardInstanceId,
        generation: generation,
      );
      if (!current()) return;
      _pasteCurrent = current;
      _pastePreview = placement;
      reportStatus('Vložit výběr · pohybem určete polohu, kliknutím vložte');
    } catch (error) {
      if (current()) reportStatus('Vložení selhalo: ${_clipboardError(error)}');
    }
  }

  void placeClipboard(Vec2 position) {
    final placement = pastePreview;
    if (placement == null) {
      cancelClipboardPreview(notify: true);
      return;
    }
    final revision = project.revision;
    try {
      final commands = placement.commandsAt(position);
      cancelClipboardPreview();
      if (execute(
        commands,
        'Vložení ze schránky',
        expectedRevision: revision,
      )) {
        select(placement.selectedIds);
      }
    } catch (error) {
      cancelClipboardPreview();
      reportStatus('Vložení selhalo: ${_clipboardError(error)}');
    }
  }

  String _clipboardError(Object error) => switch (error) {
    FormatException e => e.message,
    EcadException e => e.message,
    _ => 'Systémová schránka není dostupná.',
  };

  void duplicateSelection() {
    if (selectedDevices.isEmpty && selectedGraphics.isEmpty) return;
    final List<EcadCommand> commands;
    try {
      commands = assistant.duplicateCommands(
        project: project,
        sheetId: activeSheetId,
        deviceIds: selectedDevices.map((d) => d.id).toSet(),
        graphicIds: selectedGraphics.map((g) => g.id).toSet(),
      );
    } on FormatException catch (error) {
      status = error.message;
      notifyListeners();
      return;
    }
    execute(commands, 'Výběr duplikován');
  }

  ProjectResolver get resolver => ProjectResolver(project);
  EcadProject? _bomSnapshot;
  BomProjection? _bom;
  BomProjection get bom {
    if (!identical(_bomSnapshot, project)) {
      _bomSnapshot = project;
      _bom = buildBom(project);
    }
    return _bom!;
  }

  Component componentFor(Device device) =>
      project.componentById(device.componentId)!;
  MountingLayout? get activeLayout =>
      sheet.mountingView == null
          ? null
          : project.mountingLayoutById(sheet.mountingView!.layoutId);
  List<MountingPlacement> get selectedPlacements =>
      activeLayout?.placements
          .where((p) => selectedIds.contains(p.id))
          .toList() ??
      [];
  List<ContinuationMarker> get selectedMarkers =>
      sheet.continuations.where((m) => selectedIds.contains(m.id)).toList();

  String nextSheetNumber() => nextPageNumber(project, sheet);

  bool saveArticle(Article article) => execute([
    if (project.articleById(article.id) == null)
      AddArticle(article)
    else
      UpdateArticle(article),
  ], 'Artikl uložen');
  bool saveComponent(Component component) => execute([
    if (project.componentById(component.id) == null)
      AddComponent(component)
    else
      UpdateComponent(component),
  ], 'Komponenta uložena');

  Component? duplicateInventoryComponent(Component source) {
    final terminals = {
      for (final t in source.electrical?.terminals ?? <ComponentTerminal>[])
        t.id: newId('terminal'),
    };
    final electrical = source.electrical;
    final prefix =
        RegExp(r'^[A-Za-z]+')
            .firstMatch(
              source.reference?.localDesignation ??
                  (source.designation ?? 'A').replaceFirst(RegExp(r'^-'), ''),
            )
            ?.group(0) ??
        'A';
    TerminalStrip? strip;
    var creatingStrip = false;
    TerminalAssignment? terminal;
    if (source.terminal != null) {
      strip =
          project.terminalStrips
              .where((s) => s.reference.context == sheet.structure)
              .firstOrNull;
      creatingStrip = strip == null;
      strip ??= TerminalStrip(
        id: newId('strip'),
        reference: ComponentReference(
          context: sheet.structure,
          localDesignation: nextLocalDesignation(project, sheet.structure, 'X'),
        ),
      );
      terminal = source.terminal!.copyWith(
        stripId: strip.id,
        number: nextTerminalNumber(project, strip),
      );
    }
    final copy = source.copyWith(
      id: newId('component'),
      designation: null,
      reference:
          terminal == null && source.designation != null
              ? ComponentReference(
                context: sheet.structure,
                localDesignation: nextLocalDesignation(
                  project,
                  sheet.structure,
                  prefix,
                ),
              )
              : null,
      terminal: terminal,
      electrical:
          electrical == null
              ? null
              : ElectricalModel(
                terminals: [
                  for (final t in electrical.terminals)
                    t.copyWith(id: terminals[t.id]),
                ],
                functions: [
                  for (final f in electrical.functions)
                    f.copyWith(
                      id: newId('function'),
                      terminalIds:
                          f.terminalIds.map((id) => terminals[id]!).toList(),
                    ),
                ],
              ),
    );
    return execute([
          if (creatingStrip) AddTerminalStrip(strip!),
          AddComponent(copy),
        ], 'Nový skutečný kus vytvořen')
        ? copy
        : null;
  }

  bool updateSheet(Sheet value) =>
      execute([UpdateSheet(value)], 'Vlastnosti listu uloženy');

  bool renameStructureBranch(
    StructureAspect aspect,
    List<String> prefix,
    List<String> replacement,
  ) => execute([
    RenameStructureBranch(aspect, prefix, replacement),
  ], 'Větev struktury přejmenována');

  void deleteSheet() =>
      execute([DeleteSheet(sheet.id)], 'List odstraněn; komponenty zůstávají');
  void reorderSheet(int delta) {
    final ids = project.pages.map((s) => s.id).toList();
    final index = ids.indexOf(sheet.id);
    final next = index + delta;
    if (next < 0 || next >= ids.length) return;
    ids.removeAt(index);
    ids.insert(next, sheet.id);
    execute([ReorderSheets(ids)], 'Pořadí listů změněno');
  }

  bool addOccurrence(
    Component component, {
    String? functionId,
    DeviceKind? kind,
    Vec2? position,
    OccurrenceMode mode = OccurrenceMode.wiring,
    String? sheetId,
  }) {
    final sheet = project.sheetById(sheetId ?? activeSheetId);
    final currentComponent = project.componentById(component.id);
    if (sheet == null || currentComponent == null) return false;
    component = currentComponent;
    if (component.terminal != null) {
      if (kind != null && kind != DeviceKind.terminal) {
        status =
            'Průchozí svorka má jednu vodivou funkci. Použijte její kruhové zobrazení.';
        notifyListeners();
        return false;
      }
      functionId ??= component.electrical!.functions.first.id;
      kind = DeviceKind.terminal;
      if (project.pages.any(
        (s) => s.devices.any(
          (d) =>
              d.componentId == component.id &&
              d.functionId == functionId &&
              d.mode == OccurrenceMode.wiring,
        ),
      )) {
        mode = OccurrenceMode.reference;
      }
    }
    if (kind == DeviceKind.terminal && component.terminal == null) {
      status =
          'Průchozí svorku vložte nástrojem Svorka. Existující blok nemění svou elektrickou funkci automaticky.';
      notifyListeners();
      return false;
    }
    final electrical = component.electrical ?? ElectricalModel();
    final commands = <EcadCommand>[];
    SymbolSpec symbol;
    if (functionId == null) {
      if (kind == null) {
        final function = ComponentFunction(
          id: newId('function'),
          name: 'Obecný blok',
        );
        functionId = function.id;
        commands.add(
          UpdateComponent(
            component.copyWith(
              electrical: electrical.copyWith(
                functions: [...electrical.functions, function],
              ),
            ),
          ),
        );
        symbol = PortBlockSpec(width: 160, height: 120);
      } else {
        final seed = createBuiltinComponent(
          componentId: component.id,
          deviceId: newId('device'),
          kind: kind,
          designation: component.designation!,
          position: position ?? Vec2.zero,
        );
        functionId = seed.device.functionId;
        final occupied =
            electrical.terminals
                .map((t) => referenceKey(t.designation))
                .toSet();
        final terminals =
            seed.component.electrical!.terminals.map((t) {
              var label = t.designation;
              for (var n = 2; occupied.contains(referenceKey(label)); n++) {
                label = '${t.designation}.$n';
              }
              occupied.add(referenceKey(label));
              return t.copyWith(designation: label);
            }).toList();
        commands.add(
          UpdateComponent(
            component.copyWith(
              electrical: electrical.copyWith(
                terminals: [...electrical.terminals, ...terminals],
                functions: [
                  ...electrical.functions,
                  ...seed.component.electrical!.functions,
                ],
              ),
            ),
          ),
        );
        symbol = seed.device.symbol;
      }
    } else {
      final function = electrical.functionById(functionId);
      if (function == null) {
        status = 'Původní elektrická funkce již neexistuje.';
        notifyListeners();
        return false;
      }
      if (kind == DeviceKind.terminal) {
        if (function.terminalIds.length != 1) return false;
        symbol = TerminalSymbolSpec(
          terminalId: function.terminalIds.single,
          sides: terminalSides,
        );
      } else if (kind == null) {
        symbol = PortBlockSpec(
          width: 160,
          height: (function.terminalIds.length * 28.0 + 28).clamp(120, 1200),
          ports: [
            for (final (i, id) in function.terminalIds.indexed)
              BlockPort(
                id: newId('port'),
                terminalId: id,
                side: PortSide.left,
                fraction: (i + 1) / (function.terminalIds.length + 1),
              ),
          ],
        );
      } else {
        final ports = SymbolCatalog.definitionFor(kind).ports;
        if (ports.length != function.terminalIds.length) {
          status =
              'Počet vývodů funkce neodpovídá značce. Použijte obecný blok nebo novou funkci.';
          notifyListeners();
          return false;
        }
        symbol = BuiltinSymbolSpec(
          kind: kind,
          bindings: {
            for (final (i, p) in ports.indexed) p.id: function.terminalIds[i],
          },
        );
      }
    }
    var device = Device(
      id: newId('device'),
      componentId: component.id,
      functionId: functionId,
      symbol: symbol,
      position: position ?? Vec2.zero,
      mode: mode,
    );
    if (position == null) {
      final size = geometryFor(device);
      Vec2? free;
      for (var y = 200.0; y < sheet.height - 130 && free == null; y += 180) {
        for (var x = 190.0; x < sheet.width - 190 && free == null; x += 300) {
          if (sheet.devices.every((d) {
            final other = geometryFor(d);
            return (d.position.x - x).abs() >
                    (size.width + other.width) / 2 + 80 ||
                (d.position.y - y).abs() >
                    (size.height + other.height) / 2 + 50;
          })) {
            free = Vec2(x, y);
          }
        }
      }
      if (free == null) {
        status =
            'Na listu není dost volného místa. Přesuňte zobrazení nebo přidejte list.';
        notifyListeners();
        return false;
      }
      device = device.copyWith(position: free);
    }
    if (!execute([
      ...commands,
      AddDevice(sheet.id, device),
    ], 'Další zobrazení komponenty vloženo')) {
      return false;
    }
    if (sheet.id == activeSheetId) {
      select({device.id});
      setPanel(SidePanel.properties);
    }
    return true;
  }

  bool addContinuation({
    required Vec2 position,
    required String label,
    String? linkId,
    ContinuationGlyph glyph = ContinuationGlyph.arrow,
    PortSide direction = PortSide.left,
  }) {
    final marker = ContinuationMarker(
      id: newId('marker'),
      linkId: linkId ?? newId('link'),
      position: position,
      glyph: glyph,
      direction: direction,
    );
    try {
      if (!execute(
        continuationEditCommands(
          project,
          sheetId: sheet.id,
          marker: marker,
          isNewMarker: true,
          label: label,
          createLink: linkId == null,
        ),
        'Pokračování vloženo',
      )) {
        return false;
      }
    } on EcadException catch (error) {
      reportStatus(diagnosticCodeText(error.code, error.message));
      return false;
    }
    select({marker.id});
    return true;
  }

  bool configureMounting({
    MountingLayout? layout,
    required double width,
    required double height,
    required double scale,
    Vec2 origin = Vec2.zero,
    RectUnits? viewport,
    bool surfaceDimensions = true,
    bool componentDimensions = false,
  }) {
    final next =
        layout?.copyWith(widthMm: width, heightMm: height) ??
        MountingLayout(
          id: newId('layout'),
          name: sheet.name,
          widthMm: width,
          heightMm: height,
        );
    return execute([
      if (layout == null)
        AddMountingLayout(next)
      else
        UpdateMountingLayout(next),
      UpdateSheet(
        sheet.copyWith(
          mountingView: MountingView(
            layoutId: next.id,
            originMm: origin,
            viewport:
                viewport ??
                sheet.mountingView?.viewport ??
                defaultMountingViewport(
                  project,
                  sheet,
                  surfaceDimensions: surfaceDimensions,
                ),
            scaleDenominator: scale,
            showSurfaceDimensions: surfaceDimensions,
            showComponentDimensions: componentDimensions,
          ),
        ),
      ),
    ], 'Montážní pohled uložen');
  }

  bool placeComponent(String componentId, Vec2 centerMm) {
    final layout = activeLayout;
    if (layout == null) return false;
    final placement = MountingPlacement(
      id: newId('placement'),
      componentId: componentId,
      centerMm: centerMm,
    );
    if (!execute([
      UpdateMountingLayout(
        layout.copyWith(placements: [...layout.placements, placement]),
      ),
    ], 'Komponenta umístěna v mm')) {
      return false;
    }
    select({placement.id});
    setPanel(SidePanel.properties);
    return true;
  }

  bool updatePlacement(MountingPlacement placement) {
    final layout = activeLayout;
    if (layout == null) return false;
    return execute([
      UpdateMountingLayout(
        layout.copyWith(
          placements: [
            for (final p in layout.placements)
              p.id == placement.id ? placement : p,
          ],
        ),
      ),
    ], 'Montážní poloha upravena');
  }

  void _resetDocumentView() {
    cancelClipboardPreview();
    _autosaveTimer?.cancel();
    _requestId++;
    activeSheetId = project.pages.first.id;
    terminalStripId = null;
    selectedIds = {};
    showGrid = project.pages.first.sourcePage == null;
    mode = CanvasMode.select;
    placingKind = null;
    proposal = null;
    placingContinuationLinkId = null;
    placingContinuationGlyph = ContinuationGlyph.arrow;
    placingContinuationLabel = '';
    _proposalPreview = null;
    showingProposal = false;
    conversation.clear();
    diagnostics = [];
    diagnosticsVisible = false;
    busy = false;
  }

  void newProject({bool demo = false}) {
    _session.replace(demo ? DemoProject.create() : _emptyProject());
    _resetDocumentView();
    status = demo ? 'Otevřen ukázkový projekt' : 'Vytvořen nový projekt';
    _changed();
    viewport.fit();
  }

  Future<bool> openProject({bool importPdf = false, String? path}) async {
    if (_disposed || ioBusy) return false;
    final generation = _documentGeneration;
    ioBusy = true;
    notifyListeners();
    try {
      final result = await _session.open(
        path: path,
        importProject: importPdf ? importer.importPdf : null,
      );
      if (result != DocumentIoResult.opened) {
        if (_isCurrentDocument(generation)) {
          status =
              result == DocumentIoResult.canceled
                  ? 'Otevření zrušeno'
                  : 'Otevření odloženo: projekt se během výběru souboru změnil';
        }
        return false;
      }
      if (!_isCurrentDocument(generation + 1)) return false;
      _resetDocumentView();
      if (importPdf && importer.warnings.isNotEmpty) {
        conversation.add(
          ConversationEntry(
            importer.warnings.join('\n\n'),
            detail: 'Zpráva o importu PDF',
          ),
        );
        sidePanel = SidePanel.assistant;
      }
      status =
          importPdf
              ? 'PDF převedeno · ${project.pages.length} listů · grafika bez elektrických vazeb'
              : 'Projekt otevřen';
      _changed();
      viewport.fit();
      return true;
    } catch (error) {
      if (_isCurrentDocument(generation)) status = 'Otevření selhalo: $error';
      return false;
    } finally {
      ioBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<bool> restoreWorkingCopy(String sessionId) async {
    if (_disposed || ioBusy) return false;
    final generation = _documentGeneration;
    ioBusy = true;
    notifyListeners();
    try {
      if (await _session.restore(recoveryId: sessionId) !=
          DocumentIoResult.restored) {
        return false;
      }
      if (!_isCurrentDocument(generation + 1)) return false;
      _resetDocumentView();
      status = 'Obnovena místní pracovní kopie';
      autosaveStatus = 'Obnoveno z tohoto zařízení';
      viewport.fit();
      return true;
    } catch (error) {
      if (_isCurrentDocument(generation)) status = 'Obnova selhala: $error';
      return false;
    } finally {
      ioBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<bool> saveProject() => _saveProject();

  Future<bool> saveProjectAs() => _saveProject(saveAs: true);

  Future<bool> _saveProject({bool saveAs = false}) async {
    if (_disposed || ioBusy) return false;
    final generation = _documentGeneration;
    ioBusy = true;
    notifyListeners();
    try {
      final result = await _session.save(saveAs: saveAs);
      if (!_isCurrentDocument(generation)) return false;
      if (result != DocumentIoResult.saved) {
        if (_isCurrentDocument(generation) &&
            result == DocumentIoResult.canceled) {
          status = 'Uložení zrušeno';
        }
        return false;
      }
      status =
          dirty
              ? 'Uložena dřívější verze; novější změny nejsou uložené'
              : 'Projekt uložen';
      // An immediate close must retain the file target and saved revision.
      _autosaveTimer?.cancel();
      autosaveStatus = 'Ukládání pracovní kopie…';
      await _autosave();
      return _isCurrentDocument(generation) && !dirty;
    } catch (error) {
      if (_isCurrentDocument(generation)) status = 'Uložení selhalo: $error';
      return false;
    } finally {
      ioBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> exportProject({required bool pdf}) async {
    if (_disposed || ioBusy) return;
    final generation = _documentGeneration;
    ioBusy = true;
    status = pdf ? 'Připravuji PDF…' : 'Připravuji SVG…';
    notifyListeners();
    try {
      final path =
          pdf
              ? await exporter.savePdf(project)
              : await exporter.saveSvg(project, sheetId: activeSheetId);
      if (_isCurrentDocument(generation)) {
        status =
            path == null
                ? 'Export zrušen'
                : '${pdf ? 'PDF' : 'SVG'} exportováno';
      }
    } catch (error) {
      if (_isCurrentDocument(generation)) {
        status = 'Export selhal: $error';
      }
    } finally {
      ioBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  void validate() {
    diagnostics = validateProject(project);
    diagnosticsVisible = true;
    status =
        diagnostics.isEmpty
            ? 'Struktura projektu je v pořádku'
            : 'Kontrola: ${_diagnosticCounts()}';
    notifyListeners();
  }

  void hideDiagnostics() {
    diagnosticsVisible = false;
    notifyListeners();
  }

  String _diagnosticCounts() {
    final errors =
        diagnostics.where((d) => d.severity == DiagnosticSeverity.error).length;
    final warnings =
        diagnostics
            .where((d) => d.severity == DiagnosticSeverity.warning)
            .length;
    final info =
        diagnostics.where((d) => d.severity == DiagnosticSeverity.info).length;
    return 'chyby $errors · upozornění $warnings${info == 0 ? '' : ' · informace $info'}';
  }

  String _validationMessage() {
    final lines = <String>['Kontrola dokončena: ${_diagnosticCounts()}.'];
    lines.addAll(
      diagnostics.take(6).map((d) => '• ${diagnosticText(project, d)}'),
    );
    if (diagnostics.length > 6) {
      lines.add(
        'Dalších ${diagnostics.length - 6} výsledků najdete v panelu kontroly.',
      );
    }
    lines.add(
      'Kontrola ověřuje strukturu a propojení dokumentu, nikoli elektrickou bezpečnost.',
    );
    return lines.join('\n');
  }

  bool _isCurrentDocument(int generation) =>
      !_disposed && generation == _documentGeneration;

  Future<void> configureAi(
    AiProviderSettings settings, {
    required bool enabled,
  }) async {
    settings.validate();
    aiSettings = settings;
    useOllama = enabled;
    notifyListeners();
    try {
      await persistence.saveAiSettings(settings);
    } catch (_) {
      status = 'Nastavení je aktivní pro tuto relaci';
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> sendPrompt(String input) async {
    final prompt = input.trim();
    if (prompt.isEmpty || busy) return;
    final request = ++_requestId;
    final requestSettings = aiSettings;
    conversation.add(ConversationEntry(prompt, isUser: true));
    proposal = null;
    _proposalPreview = null;
    showingProposal = false;
    busy = true;
    sidePanel = SidePanel.assistant;
    notifyListeners();
    try {
      final result =
          useOllama
              ? await assistant.proposeWithOllama(
                prompt,
                project: project,
                sheetId: activeSheetId,
                selectedDeviceIds: selectedDevices.map((d) => d.id).toSet(),
                settings: requestSettings,
              )
              : assistant.propose(
                prompt,
                project: project,
                sheetId: activeSheetId,
                selectedDeviceIds: selectedDevices.map((d) => d.id).toSet(),
              );
      if (_disposed || request != _requestId) return;
      if (result.baseRevision != project.revision) {
        conversation.add(
          const ConversationEntry(
            'Projekt se během přípravy změnil. Zadejte požadavek znovu nad aktuální verzí.',
            detail: 'Návrh nebyl použit',
          ),
        );
        status = 'Návrh odložen: projekt se mezitím změnil';
        return;
      }
      if (result.action == AssistantAction.undo) {
        undo();
      }
      if (result.action == AssistantAction.redo) {
        redo();
      }
      if (result.action == AssistantAction.validate) {
        validate();
        conversation.add(
          ConversationEntry(_validationMessage(), detail: 'Kontrola projektu'),
        );
        return;
      }
      proposal = result.commands.isNotEmpty ? result : null;
      _proposalPreview = proposalIsCurrent ? result.preview(project) : null;
      showingProposal = _proposalPreview != null;
      conversation.add(
        ConversationEntry(
          result.message,
          detail:
              result.source == AssistantSource.ollama
                  ? requestSettings.model
                  : 'Místní příkazy',
        ),
      );
      status =
          proposal == null
              ? 'Příkaz zpracován'
              : 'Návrh je připraven ke kontrole';
    } catch (error) {
      if (!_disposed && request == _requestId) {
        conversation.add(
          ConversationEntry(
            'Příkaz se nepodařilo zpracovat. $error',
            detail: assistantLabel,
          ),
        );
        status = 'Asistent: požadavek selhal';
      }
    } finally {
      if (!_disposed && request == _requestId) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void applyProposal() {
    final pending = proposal;
    if (pending == null) return;
    _applyingProposal = true;
    final applied = execute(
      pending.commands,
      pending.label,
      expectedRevision: pending.baseRevision,
    );
    _applyingProposal = false;
    if (applied) {
      conversation.add(
        ConversationEntry(
          'Hotovo. ${pending.label}. Celou změnu lze vrátit jedním krokem.',
          detail: 'Projekt aktualizován',
        ),
      );
      proposal = null;
      _proposalPreview = null;
      showingProposal = false;
      notifyListeners();
    }
  }

  void discardProposal() {
    proposal = null;
    _proposalPreview = null;
    showingProposal = false;
    status = 'Návrh odložen';
    notifyListeners();
  }

  void toggleProposalPreview() {
    if (!proposalIsCurrent) return;
    showingProposal = !showingProposal;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _session.dispose();
    _requestId++;
    _autosaveTimer?.cancel();
    viewport.dispose();
    super.dispose();
  }
}
