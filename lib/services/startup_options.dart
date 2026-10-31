// SPDX-License-Identifier: GPL-3.0-or-later
class StartupOptions {
  const StartupOptions({this.projectPath, this.error});
  final String? projectPath;
  final String? error;
  bool get explicitRequest => projectPath != null || error != null;

  factory StartupOptions.parse(List<String> args, {bool isWeb = false}) {
    if (args.isEmpty) return const StartupOptions();
    if (isWeb) {
      return const StartupOptions(
        error: '--project není dostupný ve webové aplikaci.',
      );
    }
    final String path;
    if (args.length == 2 && args.first == '--project') {
      path = args.last;
    } else if (args.length == 1 && args.first.startsWith('--project=')) {
      path = args.first.substring('--project='.length);
    } else {
      return const StartupOptions(
        error: 'Očekáván argument --project <cesta.oecad>.',
      );
    }
    if (path.trim().isEmpty ||
        path.startsWith('--') ||
        path.contains('\u0000')) {
      return const StartupOptions(
        error: 'Argument --project vyžaduje cestu k souboru.',
      );
    }
    return StartupOptions(projectPath: path);
  }
}
