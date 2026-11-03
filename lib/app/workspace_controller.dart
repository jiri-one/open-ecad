import 'dart:async';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/foundation.dart';
import '../services/sheet_navigation.dart';
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

  // The caller resolves unsaved changes before removing a document.
  void closeDocument(EditorController doc) {
    if (!_documents.contains(doc)) return;
    final sessionId = doc.documentSessionId;
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
    final owner = active, statusGeneration = active.statusGeneration;
    unawaited(
      doc.persistence.removeWorkingCopy(sessionId).catchError((Object _) {
        if (!_disposed &&
            active == owner &&
            active.statusGeneration == statusGeneration) {
          active.reportStatus(
            'Pracovní kopii zavřeného projektu se nepodařilo odstranit.',
          );
        }
      }),
    );
  }

  Future<bool> open({String? path, bool importPdf = false}) async {
    final candidate = _createDocument();
    if (!await candidate.openProject(path: path, importPdf: importPdf)) {
      if (_disposed) {
        candidate.dispose();
        return false;
      }
      active.status = candidate.status;
      candidate.dispose();
      notifyListeners();
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
    return _adopt(candidate);
  }

  bool _adopt(EditorController candidate) {
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
                  (canonical != null && d.currentFile?.path == canonical),
            )
            .firstOrNull;
    if (existing != null) {
      candidate.dispose();
      openSheet(existing, existing.activeSheetId);
    } else {
      add(candidate);
    }
    return true;
  }

  EditorController _createDocument({bool demo = false}) {
    final doc = EditorController(
      startEmpty: !demo,
      persistence: active.persistence,
      importer: active.importer,
    );
    doc.appearance = active.appearance;
    doc.aiSettings = active.aiSettings;
    doc.useOllama = active.useOllama;
    return doc;
  }

  void create({bool demo = false}) {
    add(_createDocument(demo: demo));
  }

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
