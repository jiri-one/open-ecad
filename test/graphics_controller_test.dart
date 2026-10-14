// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/services/provider_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

DrawingElement _text({String id = 'text'}) => DrawingElement(
  id: id,
  kind: DrawingKind.text,
  position: const Vec2(40, 50),
  width: 100,
  height: 14,
  text: 'Přívod',
  fill: '#000000',
);

EcadProject _project() => EcadProject(
  id: 'pdf',
  name: 'Import',
  pages: [
    Sheet(
      id: 'page',
      name: 'Schéma',
      number: '1',
      width: 1191.05,
      height: 842.39,
      showFrame: false,
      sourcePage: 1,
      graphics: [_text()],
      devices: const [
        Device(
          id: 'device',
          kind: DeviceKind.terminal,
          designation: '-X1',
          position: Vec2(200, 200),
        ),
      ],
    ),
  ],
);

class _PdfPersistence extends ProjectPersistence {
  final result = Completer<EcadProject?>();
  @override
  Future<EcadProject?> importPdf() => result.future;
  @override
  Future<void> saveAutosave(EcadProject project) async {}
}

class _DelayedStartup extends ProjectPersistence {
  final settings = Completer<AiProviderSettings?>();
  @override
  Future<AiProviderSettings?> loadAiSettings() => settings.future;
  @override
  Future<EcadProject?> loadAutosave() async => _project();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'late startup recovery does not overwrite edits made during initialization',
    () async {
      final persistence = _DelayedStartup();
      final app = EditorController(persistence: persistence);
      addTearDown(app.dispose);
      final initializing = app.initialize();
      app.renameProject('Novější práce');
      persistence.settings.complete(null);
      await initializing;
      expect(app.project.name, 'Novější práce');
      expect(app.canUndo, isTrue);
    },
  );

  test(
    'whole imported page can rotate beyond the transaction command count',
    () {
      final project = _project().copyWith(
        pages: [
          _project().pages.single.copyWith(
            devices: [],
            graphics: List.generate(2001, (i) => _text(id: 'graphic$i')),
          ),
        ],
      );
      final app = EditorController(initialProject: project);
      addTearDown(app.dispose);
      app.selectAll();
      app.rotateSelection();
      expect(app.sheet.graphics.every((g) => g.rotation == 90), isTrue);
      app.undo();
      expect(app.sheet.graphics.every((g) => g.rotation == 0), isTrue);
    },
  );

  test(
    'mixed selection moves, duplicates, rotates and deletes in atomic undo steps',
    () {
      final app = EditorController(initialProject: _project());
      addTearDown(app.dispose);
      app.selectAll();
      expect(app.selectedIds, {'device', 'text'});
      app.moveSelection(
        devices: {'device': const Vec2(220, 230)},
        graphics: {'text': const Vec2(60, 80)},
      );
      expect(app.sheet.devices.single.position, const Vec2(220, 230));
      expect(app.sheet.graphics.single.position, const Vec2(60, 80));
      app.undo();
      expect(app.sheet.devices.single.position, const Vec2(200, 200));
      expect(app.sheet.graphics.single.position, const Vec2(40, 50));
      app.duplicateSelection();
      expect(app.sheet.devices, hasLength(2));
      expect(app.sheet.graphics, hasLength(2));
      expect(app.sheet.graphics.last.id, isNot('text'));
      expect(app.sheet.graphics.last.text, 'Přívod');
      expect(
        app.sheet.graphics.last.position - app.sheet.graphics.first.position,
        app.sheet.devices.last.position - app.sheet.devices.first.position,
      );
      app.undo();
      expect(app.sheet.devices, hasLength(1));
      expect(app.sheet.graphics, hasLength(1));
      app.rotateSelection();
      expect(app.sheet.devices.single.rotation, 90);
      expect(app.sheet.graphics.single.rotation, 90);
      app.undo();
      app.deleteSelection();
      expect(app.sheet.devices, isEmpty);
      expect(app.sheet.graphics, isEmpty);
      app.undo();
      expect(app.sheet.graphics.single.text, 'Přívod');
      expect(app.sheet.devices.single.designation, '-X1');
    },
  );

  test(
    'new graphic is selected for editing and text update survives serialization',
    () {
      final app = EditorController(initialProject: _project());
      addTearDown(app.dispose);
      app.setMode(CanvasMode.drawText);
      app.createGraphic(_text(id: 'added'));
      expect(app.mode, CanvasMode.select);
      expect(app.sidePanel, SidePanel.properties);
      expect(app.selectedIds, {'added'});
      expect(
        app.updateGraphic(
          app.selectedGraphics.single.copyWith(text: 'Čerpadlo 2'),
        ),
        isTrue,
      );
      final persistence = ProjectPersistence();
      final restored = persistence.decode(persistence.encode(app.project));
      expect(restored.pages.single.graphics.last.text, 'Čerpadlo 2');
      expect(restored.pages.single.sourcePage, 1);
      expect(restored.pages.single.width, 1191.05);
      app.undo();
      expect(app.selectedGraphics.single.text, 'Přívod');
    },
  );

  test(
    'PDF import opens an unsaved drawing with the source paper and no grid',
    () async {
      final persistence = _PdfPersistence();
      final app = EditorController(persistence: persistence);
      addTearDown(app.dispose);
      app.setMode(CanvasMode.wire);
      final importing = app.openProject(importPdf: true);
      expect(app.ioBusy, isTrue);
      persistence.result.complete(_project());
      await importing;
      expect(app.dirty, isTrue);
      expect(app.ioBusy, isFalse);
      expect(app.mode, CanvasMode.select);
      expect(app.showGrid, isFalse);
      expect(app.status, contains('bez elektrických vazeb'));
    },
  );

  test('late PDF result cannot replace edits made during conversion', () async {
    final persistence = _PdfPersistence();
    final app = EditorController(persistence: persistence);
    addTearDown(app.dispose);
    final importing = app.openProject(importPdf: true);
    app.renameProject('Novější práce');
    persistence.result.complete(_project());
    await importing;
    expect(app.project.name, 'Novější práce');
    expect(app.status, contains('projekt se během'));
  });

  test(
    'oversized recovery clears stale document and subsequent small autosave succeeds',
    () async {
      final persistence = ProjectPersistence();
      await persistence.saveAutosave(_project());
      final large = _project().copyWith(
        pages: [
          _project().pages.single.copyWith(
            graphics: List.generate(15001, (i) => _text(id: 'g$i')),
          ),
        ],
      );
      await expectLater(
        persistence.saveAutosave(large),
        throwsA(isA<AutosaveTooLargeException>()),
      );
      expect(await persistence.loadAutosave(), isNull);
      await persistence.saveAutosave(_project());
      expect((await persistence.loadAutosave())!.name, 'Import');
    },
  );
}
