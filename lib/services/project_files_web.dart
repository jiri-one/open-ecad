// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:ecad_core/ecad_core.dart';
import 'package:file_selector/file_selector.dart';

import 'file_download_web.dart';
import 'project_file_types.dart';

class PlatformProjectFiles implements ProjectFiles {
  @override
  Future<ProjectFileData?> pick() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Open ECAD project',
          extensions: ['oecad', 'json'],
          mimeTypes: ['application/json', 'application/octet-stream'],
        ),
      ],
    );
    if (file == null) return null;
    if (await file.length() > ProjectLimits.maxFileBytes) {
      throw const FormatException('Projekt je větší než povolených 128 MiB.');
    }
    return ProjectFileData(await file.readAsBytes(), name: file.name);
  }

  @override
  Future<ProjectFileData> readPath(String path) =>
      throw UnsupportedError('--project není dostupný ve webové aplikaci.');

  @override
  Future<SavedProjectFile?> save(
    Uint8List bytes, {
    required String suggestedName,
    required bool Function() canCommit,
    DocumentFileHandle? target,
    DocumentFileHandle? currentFile,
    Iterable<String> Function()? protectedPaths,
  }) async {
    if (!canCommit()) throw const DocumentOperationSuperseded();
    final name = await saveFileBytes(
      bytes,
      fileName: suggestedName,
      mimeType: 'application/json',
      extension: 'oecad',
    );
    return name == null ? null : SavedProjectFile(name: name);
  }
}
