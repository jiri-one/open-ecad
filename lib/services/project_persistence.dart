// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'file_download.dart';
import 'project_files.dart';
import 'provider_settings.dart';

export 'project_file_types.dart';

class AutosaveTooLargeException implements Exception {
  const AutosaveTooLargeException();
}

class LoadedProject {
  const LoadedProject(this.project, {this.origin, this.fileName});
  final EcadProject project;
  final DocumentFileHandle? origin;
  final String? fileName;
}

class WorkingCopy {
  const WorkingCopy(
    this.project, {
    required this.sessionId,
    this.savedRevision,
    this.fileName,
    this.currentFile,
  });
  final EcadProject project;
  final String sessionId;
  final int? savedRevision;
  final String? fileName;
  final DocumentFileHandle? currentFile;
}

EcadProject _decodeProject(String source) =>
    ProjectPersistence().decode(source);
String _encodeProject(EcadProject project) => jsonEncode(project.toJson());

class ProjectPersistence {
  ProjectPersistence({ProjectFiles? files})
    : files = files ?? createProjectFiles();
  final ProjectFiles files;
  static const autosaveKey = 'open_ecad.autosave.v2';
  static const recoveryIndexKey = 'open_ecad.recovery.v1.index';
  static const recoveryPrefix = 'open_ecad.recovery.v1.';
  static const settingsKey = 'open_ecad.ollama.v1';
  static const maxFileBytes = ProjectLimits.maxFileBytes;
  static const maxAutosaveBytes = 2 * 1024 * 1024;
  static const maxRetainedRecoveryCopies = 10;

  static Future<void> _autosaveQueue = Future<void>.value();
  static final _openRecoverySessions = <String, int>{};

  void retainRecoverySession(String sessionId) =>
      _openRecoverySessions.update(sessionId, (n) => n + 1, ifAbsent: () => 1);

  void releaseRecoverySession(String sessionId) {
    final users = _openRecoverySessions[sessionId];
    if (users == null) return;
    if (users == 1) {
      _openRecoverySessions.remove(sessionId);
    } else {
      _openRecoverySessions[sessionId] = users - 1;
    }
  }

  String encode(EcadProject project) => jsonEncode(project.toJson());

  EcadProject decode(String source) {
    if (utf8.encode(source).length > maxFileBytes) {
      throw const FormatException('Projekt je větší než povolených 128 MiB.');
    }
    final project = EcadProject.fromJson(jsonDecode(source));
    requireValidProject(project);
    return project;
  }

  Future<LoadedProject?> pickAndLoad() async {
    final file = await files.pick();
    return file == null ? null : _load(file);
  }

  Future<LoadedProject> loadPath(String path) async =>
      _load(await files.readPath(path));

  Future<LoadedProject> _load(ProjectFileData file) async => LoadedProject(
    await compute(_decodeProject, utf8.decode(file.bytes)),
    origin: file.origin,
    fileName: file.origin?.path ?? file.name,
  );

  Future<SavedProjectFile?> saveTo(
    EcadProject project,
    DocumentFileHandle target, {
    required bool Function() canCommit,
  }) => _save(project, target: target, canCommit: canCommit);

  Future<SavedProjectFile?> saveAs(
    EcadProject project, {
    DocumentFileHandle? currentFile,
    required bool Function() canCommit,
  }) => _save(project, currentFile: currentFile, canCommit: canCommit);

  Future<SavedProjectFile?> _save(
    EcadProject project, {
    DocumentFileHandle? target,
    DocumentFileHandle? currentFile,
    required bool Function() canCommit,
  }) async {
    final encoded = await compute(_encodeProject, project);
    final bytes = Uint8List.fromList(utf8.encode(encoded));
    if (bytes.length > maxFileBytes) {
      throw const FormatException('Projekt je větší než povolených 128 MiB.');
    }
    if (!canCommit()) throw const DocumentOperationSuperseded();
    return files.save(
      bytes,
      suggestedName: '${safeFileName(project.name)}.oecad',
      target: target,
      currentFile: currentFile,
      canCommit: canCommit,
    );
  }

  Future<String?> saveBytes(
    Uint8List bytes, {
    required String fileName,
    required String mimeType,
    required String extension,
  }) => saveFileBytes(
    bytes,
    fileName: fileName,
    mimeType: mimeType,
    extension: extension,
  );

