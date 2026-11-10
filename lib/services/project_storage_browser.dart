// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'project_storage.dart';
import 'project_storage_web.dart';

ProjectStorage createProjectStorage() => BrowserProjectStorage();

class BrowserProjectStorage extends PreferencesProjectStorage {
  Future<void> _withLock(Future<void> Function() action) async {
    Object? failure;
    StackTrace? trace;
    Future<void> run() async {
      try {
        await action();
      } catch (error, stack) {
        // JS promise rejection would erase the Dart exception's type.
        failure = error;
        trace = stack;
      }
    }

    await web.window.navigator.locks
        .request('open-ecad.projects', ((web.Lock _) => run().toJS).toJS)
        .toDart;
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }

  @override
  Future<void> write(
    String id,
    String source, {
    required String? expectedToken,
    Uint8List? bytes,
  }) => _withLock(
    () => super.write(id, source, expectedToken: expectedToken, bytes: bytes),
  );

  @override
  Future<void> remove(String id, {required String? expectedToken}) =>
      _withLock(() => super.remove(id, expectedToken: expectedToken));
}
