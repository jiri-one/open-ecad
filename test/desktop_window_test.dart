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
  bool allowSave = false;

  @override
  Future<SavedProjectFile?> saveAs(
    EcadProject project, {
    DocumentFileHandle? currentFile,
    required bool Function() canCommit,
  }) async => allowSave ? const SavedProjectFile(name: 'memory.oecad') : null;
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
        expect(tester.element(find.byType(SchematicCanvas)), same(canvas));
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
      app.renameProject('Edited window test');
      await tester.pump();
      await tester.tap(find.byTooltip('Zavřít okno'));
      expect(calls.last.method, 'close');
      expect(app.dirty, isTrue);
      expect(
        ModalRoute.of(tester.element(find.byType(EditorWorkspace)))?.isCurrent,
        isTrue,
      );
      await event('close');
      expect(app.status, isNot(startsWith('Okno se nepodařilo')));
      expect(find.text('Neuložené změny · Edited window test'), findsOneWidget);
      expect(calls.where((c) => c.method == 'destroy'), isEmpty);
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(app.status, 'Uložení zrušeno');
      expect(calls.where((c) => c.method == 'destroy'), isEmpty);
      await event('close');
      await event('close');
      expect(find.text('Neuložené změny · Edited window test'), findsOneWidget);
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'destroy'), isEmpty);
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
      other.renameProject('Other edited');
      app.renameProject('Changed immediately before close');
      await event('close');
      persistence.allowSave = true;
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(app.dirty, isFalse);
      expect(find.text('Neuložené změny · Other edited'), findsOneWidget);
      expect(calls.where((c) => c.method == 'destroy'), isEmpty);
      other.renameProject('Other changed while confirming');
      await tester.tap(find.text('Zavřít bez uložení'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'destroy'), isEmpty);
      await event('close');
      expect(
        find.text('Neuložené změny · Other changed while confirming'),
        findsOneWidget,
      );
      await tester.tap(find.text('Zavřít bez uložení'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'destroy'), hasLength(1));
      final recovered = await app.persistence.loadAutosave(
        sessionId: app.documentSessionId,
      );
      expect(recovered!.project.name, 'Changed immediately before close');
      expect(recovered.savedRevision, app.project.revision);
      expect(
        (await persistence.loadAutosave(
          sessionId: other.documentSessionId,
        ))!.project.name,
        'Other changed while confirming',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
