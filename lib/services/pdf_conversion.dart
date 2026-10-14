// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';

class PdfConversion {
  const PdfConversion(this.projectJson, {this.warnings = const []});
  final String projectJson;
  final List<String> warnings;
}

/// Tells the user which sheet types were guessed, since titles can mislead.
/// Reports from converters without type detection produce no note.
String? sheetTypeImportNote(Object? summary) {
  if (summary is! Map || summary['classified'] is! Map) return null;
  final classified = (summary['classified'] as Map).values
      .whereType<int>()
      .fold<int>(0, (total, count) => total + count);
  final unclassified = summary['unclassified'];
  if (classified == 0 || unclassified is! int) return null;
  return 'Typ listu je odhadnutý z názvu stránky v záložkách PDF u '
      '$classified z ${classified + unclassified} listů. Ostatní mají výchozí '
      'typ ${SheetType.legacyDefault.label.toLowerCase()}. Typ lze změnit '
      've vlastnostech listu.';
}
