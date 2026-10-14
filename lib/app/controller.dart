import 'dart:async';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../editor/schematic_canvas.dart';
import '../services/ecad_services.dart';
import 'theme.dart';

enum SidePanel { assistant, properties }

String defaultSheetName(SheetType type) => switch (type) {
  SheetType.multiLine => 'Nové schéma',
  SheetType.singleLine => 'Nové jednopólové schéma',
  SheetType.cabinetLayout => 'Nová výstavba rozvaděče',
  SheetType.form => 'Nový formulář',
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
  }) : _engine = ProjectEngine(initialProject ?? DemoProject.create()),
       persistence = persistence ?? ProjectPersistence(),
       assistant = assistant ?? AssistantService() {
    activeSheetId = project.pages.first.id;
    _savedRevision = project.revision;
  }

  ProjectEngine _engine;
  final ProjectPersistence persistence;
  final AssistantService assistant;
  final ProjectExportService exporter = ProjectExportService();
  final SchematicViewportController viewport = SchematicViewportController();
  Timer? _autosaveTimer;
  bool _disposed = false;
  int _savedRevision = 0;
  int _requestId = 0;
  int _documentGeneration = 0;
  String activeSheetId = '';
  Set<String> selectedIds = {};
  EcadAppearance appearance = EcadAppearance.paper;
  CanvasMode mode = CanvasMode.select;
  DeviceKind? placingKind;
  bool showGrid = true;
  SidePanel sidePanel = SidePanel.assistant;
  bool busy = false;
  bool ioBusy = false;
  bool useOllama = false;
  String status = 'Připraveno';
  String? fileName;
  String autosaveStatus = 'Pracovní kopie se ukládá místně';
  AiProviderSettings aiSettings = const AiProviderSettings();
  AssistantProposal? proposal;
  EcadProject? _proposalPreview;
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
  Sheet get displaySheet =>
      showingProposal && proposalIsCurrent
          ? (_proposalPreview?.pages.firstWhere(
                (p) => p.id == activeSheetId,
                orElse: () => sheet,
              ) ??
              sheet)
          : sheet;
  bool get canUndo => _engine.canUndo;
  bool get canRedo => _engine.canRedo;
  bool get dirty => project.revision != _savedRevision;
  bool get proposalIsCurrent =>
      proposal != null && proposal!.baseRevision == project.revision;
  List<Device> get selectedDevices =>
      sheet.devices.where((d) => selectedIds.contains(d.id)).toList();
  List<DrawingElement> get selectedGraphics =>
      sheet.graphics.where((g) => selectedIds.contains(g.id)).toList();
  String get assistantLabel => useOllama ? aiSettings.model : 'Místní příkazy';

  Future<void> initialize() async {
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
      final restored = await persistence.loadAutosave();
      if (!_isCurrentDocument(generation) || project.revision != revision) {
        return;
      }
      if (restored != null && restored.project.pages.isNotEmpty) {
        final document = restored.project;
        _engine = ProjectEngine(document);
        _documentGeneration++;
        activeSheetId = document.pages.first.id;
        showGrid = document.pages.first.showFrame;
        _savedRevision = restored.savedRevision ?? -1;
        fileName = restored.fileName;
        status = 'Obnovena místní pracovní kopie';
        autosaveStatus = 'Obnoveno z tohoto zařízení';
      }
    } catch (error) {
      if (!_isCurrentDocument(generation) || project.revision != revision) {
        return;
      }
      status = 'Pracovní kopii se nepodařilo obnovit';
      autosaveStatus = error.toString();
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
  });
  void setMode(CanvasMode value, {DeviceKind? kind}) {
    showingProposal = false;
    mode = value;
    placingKind = kind;
    status = switch (value) {
      CanvasMode.select => 'Výběr · Shift přidá do výběru',
      CanvasMode.wire => 'Vodič · klikněte na dva připojovací body',
      CanvasMode.pan => 'Posun · táhněte výkresem',
      CanvasMode.place =>
        '${SymbolCatalog.definitionFor(kind!).label} · klikněte do výkresu, Esc ukončí vkládání',
      CanvasMode.drawLine => 'Čára · tažením určete oba konce',
      CanvasMode.drawRectangle => 'Obdélník · tažením určete velikost',
      CanvasMode.drawText => 'Text · klikněte do výkresu a upravte vlastnosti',
    };
    notifyListeners();
  }

  /// A pending proposal survives; only [discardProposal] drops it.
  void cancelTool() => setMode(CanvasMode.select);

  void toggleGrid() {
    showGrid = !showGrid;
    notifyListeners();
  }

  void setSheet(String id) {
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
    selectedIds = {};
    mode = CanvasMode.select;
    placingKind = null;
    notifyListeners();
    viewport.fit();
  }

  bool execute(
    List<EcadCommand> commands,
    String label, {
    int? expectedRevision,
  }) {
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
      status = error.toString();
      notifyListeners();
      return false;
    }
  }

  void _changed() {
    showingProposal = false;
    if (!project.pages.any((p) => p.id == activeSheetId)) {
      activeSheetId = project.pages.first.id;
    }
    selectedIds = selectedIds.intersection({
      ...sheet.devices.map((d) => d.id),
      ...sheet.graphics.map((g) => g.id),
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
    try {
      await persistence.saveAutosave(
        snapshot,
        savedRevision: _savedRevision < 0 ? null : _savedRevision,
        fileName: fileName,
      );
      if (!_isCurrentDocument(generation) ||
          snapshot.revision != project.revision) {
        return;
      }
      autosaveStatus = 'Pracovní kopie uložena místně';
    } on AutosaveTooLargeException {
      if (!_isCurrentDocument(generation) ||
          snapshot.revision != project.revision) {
        return;
      }
      autosaveStatus = 'Velký projekt · ukládejte do souboru';
    } catch (_) {
      if (!_isCurrentDocument(generation) ||
          snapshot.revision != project.revision) {
        return;
      }
      autosaveStatus = 'Automatické uložení selhalo — uložte soubor';
    }
    if (!_disposed) notifyListeners();
  }

  void undo() {
    if (showingProposal) return;
    if (_engine.undo()) {
      status = 'Změna vrácena';
      _changed();
    }
  }

  void redo() {
    if (showingProposal) return;
    if (_engine.redo()) {
      status = 'Změna obnovena';
      _changed();
    }
  }

  void moveDevices(Map<String, Vec2> positions) =>
      execute([MoveDevices(activeSheetId, positions)], 'Přesunutí přístrojů');

  void moveSelection({
    required Map<String, Vec2> devices,
    required Map<String, Vec2> graphics,
  }) {
    final commands = <EcadCommand>[
      if (devices.isNotEmpty) MoveDevices(activeSheetId, devices),
      if (graphics.isNotEmpty) MoveGraphics(activeSheetId, graphics),
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
    final device = Device(
      id: newId('device'),
      kind: kind,
      designation: SymbolCatalog.nextDesignation(
        project.pages.expand((page) => page.devices),
        kind,
      ),
      position: position,
    );
    if (execute([
      AddDevice(activeSheetId, device),
    ], 'Vložen ${definition.label.toLowerCase()}')) {
      selectedIds = {device.id};
      notifyListeners();
    }
  }

  void connect(TerminalRef from, TerminalRef to) => execute([
    AddWire(activeSheetId, Wire(id: newId('wire'), from: from, to: to)),
  ], 'Připojen vodič');
  void deleteWire(String id) =>
      execute([DeleteWire(activeSheetId, id)], 'Vodič odstraněn');
  void deleteSelection() {
    final devices = selectedDevices.map((d) => d.id).toSet();
    final graphics = selectedGraphics.map((g) => g.id).toSet();
    final commands = <EcadCommand>[
      if (devices.isNotEmpty) DeleteDevices(activeSheetId, devices),
      if (graphics.isNotEmpty) DeleteGraphics(activeSheetId, graphics),
    ];
    if (commands.isNotEmpty) execute(commands, 'Výběr odstraněn');
  }

  void rotateSelection() {
    final commands = <EcadCommand>[
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

  bool updateDevice(Device device) => execute([
    UpdateDevice(activeSheetId, device),
  ], 'Vlastnosti přístroje upraveny');
  void renameProject(String name) {
    if (name.trim().isNotEmpty) {
      execute([RenameProject(name.trim())], 'Projekt přejmenován');
    }
  }

  void renameSheet(String name) {
    if (name.trim().isNotEmpty) {
      execute([RenameSheet(activeSheetId, name.trim())], 'List přejmenován');
    }
  }

  void setSheetType(SheetType type) {
    if (sheet.type == type) return;
    execute([SetSheetType(activeSheetId, type)], 'Typ listu: ${type.label}');
  }

  void addSheet({
    SheetType type = SheetType.multiLine,
    String? name,
    bool formStarter = false,
  }) {
    final page = Sheet(
      id: newId('sheet'),
      name:
          name == null || name.trim().isEmpty
              ? defaultSheetName(type)
              : name.trim(),
      number: (project.pages.length + 1).toString().padLeft(2, '0'),
      type: type,
      graphics:
          formStarter && type == SheetType.form
              ? SheetTemplates.blankForm()
              : const [],
    );
    if (execute([AddSheet(page)], 'Přidán nový list · ${type.label}')) {
      setSheet(page.id);
    }
  }

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

  void newProject({bool demo = false}) {
    _documentGeneration++;
    _requestId++;
    _engine = ProjectEngine(
      demo
          ? DemoProject.create()
          : EcadProject(
            id: newId('project'),
            name: 'Nový projekt',
            pages: [
              Sheet(id: newId('sheet'), name: 'První schéma', number: '01'),
            ],
          ),
    );
    _savedRevision = -1;
    activeSheetId = project.pages.first.id;
    selectedIds = {};
    showGrid = true;
    mode = CanvasMode.select;
    placingKind = null;
    proposal = null;
    _proposalPreview = null;
    conversation.clear();
    fileName = null;
    busy = false;
    status = demo ? 'Otevřen ukázkový projekt' : 'Vytvořen nový projekt';
    _changed();
    viewport.fit();
  }

  Future<void> openProject({bool importPdf = false}) async {
    if (_disposed || ioBusy) return;
    final generation = _documentGeneration;
    final revision = project.revision;
    ioBusy = true;
    notifyListeners();
    try {
      final loaded =
          importPdf ? await persistence.importPdf() : await persistence.open();
      if (loaded == null || !_isCurrentDocument(generation)) return;
      if (project.revision != revision) {
        status = 'Otevření odloženo: projekt se během výběru souboru změnil';
        return;
      }
      final nextEngine = ProjectEngine(loaded);
      _documentGeneration++;
      _requestId++;
      _engine = nextEngine;
      activeSheetId = loaded.pages.first.id;
      _savedRevision = importPdf ? -1 : loaded.revision;
      selectedIds = {};
      mode = CanvasMode.select;
      placingKind = null;
      proposal = null;
      _proposalPreview = null;
      conversation.clear();
      busy = false;
      fileName = null;
      showGrid = loaded.pages.first.showFrame;
      if (importPdf && persistence.pdfImportWarnings.isNotEmpty) {
        conversation.add(
          ConversationEntry(
            persistence.pdfImportWarnings.join('\n\n'),
            detail: 'Zpráva o importu PDF',
          ),
        );
        sidePanel = SidePanel.assistant;
      }
      status =
          importPdf
              ? 'PDF převedeno · ${loaded.pages.length} listů · grafika bez elektrických vazeb'
              : 'Projekt otevřen';
      _changed();
      viewport.fit();
    } catch (error) {
      if (_isCurrentDocument(generation)) {
        status = 'Otevření selhalo: $error';
      }
    } finally {
      ioBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> saveProject() async {
    if (_disposed || ioBusy) return;
    final snapshot = project;
    final generation = _documentGeneration;
    ioBusy = true;
    notifyListeners();
    try {
      final path = await persistence.save(snapshot);
      if (path != null && _isCurrentDocument(generation)) {
        fileName = path;
        _savedRevision = snapshot.revision;
        status =
            project.revision == snapshot.revision
                ? 'Projekt uložen'
                : 'Uložena dřívější verze; novější změny nejsou uložené';
        // Complete the recovery record before returning: an immediate close
        // cancels timers and must not lose the saved revision or file name.
        _autosaveTimer?.cancel();
        autosaveStatus = 'Ukládání pracovní kopie…';
        await _autosave();
      }
    } catch (error) {
      if (_isCurrentDocument(generation)) {
        status = 'Uložení selhalo: $error';
      }
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
    lines.addAll(diagnostics.take(6).map((d) => '• ${d.message}'));
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
    _disposed = true;
    _requestId++;
    _autosaveTimer?.cancel();
    viewport.dispose();
    super.dispose();
  }
}
