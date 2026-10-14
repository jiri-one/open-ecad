// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<String?> saveFileBytes(
  Uint8List bytes, {
  required String fileName,
  required String mimeType,
  required String extension,
}) async {
  final blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  final link =
      web.HTMLAnchorElement()
        ..href = url
        ..download = fileName;
  web.document.body?.append(link);
  link.click();
  link.remove();
  // Revoking synchronously can abort downloads in some browsers.
  Timer(const Duration(seconds: 5), () => web.URL.revokeObjectURL(url));
  return fileName;
}
