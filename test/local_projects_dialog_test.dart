// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';

EcadProject _project(String name) => EcadProject(
  id: 'synthetic-project',
  name: name,
  pages: [Sheet(id: 'sheet', name: 'Sheet', number: '1')],
);

class _QuotaPersistence extends ProjectPersistence {
  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async {
    if (copy.project.name == 'Unsaved' &&
        (await listRecoveryIds()).contains('closed')) {
      throw StateError('Synthetic quota exceeded');
    }
    return super.saveWorkingCopy(copy, encoded: encoded);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'closed projects can be deleted to recover from a full local store',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final persistence = _QuotaPersistence();
      await persistence.saveWorkingCopy(
        WorkingCopy(_project('Closed'), sessionId: 'closed', savedRevision: 0),
      );
      final app = EditorController(
        initialProject: _project('Unsaved'),
        persistence: persistence,
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(OpenEcadApp(controller: app));
      await tester.pumpAndSettle();
      expect(app.autosaveError, contains('Synthetic quota'));
      await tester.tap(find.byTooltip('Soubor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Místní projekty…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Odstranit místní projekt'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Odstranit'));
      await tester.pumpAndSettle();
      expect(await persistence.loadProjectSummary('closed'), isNull);
      await tester.tap(find.widgetWithText(TextButton, 'Zavřít'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Zkusit automatické uložení znovu'));
      await tester.pumpAndSettle();
      expect(app.changesSaved, isTrue);
      expect(app.autosaveError, isNull);
      expect(
        (await persistence.loadAutosave(
          sessionId: app.documentSessionId,
        ))!.project.name,
        'Unsaved',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
