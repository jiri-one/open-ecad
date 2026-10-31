import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'app/controller.dart';
import 'app/workspace.dart';
import 'services/startup_options.dart';

SemanticsHandle? _webSemantics;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) _webSemantics ??= SemanticsBinding.instance.ensureSemantics();
  final options = StartupOptions.parse(args, isWeb: kIsWeb);
  final controller = EditorController(startEmpty: options.explicitRequest);
  await controller.initialize(
    startupProjectPath: options.projectPath,
    startupError: options.error,
  );
  runApp(OpenEcadApp(controller: controller));
}
