// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

class DocumentFileHandle {
  const DocumentFileHandle({required this.path, required this.version});

  final String path;
  final String version;

  Map<String, dynamic> toJson() => {'path': path, 'version': version};

  factory DocumentFileHandle.fromJson(dynamic json) {
    if (json is! Map<String, dynamic> ||
        json['path'] is! String ||
        (json['path'] as String).isEmpty ||
        json['version'] is! String ||
        (json['version'] as String).isEmpty) {
      throw const FormatException('Neplatný odkaz na soubor pracovní kopie.');
    }
    return DocumentFileHandle(path: json['path'], version: json['version']);
  }
}

class ProjectFileData {
  const ProjectFileData(this.bytes, {this.origin, required this.name});
  final Uint8List bytes;
  final DocumentFileHandle? origin;
  final String name;
}

class SavedProjectFile {
  const SavedProjectFile({this.origin, required this.name});
  final DocumentFileHandle? origin;
  final String name;
}

class ProjectFileConflict implements Exception {
  const ProjectFileConflict(this.path);
  final String path;

  @override
  String toString() =>
      'Soubor se změnil mimo aplikaci nebo již neexistuje: $path. '
      'Místní projekt zůstává zachován. Vytvořte kopii projektu do jiného souboru.';
}

class DocumentOperationSuperseded implements Exception {
  const DocumentOperationSuperseded();
}

abstract class ProjectFiles {
  Future<ProjectFileData?> pick();
  Future<ProjectFileData> readPath(String path);
  Future<SavedProjectFile?> save(
    Uint8List bytes, {
    required String suggestedName,
    required bool Function() canCommit,
    DocumentFileHandle? target,
    DocumentFileHandle? currentFile,
    Iterable<String> Function()? protectedPaths,
  });
}
