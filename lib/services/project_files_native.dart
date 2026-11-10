// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:ecad_core/ecad_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show compute;

import 'project_file_types.dart';

const _projectTypes = [
  XTypeGroup(label: 'Open ECAD project', extensions: ['oecad', 'json']),
];

Future<String?> _pickOpen() async =>
    (await openFile(acceptedTypeGroups: _projectTypes))?.path;

Future<String?> _pickSave(String name, String? currentPath) async =>
    (await getSaveLocation(
      suggestedName:
          currentPath == null ? name : File(currentPath).uri.pathSegments.last,
      initialDirectory:
          currentPath == null ? null : File(currentPath).parent.path,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Open ECAD project', extensions: ['oecad']),
      ],
    ))?.path;

class PlatformProjectFiles implements ProjectFiles {
  PlatformProjectFiles({
    Future<String?> Function()? selectOpen,
    Future<String?> Function(String, String?)? selectSave,
  }) : _selectOpen = selectOpen ?? _pickOpen,
       _selectSave = selectSave ?? _pickSave;

  final Future<String?> Function() _selectOpen;
  final Future<String?> Function(String, String?) _selectSave;

  @override
  Future<ProjectFileData?> pick() async {
    final path = await _selectOpen();
    return path == null ? null : readPath(path);
  }

  @override
  Future<ProjectFileData> readPath(String path) async {
    final canonical = await File(path).resolveSymbolicLinks();
    final file = File(canonical);
    final (bytes, version) = await _read(file);
    return ProjectFileData(
      bytes,
      origin: DocumentFileHandle(path: canonical, version: version),
      name: file.uri.pathSegments.last,
    );
  }

  @override
  Future<SavedProjectFile?> save(
    Uint8List bytes, {
    required String suggestedName,
    required bool Function() canCommit,
    DocumentFileHandle? target,
    DocumentFileHandle? currentFile,
    Iterable<String> Function()? protectedPaths,
  }) async {
    void checkCurrent() {
      if (!canCommit()) throw const DocumentOperationSuperseded();
    }

    checkCurrent();
    final selected =
        target?.path ?? await _selectSave(suggestedName, currentFile?.path);
    checkCurrent();
    if (selected == null) return null;
    final path = await _canonicalSavePath(selected);
    void checkDestination() {
      if ((protectedPaths?.call() ?? const <String>[]).any(
        (p) =>
            Platform.isWindows
                ? p.toLowerCase() == path.toLowerCase()
                : p == path,
      )) {
        throw StateError(
          'Tento soubor patří otevřenému projektu. Pro kopii vyberte jiný soubor.',
        );
      }
    }

    checkDestination();
    final file = File(path);
    final known = target ?? (currentFile?.path == path ? currentFile : null);
    final expected = known?.version ?? await _version(file);
    if (known != null && known.path != path) {
      throw ProjectFileConflict(known.path);
    }
    checkCurrent();
    final directory = await file.parent.createTemp('.open-ecad-');
    try {
      final temporary = File(
        '${directory.path}${Platform.pathSeparator}project.tmp',
      );
      await temporary.writeAsBytes(bytes, flush: true);
      if (!Platform.isWindows) {
        final original = await file.stat();
        if (original.type == FileSystemEntityType.file) {
          // Rename replaces the inode, so the staging file needs its mode first.
          final mode = (original.mode & 0xfff).toRadixString(8);
          final changed = await Process.run('/bin/chmod', [
            mode,
            temporary.path,
          ]);
          if (changed.exitCode != 0) {
            throw FileSystemException(
              'Cannot preserve file permissions: ${changed.stderr}',
              path,
            );
          }
        }
      }
      final stat = await temporary.stat();
      final writtenVersion = await compute(_tokenData, (
        size: stat.size,
        modified: stat.modified.microsecondsSinceEpoch,
        bytes: bytes,
      ));
      if (await _version(file) != expected) throw ProjectFileConflict(path);
      checkCurrent();
      checkDestination();
      // Keep document replacement and the OS commit in the same event-loop turn.
      temporary.renameSync(path);
      return SavedProjectFile(
        origin: DocumentFileHandle(path: path, version: writtenVersion),
        name: file.uri.pathSegments.last,
      );
    } finally {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // Cleanup must not turn a committed save into an apparent failure.
      }
    }
  }
}

Future<String> _canonicalSavePath(String path) async {
  final file = File(path).absolute;
  if (await file.exists()) return file.resolveSymbolicLinks();
  final parent = await file.parent.resolveSymbolicLinks();
  return '$parent${Platform.pathSeparator}${file.uri.pathSegments.last}';
}

Future<String?> _version(File file) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return null;
  if (type != FileSystemEntityType.file) throw ProjectFileConflict(file.path);
  return (await _read(file)).$2;
}

Future<(Uint8List, String)> _read(File file) => compute(_readPath, file.path);

(Uint8List, String) _readPath(String path) {
  final file = File(path);
  final before = file.statSync();
  if (before.size > ProjectLimits.maxFileBytes) {
    throw const FormatException('Projekt je větší než povolených 128 MiB.');
  }
  final bytes = file.readAsBytesSync();
  final after = file.statSync();
  if (after.type != FileSystemEntityType.file ||
      before.size != after.size ||
      before.modified != after.modified ||
      before.changed != after.changed ||
      bytes.length != after.size) {
    throw ProjectFileConflict(file.path);
  }
  return (bytes, _token(after, bytes));
}

String _token(FileStat stat, Uint8List bytes) => _tokenData((
  size: stat.size,
  modified: stat.modified.microsecondsSinceEpoch,
  bytes: bytes,
));

String _tokenData(({int size, int modified, Uint8List bytes}) data) {
  // A stable content checksum catches equal-size edits with preserved timestamps.
  var checksum = 0xcbf29ce484222325;
  for (final byte in data.bytes) {
    checksum = (checksum ^ byte) * 0x100000001b3;
  }
  return '${data.size}:${data.modified}:${checksum.toRadixString(16)}';
}
