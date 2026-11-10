import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/foundation.dart';
import '../services/sheet_navigation.dart';
import '../services/pdf_frame_import.dart';
import '../services/project_import.dart';
import 'controller.dart';

class SheetTab {
  const SheetTab(this.sessionId, this.sheetId);
  final String sessionId, sheetId;
  @override
  bool operator ==(Object other) =>
      other is SheetTab &&
      other.sessionId == sessionId &&
      other.sheetId == sheetId;
  @override
  int get hashCode => Object.hash(sessionId, sheetId);
}

class WorkspaceController extends ChangeNotifier {
  WorkspaceController(EditorController initial) : _active = initial {
    add(initial, owned: false);
  }
  bool _disposed = false;
  final List<EditorController> _documents = [];
  final List<SheetTab> _tabs = [];
  final Set<EditorController> _owned = {};
  final Map<EditorController, VoidCallback> _listeners = {};
  final Map<EditorController, SheetTab> _lastSheets = {};
  final Map<EditorController, StructureAspect> _sheetNavigationAspects = {};
  late EditorController _active;
  SheetTab? activeTab;
  int navigationGeneration = 0;
  int _openRequest = 0;
  EditorController get active => _active;
  List<EditorController> get documents => List.unmodifiable(_documents);
  List<SheetTab> get tabs => List.unmodifiable(_tabs);
  EditorController? document(String sessionId) =>
      _documents.where((d) => d.documentSessionId == sessionId).firstOrNull;

  void add(EditorController document, {bool owned = true}) {
    if (_documents.contains(document)) {
      openSheet(document, document.activeSheetId);
      return;
    }
    _documents.add(document);
    if (owned) _owned.add(document);
    void changed() {
      final next = SheetTab(document.documentSessionId, document.activeSheetId);
      final previous = _lastSheets[document];
      _tabs.removeWhere(
        (t) => this.document(t.sessionId)?.project.sheetById(t.sheetId) == null,
      );
      if (next != previous) {
        _lastSheets[document] = next;
        if (!_tabs.contains(next)) _tabs.add(next);
        if (document == _active) {
          navigationGeneration++;
          activeTab = next;
        }
      }
      notifyListeners();
    }

    _listeners[document] = changed;
    document.addListener(changed);
    openSheet(document, document.activeSheetId);
    document.enableAutosave();
  }

  void openSheet(
    EditorController document,
    String sheetId, {
    bool fitViewport = true,
    bool newTab = true,
  }) {
    if (!_documents.contains(document) ||
        document.project.sheetById(sheetId) == null) {
      return;
    }
    if (_active != document ||
        activeTab != SheetTab(document.documentSessionId, sheetId)) {
      navigationGeneration++;
    }
    final tab = SheetTab(document.documentSessionId, sheetId);
    if (!_tabs.contains(tab)) {
      final current = activeTab == null ? -1 : _tabs.indexOf(activeTab!);
      if (!newTab && current >= 0) {
        _tabs[current] = tab;
      } else {
        _tabs.add(tab);
      }
    }
    _active = document;
    activeTab = tab;
    _lastSheets[document] = tab;
    document.setSheet(sheetId, fitViewport: fitViewport);
    notifyListeners();
  }

  void setSheetNavigationAspect(EditorController doc, StructureAspect aspect) {
    if (!_documents.contains(doc) || sheetNavigationAspect(doc) == aspect) {
      return;
    }
    _sheetNavigationAspects[doc] = aspect;
    notifyListeners();
  }

  StructureAspect sheetNavigationAspect(EditorController doc) =>
      _sheetNavigationAspects[doc] ?? StructureAspect.function;

  Sheet? adjacentSheet(int delta) {
    if (activeTab == null) return null;
    final sheets = orderedSheets(
      active.project.pages,
      first: sheetNavigationAspect(active),
    );
    final index = sheets.indexWhere((s) => s.id == active.activeSheetId);
    final target = index + delta;
    return index < 0 || target < 0 || target >= sheets.length
        ? null
        : sheets[target];
  }

  void navigateSheet(int delta) {
    final target = adjacentSheet(delta);
    if (target != null) openSheet(active, target.id, newTab: false);
  }

  void activate(SheetTab tab) {
    final doc = document(tab.sessionId);
    if (doc != null) openSheet(doc, tab.sheetId);
  }

  void closeTab(SheetTab tab) {
    final index = _tabs.indexOf(tab);
    if (index < 0) return;
    _tabs.removeAt(index);
    if (activeTab == tab) {
      navigationGeneration++;
      activeTab = null;
      if (_tabs.isNotEmpty) activate(_tabs[index.clamp(0, _tabs.length - 1)]);
    }
    notifyListeners();
  }

