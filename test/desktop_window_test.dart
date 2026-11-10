import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/desktop_window.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/widgets/project_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

class _Persistence extends ProjectPersistence {
  bool fail = false;
  String? failName;
  bool allowCopy = false;
  EcadProject? exported;

  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async {
    if (fail || copy.project.name == failName) throw StateError('Disk full');
    return super.saveWorkingCopy(copy, encoded: encoded);
  }

  @override
  Future<SavedProjectFile?> saveAs(
    EcadProject project, {
    DocumentFileHandle? currentFile,
    Iterable<String> Function()? protectedPaths,
    EncodedProject? encoded,
    required bool Function() canCommit,
  }) async {
    if (!allowCopy) throw StateError('Copy unavailable');
    exported = project;
    return const SavedProjectFile(name: 'copy.oecad');
  }
}

void main() {
  testWidgets(
    'custom window chrome keeps editor state through window changes',
    (tester) async {
      const channel = MethodChannel('window_manager');
      const codec = StandardMethodCodec();
      final calls = <MethodCall>[];
      bool maximized = false, fullScreen = false;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'isMaximized' => maximized,
              'isFullScreen' => fullScreen,
              'isMinimized' => false,
              _ => null,
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(960, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await DesktopWindow.initialize();
      expect(calls.first.method, 'ensureInitialized');
      expect(calls.map((c) => c.method), containsAllInOrder(['show', 'focus']));
      expect(
        calls.singleWhere((c) => c.method == 'setTitleBarStyle').arguments,
        {'titleBarStyle': 'hidden', 'windowButtonVisibility': false},
      );
      final persistence = _Persistence();
      final app = EditorController(
        persistence: persistence,
        initialProject: EcadProject(
          id: 'window-test',
          name: 'Window test',
          pages: [Sheet(id: 'sheet', name: 'Sheet', number: '1')],
        ),
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(OpenEcadApp(controller: app));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Zobrazit projekt a knihovnu'));
      await tester.pumpAndSettle();
      final canvas = tester.element(find.byType(SchematicCanvas));
      expect(find.byType(ProjectPanel), findsNothing);
      expect(tester.getRect(find.byType(SchematicCanvas)).top, 40);

      Future<void> event(String name) async {
        ServicesBinding.instance.channelBuffers.push(
          'window_manager',
          codec.encodeMethodCall(MethodCall('onEvent', {'eventName': name})),
          (_) {},
        );
        await tester.pumpAndSettle();
        if (name != 'close') {
          expect(tester.element(find.byType(SchematicCanvas)), same(canvas));
        }
        expect(find.byType(ProjectPanel), findsNothing);
        expect(tester.takeException(), isNull);
      }

      await tester.tap(find.byTooltip('Minimalizovat'));
      expect(calls.last.method, 'minimize');
      await tester.tap(find.byTooltip('Maximalizovat'));
      expect(calls.last.method, 'maximize');
      maximized = true;
      await event('maximize');
      expect(
        tester
            .widget<DragToResizeArea>(find.byType(DragToResizeArea))
            .enableResizeEdges,
        isEmpty,
      );
      await tester.tap(find.byTooltip('Obnovit velikost okna'));
      expect(calls.last.method, 'unmaximize');
      maximized = false;
      await event('unmaximize');
      expect(
        tester
            .widget<DragToResizeArea>(find.byType(DragToResizeArea))
            .enableResizeEdges,
        isNull,
      );
      fullScreen = true;
      await event('enter-full-screen');
      expect(
        tester
            .widget<DragToResizeArea>(find.byType(DragToResizeArea))
            .enableResizeEdges,
        isEmpty,
      );
      fullScreen = false;
      await event('leave-full-screen');
      persistence.fail = true;
      app.renameProject('Edited window test');
      await tester.pump();
      await tester.tap(find.byTooltip('Zavřít okno'));
      expect(calls.last.method, 'close');
      await event('close');
      expect(find.textContaining('Neuložené změny'), findsNothing);
      expect(app.autosaveError, contains('Disk full'));
      expect(calls.where((c) => c.method == 'destroy'), isEmpty);
      await tester.tap(find.text('Pokračovat v úpravách'));
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('Zkusit automatické uložení znovu'),
        findsOneWidget,
      );
      persistence.fail = false;
      await tester.tap(find.byTooltip('Zkusit automatické uložení znovu'));
      await tester.pumpAndSettle();
      expect(app.changesSaved, isTrue);
      final workspace =
          tester
              .widget<EditorWorkspace>(find.byType(EditorWorkspace))
              .workspace!;
      final other = EditorController(
        initialProject: app.project.copyWith(name: 'Other'),
        persistence: persistence,
      );
      workspace.add(other);
      workspace.openSheet(app, app.activeSheetId);
      persistence.failName = 'Other edited';
      other.renameProject('Other edited');
      app.renameProject('Changed immediately before close');
      await event('close');
      expect(workspace.active, same(other));
      expect(calls.where((c) => c.method == 'destroy'), isEmpty);
      await tester.tap(find.text('Pokračovat v úpravách'));
      await tester.pumpAndSettle();
      persistence.failName = null;
      await event('close');
      expect(find.textContaining('Neuložené změny'), findsNothing);
      expect(calls.where((c) => c.method == 'destroy'), hasLength(1));
      expect(
        (await persistence.loadAutosave(
          sessionId: app.documentSessionId,
        ))!.project.name,
        'Changed immediately before close',
      );
      expect(
        (await persistence.loadAutosave(
          sessionId: other.documentSessionId,
        ))!.project.name,
        'Other edited',
      );
      workspace.openSheet(app, app.activeSheetId);
      final before = await persistence.loadProjectSummary(
        app.documentSessionId,
      );
      await event('close');
      expect(calls.where((c) => c.method == 'destroy'), hasLength(2));
      expect(
        (await persistence.loadStartupProject())!.sessionId,
        app.documentSessionId,
      );
      expect(
        (await persistence.loadProjectSummary(
          app.documentSessionId,
        ))!.storageToken,
        before!.storageToken,
      );
      persistence.fail = true;
      app.renameProject('Cannot save');
      await event('close');
      await tester.tap(find.text('Vytvořit kopii a zavřít'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'destroy'), hasLength(2));
      await event('close');
      await tester.tap(find.text('Přesto zavřít'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'destroy'), hasLength(3));
      expect(
        (await persistence.loadAutosave(
          sessionId: app.documentSessionId,
        ))!.project.name,
        'Changed immediately before close',
      );
      app.renameProject('Rescued copy');
      persistence.allowCopy = true;
      await event('close');
      await tester.tap(find.text('Vytvořit kopii a zavřít'));
      await tester.pumpAndSettle();
      expect(persistence.exported!.name, 'Rescued copy');
      expect(calls.where((c) => c.method == 'destroy'), hasLength(4));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
