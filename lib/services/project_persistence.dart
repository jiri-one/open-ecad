// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'file_download.dart';
import 'project_files.dart';
import 'provider_settings.dart';
import 'project_storage.dart';

export 'project_file_types.dart';
export 'project_storage.dart' show ProjectStorageConflict;

class AutosaveTooLargeException implements Exception {
  const AutosaveTooLargeException();

  @override
  String toString() =>
      'Projekt překračuje limit 128 MiB pro automatické uložení.';
}

class LoadedProject {
  const LoadedProject(this.project, {this.origin, this.fileName});
  final EcadProject project;
  final DocumentFileHandle? origin;
  final String? fileName;
}

class EncodedProject {
  const EncodedProject({
    required this.source,
    required this.bytes,
    required this.hash,
  });
  final String source;
  final Uint8List bytes;
  final String hash;
}

class WorkingCopy {
  const WorkingCopy(
    this.project, {
    required this.sessionId,
    this.savedRevision,
    this.fileName,
    this.currentFile,
    this.storageToken,
  });
  final EcadProject project;
  final String sessionId;
  final int? savedRevision;
  final String? fileName;
  final DocumentFileHandle? currentFile;
  final String? storageToken;
}

class SavedProjectSummary {
  const SavedProjectSummary({
    required this.sessionId,
    required this.name,
    required this.revision,
    required this.savedRevision,
    required this.fileName,
    required this.currentFile,
    required this.storageToken,
    required this.projectHash,
  });
  final String sessionId;
  final String name;
  final int revision;
  final int? savedRevision;
  final String? fileName;
  final DocumentFileHandle? currentFile;
  final String? storageToken;
  final String projectHash;

  bool get hasPendingFileChanges =>
      currentFile != null && revision != savedRevision;
}

const _backgroundThreshold = 64 * 1024;

class _PayloadTooLarge extends FormatException {
  const _PayloadTooLarge() : super('Projekt je větší než povolených 128 MiB.');
}

Object? _canonicalJson(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonicalJson(value[key])};
  }
  if (value is List) return value.map(_canonicalJson).toList();
  return value;
}

String _projectSource(EcadProject project) =>
    jsonEncode(_canonicalJson(project.toJson()));

EncodedProject _encodeProject(EcadProject project) {
  if (project.description.length > ProjectPersistence.maxFileBytes) {
    throw const _PayloadTooLarge();
  }
  final source = _projectSource(project);
  final bytes = utf8.encode(source);
  if (bytes.length > ProjectPersistence.maxFileBytes) {
    throw const _PayloadTooLarge();
  }
  return EncodedProject(
    source: source,
    bytes: bytes,
    hash: sha256.convert(bytes).toString(),
  );
}