  Future<void> saveWorkingCopy(WorkingCopy copy) {
    final project = copy.project;
    final graphicCount = project.pages.fold<int>(
      0,
      (n, page) => n + page.graphics.length,
    );
    final payloadChars = project.pages
        .expand((page) => page.graphics)
        .fold<int>(
          0,
          (n, graphic) =>
              n +
              graphic.imageData.length +
              graphic.text.length +
              graphic.path.length * 24,
        );
    final json =
        graphicCount > 15000 || payloadChars > maxAutosaveBytes
            ? null
            : jsonEncode({
              'version': 1,
              'sessionId': copy.sessionId,
              'project': project.toJson(),
              if (copy.savedRevision != null)
                'savedRevision': copy.savedRevision,
              if (copy.fileName != null) 'fileName': copy.fileName,
              if (copy.currentFile != null) 'file': copy.currentFile!.toJson(),
            });
    final tooLarge =
        json == null || utf8.encode(json).length > maxAutosaveBytes;
    // Ordered writes keep a slow older snapshot from replacing a newer one.
    final next = _autosaveQueue.then((_) async {
      if (tooLarge) throw const AutosaveTooLargeException();
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.setString(
        '$recoveryPrefix${copy.sessionId}',
        json,
      )) {
        throw StateError('Automatické uložení se nezdařilo.');
      }
      final ids =
          <String>{
            copy.sessionId,
            ...?preferences.getStringList(recoveryIndexKey),
          }.toList();
      // Open documents remain recoverable even when their snapshot is older.
      final expired =
          ids
              .where((id) => !_openRecoverySessions.containsKey(id))
              .skip(maxRetainedRecoveryCopies)
              .toSet();
      ids.removeWhere(expired.contains);
      if (!await preferences.setStringList(recoveryIndexKey, ids)) {
        throw StateError('Seznam pracovních kopií se nepodařilo uložit.');
      }
      for (final id in expired) {
        if (!await preferences.remove('$recoveryPrefix$id')) {
          throw StateError('Starší pracovní kopii se nepodařilo odstranit.');
        }
      }
    });
    _autosaveQueue = next.catchError((Object _) {});
    return next;
  }

  Future<List<String>> listRecoveryIds() async {
    await _autosaveQueue;
    final preferences = await SharedPreferences.getInstance();
    return List.unmodifiable(preferences.getStringList(recoveryIndexKey) ?? []);
  }

  Future<WorkingCopy?> loadAutosave({String? sessionId}) async {
    await _autosaveQueue;
    final preferences = await SharedPreferences.getInstance();
    final ids = preferences.getStringList(recoveryIndexKey) ?? [];
    final id = sessionId ?? (ids.isEmpty ? null : ids.first);
    if (id == null) {
      if (preferences.containsKey(autosaveKey)) {
        throw const FormatException(
          'Starší pracovní kopie není podporována; zůstala beze změny v místním úložišti.',
        );
      }
      return null;
    }
    final source = preferences.getString('$recoveryPrefix$id');
    if (source == null) throw const FormatException('Pracovní kopie chybí.');
    final record = jsonDecode(source);
    if (record is! Map<String, dynamic> ||
        record['version'] != 1 ||
        record['sessionId'] != id) {
      throw const FormatException(
        'Pracovní kopie je poškozená nebo nepodporovaná.',
      );
    }
    final project = EcadProject.fromJson(record['project']);
    requireValidProject(project);
    final saved = record['savedRevision'];
    final fileName = record['fileName'];
    return WorkingCopy(
      project,
      sessionId: id,
      savedRevision:
          saved is int && saved >= 0 && saved <= project.revision
              ? saved
              : null,
      fileName: fileName is String ? fileName : null,
      currentFile:
          record['file'] == null
              ? null
              : DocumentFileHandle.fromJson(record['file']),
    );
  }

  Future<void> removeWorkingCopy(String sessionId) {
    final next = _autosaveQueue.then((_) async {
      final preferences = await SharedPreferences.getInstance();
      final ids = preferences.getStringList(recoveryIndexKey) ?? [];
      ids.remove(sessionId);
      if (!await preferences.setStringList(recoveryIndexKey, ids) ||
          !await preferences.remove('$recoveryPrefix$sessionId')) {
        throw StateError('Pracovní kopii se nepodařilo odstranit.');
      }
    });
    _autosaveQueue = next.catchError((Object _) {});
    return next;
  }

  Future<AiProviderSettings?> loadAiSettings() async {
    final preferences = await SharedPreferences.getInstance();
    final source = preferences.getString(settingsKey);
    if (source == null) return null;
    final json = jsonDecode(source);
    if (json is! Map<String, dynamic>) return null;
    return AiProviderSettings.fromJson(json);
  }

  Future<void> saveAiSettings(AiProviderSettings settings) async {
    settings.validate();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(settingsKey, jsonEncode(settings.toJson()));
  }

  static String safeFileName(String name) {
    final clean =
        name
            .replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_')
            .replaceAll(RegExp(r'[. ]+$'), '')
            .trim();
    return clean.isEmpty
        ? 'projekt'
        : clean.substring(0, clean.length.clamp(0, 100));
  }
}
