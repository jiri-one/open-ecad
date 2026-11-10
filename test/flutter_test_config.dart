import 'dart:async';

import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/services/project_storage_web.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  ProjectPersistence.storageFactory = PreferencesProjectStorage.new;
  await testMain();
}
