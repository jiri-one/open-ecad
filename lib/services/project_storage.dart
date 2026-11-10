// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'project_storage_native.dart'
    if (dart.library.js_interop) 'project_storage_browser.dart'
    as platform;

abstract class ProjectStorage {
  Future<void> write(
    String id,
    String source, {
    required String? expectedToken,
    Uint8List? bytes,
  });
  Future<String?> read(String id);
  Future<String?> readHeader(String id);
  Future<List<String>> list();
  Future<void> remove(String id, {required String? expectedToken});
}

ProjectStorage createProjectStorage() => platform.createProjectStorage();

class ProjectStorageConflict implements Exception {
  const ProjectStorageConflict(this.id);
  final String id;

  @override
  String toString() =>
      'Projekt se mezitím změnil v jiném okně. Pokračujte v nové místní kopii.';
}

void validateProjectStorageId(String id) {
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id) || id == 'index') {
    throw const FormatException('Neplatný identifikátor projektu.');
  }
}

const projectStorageHeaderEnd = ',"project":';

String projectStorageHeader(String source) {
  final end = source.indexOf('\n');
  if (end >= 0) {
    final firstLine = source.substring(0, end);
    if (firstLine.endsWith(projectStorageHeaderEnd)) return firstLine;
  }
  return source;
}

Map<String, dynamic> projectStorageMetadata(String source) {
  var header = projectStorageHeader(source);
  if (header.endsWith(projectStorageHeaderEnd)) {
    header =
        '${header.substring(0, header.length - projectStorageHeaderEnd.length)}}';
  }
  final record = jsonDecode(header);
  if (record is! Map<String, dynamic>) {
    throw const FormatException('Místní projekt je poškozený.');
  }
  return record;
}

String? projectStorageToken(String? source) {
  if (source == null) return null;
  final token = projectStorageMetadata(source)['storageToken'];
  if (token != null && (token is! String || token.isEmpty)) {
    throw const FormatException('Neplatná verze místního projektu.');
  }
  return token as String?;
}
