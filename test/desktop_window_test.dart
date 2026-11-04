import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/desktop_window.dart';
import 'package:open_ecad/widgets/project_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

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
      final app = EditorController(
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
      await tester.tap(find.byTooltip('Zavřít okno'));
      expect(calls.last.method, 'close');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
