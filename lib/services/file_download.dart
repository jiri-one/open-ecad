// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'file_download_native.dart'
    if (dart.library.js_interop) 'file_download_web.dart'
    as platform;

/// Saves through a native file dialog, or a browser download on the web.
Future<String?> saveFileBytes(
  Uint8List bytes, {
  required String fileName,
  required String mimeType,
  required String extension,
}) => platform.saveFileBytes(
  bytes,
  fileName: fileName,
  mimeType: mimeType,
  extension: extension,
);
