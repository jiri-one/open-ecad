// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:ecad_core/ecad_core.dart';

import 'project_persistence.dart';

enum DocumentIoResult {
  opened,
  restored,
  saved,
  canceled,
  superseded,
  unchanged,
}

class DocumentSession {
  DocumentSession(EcadProject project, {required this.persistence})
    : _engine = ProjectEngine(project),
      _savedRevision = project.revision {
    persistence.retainRecoverySession(_sessionId);
  }

  final ProjectPersistence persistence;
  ProjectEngine _engine;
  String _sessionId = newId('document');
  DocumentFileHandle? _currentFile;
  String? _fileName;
  int? _savedRevision;
  int _generation = 0;
  int _loadRequest = 0;
  int _saveRequest = 0;
  Future<void>? _nativeSave;
  bool _disposed = false;
  bool _initialized = false;

  ProjectEngine get engine => _engine;
  EcadProject get project => engine.project;
  String get sessionId => _sessionId;
  int get generation => _generation;
  DocumentFileHandle? get currentFile => _currentFile;
  String? get fileName => _fileName;
  int? get savedRevision => _savedRevision;
  bool get dirty => project.revision != savedRevision;
  WorkingCopy get workingCopy => WorkingCopy(
    project,
    sessionId: sessionId,
    savedRevision: savedRevision,
    fileName: fileName,
    currentFile: currentFile,
  );

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void replace(EcadProject project, {bool saved = false}) => _replace(
    LoadedProject(project),
    savedRevision: saved ? project.revision : null,
  );

  void _replace(
    LoadedProject loaded, {
    int? savedRevision,
    String? recoveryId,
  }) {
    final next = ProjectEngine(loaded.project);
    persistence.releaseRecoverySession(_sessionId);
    _engine = next;
    _generation++;
    _sessionId = recoveryId ?? newId('document');
    persistence.retainRecoverySession(_sessionId);
    _currentFile = loaded.origin;
    _fileName = loaded.origin?.path ?? loaded.fileName;
    _savedRevision = savedRevision;
    _nativeSave = null;
  }

  Future<DocumentIoResult> initialize({
    String? startupProjectPath,
    String? startupError,
    bool restoreAutosave = true,
  }) async {
    if (_initialized || _disposed) return DocumentIoResult.unchanged;
    _initialized = true;
    if (startupError != null) throw FormatException(startupError);
    if (startupProjectPath != null) return open(path: startupProjectPath);
    if (!restoreAutosave) return DocumentIoResult.unchanged;
    return restore();
  }

  Future<DocumentIoResult> restore({String? recoveryId}) async {
    if (_disposed) return DocumentIoResult.superseded;
    final generation = _generation;
    final revision = project.revision;
    final request = ++_loadRequest;
    bool current() =>
        _isCurrent(generation) &&
        request == _loadRequest &&
        project.revision == revision;
    try {
      final copy = await persistence.loadAutosave(sessionId: recoveryId);
      if (!current()) return DocumentIoResult.superseded;
      if (copy == null) return DocumentIoResult.unchanged;
      _replace(
        LoadedProject(
          copy.project,
          origin: copy.currentFile,
          fileName: copy.fileName,
        ),
        savedRevision: copy.savedRevision,
        recoveryId: copy.sessionId,
      );
      return DocumentIoResult.restored;
    } catch (_) {
      if (!current()) return DocumentIoResult.superseded;
      rethrow;
    }
  }

  Future<DocumentIoResult> open({
    String? path,
    Future<EcadProject?> Function()? importProject,
  }) async {
    if (_disposed) return DocumentIoResult.superseded;
    final generation = _generation;
    final revision = project.revision;
    final request = ++_loadRequest;
    bool current() =>
        _isCurrent(generation) &&
        request == _loadRequest &&
        project.revision == revision;
    try {
      final LoadedProject? loaded;
      if (importProject != null) {
        final imported = await importProject();
        loaded = imported == null ? null : LoadedProject(imported);
      } else {
        loaded =
            path == null
                ? await persistence.pickAndLoad()
                : await persistence.loadPath(path);
      }
      if (!current()) return DocumentIoResult.superseded;
      if (loaded == null) return DocumentIoResult.canceled;
      _replace(
        loaded,
        savedRevision: importProject != null ? null : loaded.project.revision,
      );
      return DocumentIoResult.opened;
    } catch (_) {
      if (!current()) return DocumentIoResult.superseded;
      rethrow;
    }
  }

  Future<DocumentIoResult> save({bool saveAs = false}) async {
    if (_disposed) return DocumentIoResult.superseded;
    final snapshot = project;
    final generation = _generation;
    final request = ++_saveRequest;
    bool current() => _isCurrent(generation) && request == _saveRequest;
    // A known file's next write needs the token from any preceding OS commit.
    final previous = currentFile == null ? null : _nativeSave;
    final completion = currentFile == null ? null : Completer<void>();
    if (completion != null) _nativeSave = completion.future;
    try {
      if (previous != null) await previous;
      if (!current()) return DocumentIoResult.superseded;
      final file = currentFile;
      final result =
          saveAs || file == null
              ? await persistence.saveAs(
                snapshot,
                currentFile: file,
                canCommit: current,
              )
              : await persistence.saveTo(snapshot, file, canCommit: current);
      if (!_isCurrent(generation) || (!current() && completion == null)) {
        return DocumentIoResult.superseded;
      }
      if (result == null) {
        return current()
            ? DocumentIoResult.canceled
            : DocumentIoResult.superseded;
      }
      // A superseding request cannot undo a commit already made by this save.
      _currentFile = result.origin;
      _fileName = result.origin?.path ?? result.name;
      _savedRevision = snapshot.revision;
      return current() ? DocumentIoResult.saved : DocumentIoResult.superseded;
    } on DocumentOperationSuperseded {
      return DocumentIoResult.superseded;
    } catch (_) {
      if (!current()) return DocumentIoResult.superseded;
      rethrow;
    } finally {
      completion?.complete();
      if (completion != null && identical(_nativeSave, completion.future)) {
        _nativeSave = null;
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    persistence.releaseRecoverySession(_sessionId);
  }
}
