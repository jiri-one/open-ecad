// SPDX-License-Identifier: GPL-3.0-or-later
import 'project_file_types.dart';
import 'project_files_native.dart'
    if (dart.library.js_interop) 'project_files_web.dart'
    as platform;

export 'project_file_types.dart';

ProjectFiles createProjectFiles() => platform.PlatformProjectFiles();
