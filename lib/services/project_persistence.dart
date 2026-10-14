// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'file_download.dart';
import 'provider_settings.dart';
import 'pdf_import.dart';

class AutosaveTooLargeException implements Exception {
  const AutosaveTooLargeException();
}

EcadProject _decodeProject(String source) =>
    ProjectPersistence().decode(source);
String _encodeProject(EcadProject project) => jsonEncode(project.toJson());

/// Portable, versioned project files and a single local recovery copy.
/// Provider settings contain a URL and model name only; never API credentials.
class ProjectPersistence {
  static const autosaveKey = 'open_ecad.autosave.v1';
  static const settingsKey = 'open_ecad.ollama.v1';
  static const maxFileBytes = ProjectLimits.maxFileBytes;
  static const maxAutosaveBytes = 2 * 1024 * 1024;

  Future<void> _autosaveQueue = Future<void>.value();
  List<String> pdfImportWarnings = const [];

  String encode(EcadProject project) => jsonEncode(project.toJson());

  EcadProject decode(String source) {
    if (utf8.encode(source).length > maxFileBytes) {
      throw const FormatException('Projekt je větší než povolených 128 MiB.');
    }
    final project = EcadProject.fromJson(jsonDecode(source));
    requireValidProject(project);
    return project;
  }

  Future<EcadProject?> open() async {
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
    if (await file.length() > maxFileBytes) {
      throw const FormatException('Projekt je větší než povolených 128 MiB.');
    }
    return compute(_decodeProject, await file.readAsString());
  }

  Future<EcadProject?> importPdf() async {
    pdfImportWarnings = const [];
    if (kIsWeb) {
      final converted = await convertPdfToProject('');
      return compute(_decodeProject, converted.projectJson);
    }
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'PDF',
          extensions: ['pdf'],
          mimeTypes: ['application/pdf'],
        ),
      ],
    );
    if (file == null) return null;
    if (await file.length() > maxFileBytes) {
      throw const FormatException('PDF je větší než povolených 128 MiB.');
    }
    final converted = await convertPdfToProject(file.path);
    pdfImportWarnings = converted.warnings;
    return compute(_decodeProject, converted.projectJson);
  }

  Future<String?> save(EcadProject project) async {
    final encoded = await compute(_encodeProject, project);
    final bytes = Uint8List.fromList(utf8.encode(encoded));
    if (bytes.length > maxFileBytes) {
      throw const FormatException('Projekt je větší než povolených 128 MiB.');
    }
    return saveBytes(
      bytes,
      fileName: '${safeFileName(project.name)}.oecad',
      mimeType: 'application/json',
      extension: 'oecad',
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

  Future<void> saveAutosave(EcadProject project) {
    // Preference storage has small quotas on browsers. Do not repeatedly
    // serialize hundreds of thousands of primitives or leave an older recovery
    // document behind while claiming that a large import was saved.
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
            : encode(project);
    final tooLarge =
        json == null || utf8.encode(json).length > maxAutosaveBytes;
    // Serializing writes prevents a slower older revision replacing a new one.
    final next = _autosaveQueue.then((_) async {
      final preferences = await SharedPreferences.getInstance();
      if (tooLarge) {
        await preferences.remove(autosaveKey);
        throw const AutosaveTooLargeException();
      }
      if (!await preferences.setString(autosaveKey, json)) {
        throw StateError('Automatické uložení se nezdařilo.');
      }
    });
    _autosaveQueue = next.catchError((Object _) {});
    return next;
  }

  Future<EcadProject?> loadAutosave() async {
    await _autosaveQueue;
    final preferences = await SharedPreferences.getInstance();
    final source = preferences.getString(autosaveKey);
    return source == null ? null : decode(source);
  }

  Future<void> clearAutosave() async {
    await _autosaveQueue;
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(autosaveKey);
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
