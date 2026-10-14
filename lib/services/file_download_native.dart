// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

Future<String?> saveFileBytes(
  Uint8List bytes, {
  required String fileName,
  required String mimeType,
  required String extension,
}) async {
  final location = await getSaveLocation(
    suggestedName: fileName,
    acceptedTypeGroups: [
      XTypeGroup(label: extension.toUpperCase(), extensions: [extension]),
    ],
  );
  if (location == null) return null;
  final file = XFile.fromData(bytes, mimeType: mimeType, name: fileName);
  await file.saveTo(location.path);
  return location.path;
}
