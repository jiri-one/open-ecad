// SPDX-License-Identifier: GPL-3.0-or-later
class PdfConversion {
  const PdfConversion(this.projectJson, {this.warnings = const []});
  final String projectJson;
  final List<String> warnings;
}