  Future<bool> closeDocument(
    EditorController doc, {
    bool discardChanges = false,
  }) async {
    if (!_documents.contains(doc) || doc.ioBusy) return false;
    final generation = doc.documentGeneration;
    if ((!discardChanges && !await doc.flushWorkingCopy()) ||
        _disposed ||
        !_documents.contains(doc) ||
        !doc.isDocumentCurrent(generation) ||
        (!discardChanges && !doc.changesSaved) ||
        doc.ioBusy) {
      return false;
    }
    _tabs.removeWhere((t) => t.sessionId == doc.documentSessionId);
    doc.removeListener(_listeners.remove(doc)!);
    _lastSheets.remove(doc);
    _sheetNavigationAspects.remove(doc);
    _documents.remove(doc);
    _owned.remove(doc);
    doc.dispose();
    if (_active == doc) {
      activeTab = null;
      if (_tabs.isNotEmpty) {
        activate(_tabs.last);
      } else if (_documents.isNotEmpty) {
        _active = _documents.last;
      } else {
        add(_createDocument());
      }
    }
    notifyListeners();
    return true;
  }

  Future<bool> exportProjectCopy({EditorController? document}) {
    final doc = document ?? active;
    if (_disposed || !_documents.contains(doc)) return Future.value(false);
    return doc.exportProjectCopy(
      protectedPaths:
          () => {
            for (final other in _documents)
              if (other.currentFile != null) other.currentFile!.path,
          },
    );
  }

  Future<bool> open({
    String? path,
    bool importPdf = false,
    PdfImportReview? reviewPdf,
  }) async {
    final owner = active;
    final generation = owner.documentGeneration;
    final revision = owner.project.revision;
    final navigation = navigationGeneration;
    final statusGeneration = owner.statusGeneration;
    final request = ++_openRequest;
    bool current() =>
        !_disposed &&
        request == _openRequest &&
        active == owner &&
        _documents.contains(owner) &&
        owner.isDocumentCurrent(generation) &&
        owner.project.revision == revision &&
        navigationGeneration == navigation;
    void reportCancelledImport() {
      if (!_disposed &&
          request == _openRequest &&
          active == owner &&
          _documents.contains(owner) &&
          owner.isDocumentCurrent(generation) &&
          owner.statusGeneration == statusGeneration) {
        owner.reportStatus(
          'Import PDF zrušen: dokument nebo zobrazený list se mezitím změnil.',
        );
      }
    }

    final candidate = _createDocument(
      importer:
          importPdf && reviewPdf != null
              ? owner.importer.reviewNextImport(
                reviewPdf,
                isCurrent: current,
                reusableTemplates: owner.project.frameTemplates,
              )
              : null,
    );
    if (!await candidate.openProject(path: path, importPdf: importPdf)) {
      if (_disposed || (importPdf && !current())) {
        candidate.dispose();
        if (importPdf) reportCancelledImport();
        return false;
      }
      active.status = candidate.status;
      candidate.dispose();
      notifyListeners();
      return false;
    }
    if (importPdf && !current()) {
      candidate.dispose();
      reportCancelledImport();
      return false;
    }
    return _adopt(candidate);
  }

  Future<bool> restore(String sessionId) async {
    final existing = document(sessionId);
    if (existing != null) {
      openSheet(existing, existing.activeSheetId);
      return true;
    }
    final candidate = _createDocument();
    if (!await candidate.restoreWorkingCopy(sessionId)) {
      if (!_disposed) {
        active.status = candidate.status;
        notifyListeners();
      }
      candidate.dispose();
      return false;
    }
    return _adopt(candidate, restoring: true);
  }

  bool _adopt(EditorController candidate, {bool restoring = false}) {
    if (_disposed) {
      candidate.dispose();
      return false;
    }
    final canonical = candidate.currentFile?.path;
    final existing =
        _documents
            .where(
              (d) =>
                  d.documentSessionId == candidate.documentSessionId ||
                  (canonical != null &&
                      d.currentFile != null &&
                      candidate.persistence.fileSessionId(
                            d.currentFile!.path,
                          ) ==
                          candidate.persistence.fileSessionId(canonical)),
            )
            .firstOrNull;
    if (existing != null) {
      final pendingRecovery =
          restoring &&
          existing.documentSessionId != candidate.documentSessionId &&
          candidate.dirty;
      candidate.dispose();
      openSheet(existing, existing.activeSheetId);
      if (pendingRecovery) {
        existing.reportStatus(
          'Místní změny nebyly obnoveny: soubor je již otevřený. Nejprve tento projekt zavřete a pak obnovte místní změny.',
        );
        return false;
      }
    } else {
      add(candidate);
    }
    return true;
  }

  EditorController _createDocument({
    bool demo = false,
    ProjectImportService? importer,
  }) {
    final doc = EditorController(
      startEmpty: !demo,
      autosaveEnabled: false,
      persistence: active.persistence,
      importer: importer ?? active.importer.source,
    );
    doc.appearance = active.appearance;
    doc.aiSettings = active.aiSettings;
    doc.useOllama = active.useOllama;
    return doc;
  }

  void create({bool demo = false}) => add(_createDocument(demo: demo));

  @override
  void dispose() {
    _disposed = true;
    for (final doc in _documents) {
      doc.removeListener(_listeners[doc]!);
      if (_owned.contains(doc)) doc.dispose();
    }
    super.dispose();
  }
}
