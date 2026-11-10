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
      _savedRevision = project.revision;

  final ProjectPersistence persistence;
  ProjectEngine _engine;
  String _sessionId = newId('document');
  DocumentFileHandle? _currentFile;
  String? _fileName;
  int? _savedRevision;
  String? _storageToken;
  WorkingCopy? _checkpoint;
  Object? checkpointWarning;
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
    storageToken: _storageToken,
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
    String? storageToken,
    ProjectEngine? engine,
    WorkingCopy? checkpoint,
  }) {
    final next = engine ?? ProjectEngine(loaded.project);
    _engine = next;
    _generation++;
    _sessionId = recoveryId ?? newId('document');
    _currentFile = loaded.origin;
    _fileName = loaded.origin?.path ?? loaded.fileName;
    _savedRevision = savedRevision;
    _storageToken = storageToken;
    _checkpoint = checkpoint;
    checkpointWarning = null;
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
    final generation = _generation, revision = project.revision;
    final request = ++_loadRequest;
    bool current() =>
        _isCurrent(generation) &&
        project.revision == revision &&
        request == _loadRequest;
    final startup = await persistence.loadStartupProject();
    if (!current()) return DocumentIoResult.superseded;
    if (startup != null) {
      final summary = await persistence.loadProjectSummary(startup.sessionId);
      if (!current()) return DocumentIoResult.superseded;
      if (summary != null) return restore(recoveryId: startup.sessionId);
      if (startup.filePath != null) return open(path: startup.filePath);
      return DocumentIoResult.unchanged;
    }
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
      var loaded = LoadedProject(
        copy.project,
        origin: copy.currentFile,
        fileName: copy.fileName,
      );
      var savedRevision = copy.savedRevision;
      final origin = copy.currentFile;
      if (origin != null) {
        try {
          final disk = await persistence.loadPath(origin.path);
          if (!current()) return DocumentIoResult.superseded;
          if (copy.project.revision == copy.savedRevision) {
            loaded = disk;
            savedRevision = disk.project.revision;
          } else if (await persistence.projectsMatch(
            disk.project,
            copy.project,
          )) {
            // The file may have committed just before its checkpoint was written.
            loaded = LoadedProject(
              copy.project,
              origin: disk.origin,
              fileName: disk.fileName,
            );
            savedRevision = copy.project.revision;
          }
        } catch (_) {
          if (!current()) return DocumentIoResult.superseded;
          savedRevision = null;
        }
      }
      final engine = await persistence.prepareEngine(loaded.project);
      if (!current()) return DocumentIoResult.superseded;
      _replace(
        loaded,
        savedRevision: savedRevision,
        recoveryId: copy.sessionId,
        storageToken: copy.storageToken,
        engine: engine,
        checkpoint: copy,
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
      String? recoveryId, storageToken;
      if (loaded.origin != null) {
        final id = persistence.fileSessionId(loaded.origin!.path);
        try {
          final summary = await persistence.loadProjectSummary(id);
          if (!current()) return DocumentIoResult.superseded;
          if (summary == null) {
            recoveryId = id;
          } else if (!summary.hasPendingFileChanges &&
              summary.currentFile != null &&
              persistence.fileSessionId(summary.currentFile!.path) == id) {
            recoveryId = summary.sessionId;
            storageToken = summary.storageToken;
          }
        } catch (_) {
          if (!current()) return DocumentIoResult.superseded;
        }
      } else if (importProject == null && loaded.fileName != null) {
        final encoded = await persistence.prepareProject(loaded.project);
        if (!current()) return DocumentIoResult.superseded;
        final reusable = await persistence.findMatchingLocalProject(
          fileName: loaded.fileName!,
          projectHash: encoded.hash,
        );
        recoveryId = reusable?.sessionId;
        storageToken = reusable?.storageToken;
        if (!current()) return DocumentIoResult.superseded;
      }
      final engine = await persistence.prepareEngine(loaded.project);
      if (!current()) return DocumentIoResult.superseded;
      _replace(
        loaded,
        savedRevision: importProject != null ? null : loaded.project.revision,
        recoveryId: recoveryId,
        storageToken: storageToken,
        engine: engine,
      );
      return DocumentIoResult.opened;
    } catch (_) {
      if (!current()) return DocumentIoResult.superseded;
      rethrow;
    }
  }

  bool _checkpointMatches(EcadProject snapshot) {
    final copy = _checkpoint;
    return _storageToken != null &&
        copy != null &&
        identical(copy.project, snapshot) &&
        copy.savedRevision ==
            (currentFile == null ? snapshot.revision : savedRevision) &&
        copy.currentFile?.path == currentFile?.path &&
        copy.currentFile?.version == currentFile?.version &&
        copy.fileName == fileName;
  }

  Future<void> _writeCheckpoint(
    EcadProject snapshot,
    EncodedProject encoded,
    int generation,
  ) async {
    final copy = WorkingCopy(
      snapshot,
      sessionId: sessionId,
      storageToken: _storageToken,
      savedRevision: currentFile == null ? snapshot.revision : savedRevision,
      fileName: fileName,
      currentFile: currentFile,
    );
    final token = await persistence.saveWorkingCopy(copy, encoded: encoded);
    if (!_isCurrent(generation)) return;
    _storageToken = token;
    _checkpoint = copy;
  }

  Future<DocumentIoResult> autosave() async {
    if (_disposed) return DocumentIoResult.superseded;
    final generation = _generation;
    final snapshot = project;
    if (_checkpointMatches(snapshot) && !dirty) return DocumentIoResult.saved;
    final encoded = await persistence.prepareProject(snapshot);
    if (!_isCurrent(generation)) return DocumentIoResult.superseded;
    Object? localFailure;
    if (!_checkpointMatches(snapshot)) {
      try {
        await _writeCheckpoint(snapshot, encoded, generation);
      } catch (error) {
        if (currentFile == null ||
            (error is ProjectStorageConflict &&
                snapshot.revision != savedRevision)) {
          rethrow;
        }
        localFailure = error;
      }
    }
    if (!_isCurrent(generation)) return DocumentIoResult.superseded;
    if (currentFile == null) {
      _savedRevision = snapshot.revision;
    } else {
      final needsFileSave = snapshot.revision != savedRevision;
      if (needsFileSave) {
        final result = await _saveSnapshot(snapshot, encoded: encoded);
        if (result != DocumentIoResult.saved || !_isCurrent(generation)) {
          return DocumentIoResult.superseded;
        }
      }
      if (needsFileSave || localFailure != null) {
        try {
          await _writeCheckpoint(snapshot, encoded, generation);
          localFailure = null;
        } catch (error) {
          localFailure = error;
        }
      }
    }
    if (!_isCurrent(generation)) return DocumentIoResult.superseded;
    checkpointWarning = localFailure;
    return DocumentIoResult.saved;
  }

  Future<bool> continueLocally({required bool storageConflict}) async {
    if (_disposed || (currentFile == null && !storageConflict)) return false;
    final generation = _generation;
    final snapshot = project;
    final previousId = sessionId, previousToken = _storageToken;
    final retirePrevious = currentFile != null && !storageConflict;
    final id = newId('document');
    final copy = WorkingCopy(
      snapshot,
      sessionId: id,
      savedRevision: snapshot.revision,
    );
    final token = await persistence.saveWorkingCopy(copy);
    if (!_isCurrent(generation) || !identical(project, snapshot)) return false;
    _generation++;
    _sessionId = id;
    _currentFile = null;
    _fileName = null;
    _savedRevision = snapshot.revision;
    _storageToken = token;
    _checkpoint = copy;
    checkpointWarning = null;
    if (retirePrevious) {
      try {
        await persistence.removeWorkingCopy(
          previousId,
          expectedToken: previousToken,
        );
      } catch (_) {
        // The new local copy is durable even if the previous cache changed.
      }
    }
    return true;
  }

  Future<DocumentIoResult> exportCopy({
    Iterable<String> Function()? protectedPaths,
  }) async {
    if (_disposed) return DocumentIoResult.superseded;
    final generation = _generation;
    bool current() => _isCurrent(generation);
    try {
      final result = await persistence.saveAs(
        project,
        canCommit: current,
        protectedPaths:
            () => {
              ...?protectedPaths?.call(),
              if (currentFile != null) currentFile!.path,
            },
      );
      if (!current()) return DocumentIoResult.superseded;
      return result == null
          ? DocumentIoResult.canceled
          : DocumentIoResult.saved;
    } on DocumentOperationSuperseded {
      return DocumentIoResult.superseded;
    }
  }

  Future<DocumentIoResult> save({bool saveAs = false}) =>
      _saveSnapshot(project, saveAs: saveAs);

  Future<DocumentIoResult> _saveSnapshot(
    EcadProject snapshot, {
    bool saveAs = false,
    EncodedProject? encoded,
  }) async {
    if (_disposed) return DocumentIoResult.superseded;
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
                encoded: encoded,
                canCommit: current,
              )
              : await persistence.saveTo(
                snapshot,
                file,
                canCommit: current,
                encoded: encoded,
              );
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

  void dispose() => _disposed = true;
}