EcadProject _decodeProjectBytes(Uint8List bytes) {
  if (bytes.length > ProjectPersistence.maxFileBytes) {
    throw const _PayloadTooLarge();
  }
  final project = EcadProject.fromJson(jsonDecode(utf8.decode(bytes)));
  requireValidProject(project);
  return project;
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

typedef _EncodedWorkingCopy = ({String source, Uint8List bytes, String token});

_EncodedWorkingCopy _encodeWorkingCopy(
  ({Map<String, Object?> metadata, EncodedProject encoded}) input,
) {
  final (:metadata, :encoded) = input;
  final digest = _DigestSink();
  sha256.startChunkedConversion(digest)
    ..add(utf8.encode(jsonEncode(metadata)))
    ..add(encoded.bytes)
    ..close();
  final token = digest.value.toString();
  final header = jsonEncode({...metadata, 'storageToken': token});
  final prefix =
      '${header.substring(0, header.length - 1)}$projectStorageHeaderEnd\n';
  final prefixBytes = utf8.encode(prefix);
  final bytes =
      Uint8List(prefixBytes.length + encoded.bytes.length + 1)
        ..setRange(0, prefixBytes.length, prefixBytes)
        ..setRange(
          prefixBytes.length,
          prefixBytes.length + encoded.bytes.length,
          encoded.bytes,
        );
  bytes[bytes.length - 1] = 125;
  return (source: '$prefix${encoded.source}}', bytes: bytes, token: token);
}

void _checkRecord(Map<String, dynamic> record, String id) {
  if ((record['version'] != 1 && record['version'] != 2) ||
      record['sessionId'] != id) {
    throw const FormatException(
      'Pracovní kopie je poškozená nebo nepodporovaná.',
    );
  }
}

int? _savedRevision(Object? saved, int revision) =>
    saved is int && saved >= 0 && saved <= revision ? saved : null;

SavedProjectSummary _decodeSummary((String, String) input) {
  final (id, source) = input;
  final record = projectStorageMetadata(source);
  _checkRecord(record, id);
  if (record['version'] == 1) {
    final copy = _decodeWorkingCopy(input);
    return SavedProjectSummary(
      sessionId: id,
      name: copy.project.name,
      revision: copy.project.revision,
      savedRevision: copy.savedRevision,
      fileName: copy.fileName,
      currentFile: copy.currentFile,
      storageToken: copy.storageToken,
      projectHash: _encodeProject(copy.project).hash,
    );
  }
  final name = record['name'];
  final revision = record['revision'];
  final hash = record['projectHash'];
  final token = projectStorageToken(source);
  if (name is! String ||
      revision is! int ||
      revision < 0 ||
      revision > ProjectLimits.maxRevision ||
      hash is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
      token == null) {
    throw const FormatException('Neplatná hlavička místního projektu.');
  }
  return SavedProjectSummary(
    sessionId: id,
    name: name,
    revision: revision,
    savedRevision: _savedRevision(record['savedRevision'], revision),
    fileName:
        record['fileName'] is String ? record['fileName'] as String : null,
    currentFile:
        record['file'] == null
            ? null
            : DocumentFileHandle.fromJson(record['file']),
    storageToken: token,
    projectHash: hash,
  );
}

WorkingCopy _decodeWorkingCopy((String, String) input) {
  final (id, source) = input;
  final record = jsonDecode(source);
  if (record is! Map<String, dynamic>) {
    throw const FormatException(
      'Pracovní kopie je poškozená nebo nepodporovaná.',
    );
  }
  _checkRecord(record, id);
  final header = projectStorageHeader(source);
  final payload =
      header.endsWith(projectStorageHeaderEnd)
          ? source.substring(header.length + 1, source.length - 1)
          : jsonEncode(record['project']);
  if (payload.length > ProjectPersistence.maxFileBytes ||
      utf8.encode(payload).length > ProjectPersistence.maxFileBytes) {
    throw const _PayloadTooLarge();
  }
  final project = EcadProject.fromJson(record['project']);
  requireValidProject(project);
  if (record['version'] == 2) {
    final summary = _decodeSummary((id, header));
    if (summary.name != project.name || summary.revision != project.revision) {
      throw const FormatException('Hlavička neodpovídá místnímu projektu.');
    }
  }
  return WorkingCopy(
    project,
    sessionId: id,
    savedRevision: _savedRevision(record['savedRevision'], project.revision),
    fileName:
        record['fileName'] is String ? record['fileName'] as String : null,
    currentFile:
        record['file'] == null
            ? null
            : DocumentFileHandle.fromJson(record['file']),
    storageToken: projectStorageToken(header),
  );
}

ProjectEngine _createEngine(EcadProject project) => ProjectEngine(project);

bool _projectsMatch((EcadProject, EcadProject) input) =>
    _projectSource(input.$1) == _projectSource(input.$2);

class _ProjectEstimate {
  int size = 0;
  bool get large => size > _backgroundThreshold;

  void json(Object? value) {
    if (large) return;
    size += 16;
    if (value is String) {
      size += value.length * 3;
    } else if (value is Map) {
      for (final entry in value.entries) {
        json(entry.key);
        json(entry.value);
        if (large) return;
      }
    } else if (value is Iterable) {
      for (final item in value) {
        json(item);
        if (large) return;
      }
    }
  }
}

bool _largeProject(EcadProject project) {
  final estimate = _ProjectEstimate();
  estimate.json([
    project.id,
    project.name,
    project.description,
    project.documentFields,
  ]);
  estimate.size +=
      (project.pages.length +
          project.components.length +
          project.articles.length +
          project.frameTemplates.length +
          project.terminalStrips.length +
          project.mountingLayouts.length +
          project.continuationLinks.length) *
      256;
  if (estimate.large) return true;
  estimate.json(project.defaultFrame.toJson());
  for (final template in project.frameTemplates) {
    estimate.size +=
        (template.titleBlock.fields.length + template.titleBlock.lines.length) *
        128;
    if (estimate.large) return true;
    estimate.json(template.toJson());
    if (estimate.large) return true;
  }
  for (final article in project.articles) {
    estimate.json(article.toJson());
    if (estimate.large) return true;
  }
  for (final component in project.components) {
    final electrical = component.electrical;
    if (electrical != null) {
      estimate.size +=
          (electrical.terminals.length + electrical.functions.length) * 128;
      if (estimate.large) return true;
      for (final function in electrical.functions) {
        estimate.size += function.terminalIds.length * 128;
        if (estimate.large) return true;
      }
    }
    estimate.json(component.toJson());
    if (estimate.large) return true;
  }
  for (final strip in project.terminalStrips) {
    estimate.json(strip.toJson());
    if (estimate.large) return true;
  }
  for (final link in project.continuationLinks) {
    estimate.json(link.toJson());
    if (estimate.large) return true;
  }
  for (final layout in project.mountingLayouts) {
    estimate.size += layout.placements.length * 128;
    if (estimate.large) return true;
    estimate.json(layout.toJson());
    if (estimate.large) return true;
  }
  for (final page in project.pages) {
    estimate.size +=
        (page.graphics.length +
            page.wires.length +
            page.devices.length +
            page.continuations.length +
            page.corners.length) *
        128;
    if (estimate.large) return true;
    estimate.json([
      page.id,
      page.name,
      page.number,
      page.documentCode,
      page.structure.toJson(),
      page.frame.toJson(),
      page.documentFields,
      page.mountingView?.toJson(),
      page.report?.toJson(),
    ]);
    if (estimate.large) return true;
    for (final graphic in page.graphics) {
      estimate.size +=
          (graphic.id.length +
                  graphic.text.length +
                  graphic.imageData.length +
                  (graphic.stroke?.length ?? 0) +
                  (graphic.fill?.length ?? 0)) *
              3 +
          graphic.path.length * 160 +
          graphic.dash.length * 24;
      if (estimate.large) return true;
    }
    for (final wire in page.wires) {
      estimate.size += wire.waypoints.length * 48;
      if (estimate.large) return true;
      estimate.json(wire.toJson());
      if (estimate.large) return true;
    }
    for (final device in page.devices) {
      final symbol = device.symbol;
      if (symbol is PortBlockSpec) estimate.size += symbol.ports.length * 128;
      if (estimate.large) return true;
      estimate.json(device.toJson());
      if (estimate.large) return true;
    }
    for (final corner in page.corners) {
      estimate.json(corner.toJson());
      if (estimate.large) return true;
    }
    for (final marker in page.continuations) {
      estimate.json(marker.toJson());
      if (estimate.large) return true;
    }
  }
  return estimate.large;
}

class ProjectPersistence {
  ProjectPersistence({ProjectFiles? files, ProjectStorage? storage})
    : files = files ?? createProjectFiles(),
      storage = storage ?? storageFactory();
  final ProjectFiles files;
  final ProjectStorage storage;
  @visibleForTesting
  static ProjectStorage Function() storageFactory = createProjectStorage;
  static const autosaveKey = 'open_ecad.autosave.v2';
  static const recoveryIndexKey = 'open_ecad.recovery.v1.index';
  static const recoveryPrefix = 'open_ecad.recovery.v1.';
  static const settingsKey = 'open_ecad.ollama.v1';
  static const startupProjectKey = 'open_ecad.startup.v1';
  static const maxFileBytes = ProjectLimits.maxFileBytes;
  static const maxAutosaveBytes = maxFileBytes;

  static Future<void> _autosaveQueue = Future<void>.value();
  String encode(EcadProject project) => _projectSource(project);

  Future<EncodedProject> prepareProject(EcadProject project) async =>
      _largeProject(project)
          ? compute(_encodeProject, project)
          : _encodeProject(project);

  Future<ProjectEngine> prepareEngine(EcadProject project) async =>
      _largeProject(project)
          ? compute(_createEngine, project)
          : _createEngine(project);

  Future<bool> projectsMatch(EcadProject a, EcadProject b) async {
    if (identical(a, b)) return true;
    return _largeProject(a) || _largeProject(b)
        ? compute(_projectsMatch, (a, b))
        : _projectsMatch((a, b));
  }

  String fileSessionId(String canonicalPath) {
    final path =
        defaultTargetPlatform == TargetPlatform.windows
            ? canonicalPath.replaceAll('\\', '/').toLowerCase()
            : canonicalPath;
    return 'file_${sha256.convert(utf8.encode(path))}';
  }

  EcadProject decode(String source) {
    if (source.length > maxFileBytes) throw const _PayloadTooLarge();
    return _decodeProjectBytes(utf8.encode(source));
  }

  Future<LoadedProject?> pickAndLoad() async {
    final file = await files.pick();
    return file == null ? null : _load(file);
  }

  Future<LoadedProject> loadPath(String path) async =>
      _load(await files.readPath(path));

  Future<LoadedProject> _load(ProjectFileData file) async => LoadedProject(
    file.bytes.length > _backgroundThreshold
        ? await compute(_decodeProjectBytes, file.bytes)
        : _decodeProjectBytes(file.bytes),
    origin: file.origin,
    fileName: file.origin?.path ?? file.name,
  );

  Future<SavedProjectFile?> saveTo(
    EcadProject project,
    DocumentFileHandle target, {
    required bool Function() canCommit,
    EncodedProject? encoded,
  }) => _save(project, target: target, canCommit: canCommit, encoded: encoded);

  Future<SavedProjectFile?> saveAs(
    EcadProject project, {
    DocumentFileHandle? currentFile,
    required bool Function() canCommit,
    EncodedProject? encoded,
    Iterable<String> Function()? protectedPaths,
  }) => _save(
    project,
    currentFile: currentFile,
    canCommit: canCommit,
    encoded: encoded,
    protectedPaths: protectedPaths,
  );

  Future<SavedProjectFile?> _save(
    EcadProject project, {
    DocumentFileHandle? target,
    DocumentFileHandle? currentFile,
    required bool Function() canCommit,
    EncodedProject? encoded,
    Iterable<String> Function()? protectedPaths,
  }) async {
    final bytes = (encoded ?? await prepareProject(project)).bytes;
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
      protectedPaths: protectedPaths,
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

  Future<String> saveWorkingCopy(WorkingCopy copy, {EncodedProject? encoded}) {
    final next = _autosaveQueue.then((_) async {
      final EncodedProject prepared;
      try {
        prepared = encoded ?? await prepareProject(copy.project);
      } on _PayloadTooLarge {
        throw const AutosaveTooLargeException();
      }
      if (prepared.bytes.length > maxAutosaveBytes) {
        throw const AutosaveTooLargeException();
      }
      final input = (
        metadata: <String, Object?>{
          'version': 2,
          'sessionId': copy.sessionId,
          'name': copy.project.name,
          'revision': copy.project.revision,
          'projectHash': prepared.hash,
          if (copy.savedRevision != null) 'savedRevision': copy.savedRevision,
          if (copy.fileName != null) 'fileName': copy.fileName,
          if (copy.currentFile != null) 'file': copy.currentFile!.toJson(),
        },
        encoded: prepared,
      );
      final record =
          prepared.bytes.length > _backgroundThreshold
              ? await compute(_encodeWorkingCopy, input)
              : _encodeWorkingCopy(input);
      await storage.write(
        copy.sessionId,
        record.source,
        bytes: record.bytes,
        expectedToken: copy.storageToken,
      );
      return record.token;
    });
    _autosaveQueue = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  Future<List<String>> listRecoveryIds() async {
    await _autosaveQueue;
    return storage.list();
  }

  Future<WorkingCopy?> loadAutosave({String? sessionId}) async {
    await _autosaveQueue;
    var id = sessionId;
    if (id == null) {
      final ids = await storage.list();
      id = ids.firstOrNull;
    }
    if (id == null) {
      final preferences = await SharedPreferences.getInstance();
      await preferences.reload();
      if (preferences.containsKey(autosaveKey)) {
        throw const FormatException(
          'Starší pracovní kopie není podporována; zůstala beze změny v místním úložišti.',
        );
      }
      return null;
    }
    final source = await storage.read(id);
    if (source == null) throw const FormatException('Pracovní kopie chybí.');
    return source.length > _backgroundThreshold
        ? compute(_decodeWorkingCopy, (id, source))
        : _decodeWorkingCopy((id, source));
  }

  Future<SavedProjectSummary?> loadProjectSummary(String sessionId) async {
    await _autosaveQueue;
    final header = await storage.readHeader(sessionId);
    if (header == null) return null;
    return header.length > _backgroundThreshold
        ? compute(_decodeSummary, (sessionId, header))
        : _decodeSummary((sessionId, header));
  }

  Future<SavedProjectSummary?> findMatchingLocalProject({
    required String fileName,
    required String projectHash,
  }) async {
    for (final id in await listRecoveryIds()) {
      try {
        final summary = await loadProjectSummary(id);
        if (summary != null &&
            summary.currentFile == null &&
            summary.fileName == fileName &&
            summary.projectHash == projectHash) {
          return summary;
        }
      } on FormatException {
        continue;
      } on EcadException {
        continue;
      }
    }
    return null;
  }

  Future<void> removeWorkingCopy(
    String sessionId, {
    required String? expectedToken,
  }) {
    final next = _autosaveQueue.then(
      (_) => storage.remove(sessionId, expectedToken: expectedToken),
    );
    _autosaveQueue = next.catchError((Object _) {});
    return next;
  }

  Future<({String sessionId, String? filePath})?> loadStartupProject() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.reload();
      final source = preferences.getString(startupProjectKey);
      if (source == null) return null;
      final record = jsonDecode(source);
      if (record is! Map<String, dynamic> ||
          record['sessionId'] is! String ||
          (record['filePath'] != null && record['filePath'] is! String)) {
        return null;
      }
      final id = record['sessionId'] as String;
      validateProjectStorageId(id);
      return (sessionId: id, filePath: record['filePath'] as String?);
    } catch (_) {
      return null;
    }
  }

  Future<void> rememberStartupProject(
    String sessionId, {
    String? filePath,
  }) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        startupProjectKey,
        jsonEncode({
          'sessionId': sessionId,
          if (filePath != null) 'filePath': filePath,
        }),
      );
    } catch (_) {
      // Optional navigation metadata must not prevent a safely saved close.
    }
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
