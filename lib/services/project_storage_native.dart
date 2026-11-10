// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'project_storage.dart';
import 'project_storage_web.dart' show PreferencesProjectStorage;

ProjectStorage createProjectStorage() => FileProjectStorage();

String? _readFile(String path) {
  final file = File(path);
  return file.existsSync() ? file.readAsStringSync() : null;
}

String? _readHeader(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final input = file.openSync();
  final bytes = BytesBuilder(copy: false);
  try {
    while (true) {
      final chunk = input.readSync(4096);
      if (chunk.isEmpty) return utf8.decode(bytes.takeBytes());
      final end = chunk.indexOf(10);
      if (end >= 0) {
        bytes.add(Uint8List.sublistView(chunk, 0, end));
        final header = utf8.decode(bytes.takeBytes());
        return header.endsWith(projectStorageHeaderEnd)
            ? header
            : file.readAsStringSync();
      }
      bytes.add(chunk);
    }
  } finally {
    input.closeSync();
  }
}

Uint8List _encodeBytes(String source) => utf8.encode(source);

class FileProjectStorage implements ProjectStorage {
  FileProjectStorage({Future<Directory> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;
  final _previousStorage = PreferencesProjectStorage();
  static Future<void> _writes = Future.value();

  Future<void> _withLock(File file, Future<void> Function() action) {
    // POSIX file locks do not serialize callers in the same process.
    final next = _writes.then((_) async {
      await file.parent.create(recursive: true);
      final lock = await File('${file.path}.lock').open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        await action();
      } finally {
        try {
          await lock.close();
        } on FileSystemException {
          // A cleanup failure must not hide an acknowledged commit.
        }
      }
    });
    _writes = next.catchError((Object _) {});
    return next;
  }

  static Future<Directory> _defaultDirectory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/projects');

  Future<File> _file(String id) async {
    validateProjectStorageId(id);
    return File('${(await _directory()).path}/$id.json');
  }

  @override
  Future<void> write(
    String id,
    String source, {
    required String? expectedToken,
    Uint8List? bytes,
  }) async {
    final file = await _file(id);
    final Uint8List prepared = bytes ?? await compute(_encodeBytes, source);
    await _withLock(file, () async {
      final header =
          await compute(_readHeader, file.path) ??
          await _previousStorage.readHeader(id);
      if (projectStorageToken(header) != expectedToken) {
        throw ProjectStorageConflict(id);
      }
      final staging = await file.parent.createTemp('.saving-');
      try {
        final temporary = File('${staging.path}/project.json');
        await temporary.writeAsBytes(prepared, flush: true);
        await temporary.rename(file.path);
      } finally {
        try {
          await staging.delete(recursive: true);
        } on FileSystemException {
          // A cleanup failure must not hide an acknowledged commit.
        }
      }
    });
  }

  @override
  Future<String?> read(String id) async {
    final file = await _file(id);
    return await compute(_readFile, file.path) ??
        await _previousStorage.read(id);
  }

  @override
  Future<String?> readHeader(String id) async {
    final file = await _file(id);
    return await compute(_readHeader, file.path) ??
        await _previousStorage.readHeader(id);
  }

  @override
  Future<List<String>> list() async {
    final directory = await _directory();
    final files = <({String id, DateTime modified})>[];
    if (await directory.exists()) {
      await for (final entry in directory.list(followLinks: false)) {
        final name = entry.uri.pathSegments.last;
        if (entry is! File ||
            !RegExp(r'^[a-zA-Z0-9_-]+\.json$').hasMatch(name)) {
          continue;
        }
        final stat = await entry.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        files.add((
          id: name.substring(0, name.length - 5),
          modified: stat.modified,
        ));
      }
    }
    files.sort((a, b) => b.modified.compareTo(a.modified));
    return <String>{
      ...files.map((f) => f.id),
      ...await _previousStorage.list(),
    }.toList();
  }

  @override
  Future<void> remove(String id, {required String? expectedToken}) async {
    final file = await _file(id);
    await _withLock(file, () async {
      final previous = await _previousStorage.readHeader(id);
      final current = await compute(_readHeader, file.path) ?? previous;
      if (projectStorageToken(current) != expectedToken) {
        throw ProjectStorageConflict(id);
      }
      // Delete the fallback first so removing the file cannot resurrect it.
      if (previous != null) {
        await _previousStorage.remove(
          id,
          expectedToken: projectStorageToken(previous),
        );
      }
      if (await file.exists()) await file.delete();
    });
  }
}
