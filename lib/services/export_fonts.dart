// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/services.dart';

class ExportFonts {
  ExportFonts._(this.regular, this.bold);
  final ByteData regular, bold;
  static Future<ExportFonts>? _pending;
  static ExportFonts? _loaded;
  static ExportFonts? get loaded => _loaded;

  static Future<ExportFonts> load() => _pending ??= _load();

  static Future<ExportFonts> _load() async {
    try {
      final regular = await rootBundle.load(
        'assets/fonts/NotoSans-Regular.ttf',
      );
      final bold = await rootBundle.load('assets/fonts/NotoSans-SemiBold.ttf');
      // Headless rendering must use the same metrics as the app's bundled font.
      final loader =
          FontLoader('NotoSans')
            ..addFont(Future.value(regular))
            ..addFont(Future.value(bold));
      await loader.load();
      return _loaded = ExportFonts._(regular, bold);
    } catch (_) {
      _pending = null;
      rethrow;
    }
  }

  String get svgStyle {
    String face(ByteData data, int weight) =>
        '@font-face{font-family:"Noto Sans";font-weight:$weight;'
        'src:url(data:font/ttf;base64,${base64Encode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))}) format("truetype");}';
    return '<style>${face(regular, 400)}${face(bold, 600)}</style>';
  }
}
