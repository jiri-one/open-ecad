// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import 'file_download.dart';

typedef FrameFileReader = Future<String?> Function();
typedef FrameFileWriter =
    Future<String?> Function(
      String source,
      String name,
      bool Function() canCommit,
    );

class FrameTemplateFiles {
  const FrameTemplateFiles({this.read = _read, this.write = _write});

  final FrameFileReader read;
  final FrameFileWriter write;
  static const maxBytes = 1024 * 1024;
  static const fileType = XTypeGroup(
    label: 'Šablona rámečku Open ECAD',
    extensions: ['oecadframe'],
    mimeTypes: ['application/json'],
  );

  Future<FrameTemplate?> importTemplate({
    required bool Function() canCommit,
  }) async {
    final source = await read();
    _check(canCommit);
    if (source == null) return null;
    if (utf8.encode(source).length > maxBytes) {
      throw const FormatException('Šablona je větší než 1 MiB.');
    }
    return FrameTemplateCodec.decode(source).copyWith(id: newId('frame'));
  }

  Future<String?> exportTemplate(
    FrameTemplate template, {
    required bool Function() canCommit,
  }) async {
    final source = FrameTemplateCodec.encode(template);
    _check(canCommit);
    final name = template.name.replaceAll(
      RegExp(r'[^\p{L}\p{N}_-]+', unicode: true),
      '_',
    );
    return write(
      source,
      '${name.isEmpty ? 'ramecek' : name}.oecadframe',
      canCommit,
    );
  }

  static void _check(bool Function() canCommit) {
    if (!canCommit()) {
      throw const FormatException(
        'Projekt se mezitím změnil. Otevřete nastavení znovu.',
      );
    }
  }

  static Future<String?> _read() async {
    final file = await openFile(acceptedTypeGroups: [fileType]);
    if (file == null) return null;
    if (await file.length() > maxBytes) {
      throw const FormatException('Šablona je větší než 1 MiB.');
    }
    return file.readAsString();
  }

  static Future<String?> _write(
    String source,
    String name,
    bool Function() canCommit,
  ) async {
    final bytes = Uint8List.fromList(utf8.encode(source));
    if (kIsWeb) {
      _check(canCommit);
      return saveFileBytes(
        bytes,
        fileName: name,
        mimeType: 'application/json',
        extension: 'oecadframe',
      );
    }
    final location = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: [fileType],
    );
    _check(canCommit);
    if (location == null) return null;
    await XFile.fromData(
      bytes,
      mimeType: 'application/json',
      name: name,
    ).saveTo(location.path);
    return location.path;
  }
}
