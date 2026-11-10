import 'dart:async';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/pointer_warp.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'continuation_fixtures.dart';

void linuxTestWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    callback,
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(PointerWarp.channel, null);
  });

  for (final otherSheet in [false, true]) {
    linuxTestWidgets(
      'F sends one verified view target after reveal (other sheet=$otherSheet)',
      (tester) async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(PointerWarp.channel, (call) async {
          calls.add(call);
          return true;
        });
        final app = continuationController(
          continuationProject(
            sameSheet: otherSheet ? 0 : 1,
            otherSheet: otherSheet ? 1 : 0,
          ),
        );
        await mountContinuations(tester, app);
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = const Size(3400, 2200);
        await tester.pumpAndSettle();
        await selectContinuation(tester, app);
        final before = app.project;
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        expect(calls, isEmpty);
        await tester.pump();
        expect(calls, isEmpty);
        await tester.pumpAndSettle();
        expect(calls, hasLength(1));
        final marker =
            app.sheet.continuationById(otherSheet ? 'other-0' : 'same-0')!;
        final point = continuationPoint(tester, app, marker.position);
        final args = calls.single.arguments as Map;
        expect(args['x'], closeTo(point.dx, 0.01));
        expect(args['y'], closeTo(point.dy, 0.01));
        expect(args['devicePixelRatio'], 2);
        expect(args['physicalWidth'], 3400);
        expect(args['physicalHeight'], 2200);
        expect(args['viewId'], tester.view.viewId);
        expect(app.status, contains('ukazatel myši na cíli'));
        expect(app.project, same(before));
        expect(app.dirty, isFalse);
        expect(app.canUndo, isFalse);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'Schematic canvas',
        );
        await unmountContinuations(tester);
      },
    );
  }

  for (final missing in [false, true]) {
    linuxTestWidgets(
      'fallback retains target and keyboard focus (missing plugin=$missing)',
      (tester) async {
        messenger.setMockMethodCallHandler(PointerWarp.channel, (_) async {
          if (missing) throw MissingPluginException();
          return false;
        });
        final app = continuationController();
        await mountContinuations(tester, app);
        await selectContinuation(tester, app);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pumpAndSettle();
        expect(app.selectedIds, {'same-0'});
        expect(
          app.viewport.continuationFocus,
          app.sheet.continuationById('same-0')!.position,
        );
        expect(
          find.byKey(const ValueKey('continuation-focus')),
          findsOneWidget,
        );
        expect(app.status, contains('přesun ukazatele myši nepotvrzen'));
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'Schematic canvas',
        );
        expect(app.dirty, isFalse);
        expect(app.canUndo, isFalse);
        await unmountContinuations(tester);
      },
    );
  }

  for (final phase in ['before-send', 'late-result']) {
    for (final change in [
      'switch-back',
      'replace',
      'delete',
      'revision',
      'sheet',
      'close',
      'new-follow',
    ]) {
      if (phase == 'before-send' && change == 'new-follow') continue;
      linuxTestWidgets('$phase rejects stale $change', (tester) async {
        final reply = Completer<bool>();
        var calls = 0;
        messenger.setMockMethodCallHandler(PointerWarp.channel, (_) {
          calls++;
          return calls == 1 ? reply.future : Future.value(false);
        });
        final app = continuationController();
        final workspace = await mountContinuations(tester, app);
        await selectContinuation(tester, app);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pump();
        if (phase == 'late-result') {
          await tester.pump();
          expect(calls, 1);
        } else {
          expect(calls, 0);
        }
        switch (change) {
          case 'switch-back':
            final b = continuationController(
              app.project.copyWith(name: 'Second owner'),
            );
            workspace.add(b);
            workspace.openSheet(app, 'source-sheet');
          case 'replace':
            app.newProject();
          case 'delete':
            app.execute([
              DeleteContinuationMarker('source-sheet', 'same-0'),
            ], 'remove target');
          case 'revision':
            app.execute([
              UpdateContinuationMarker(
                'source-sheet',
                app.sheet
                    .continuationById('source')!
                    .copyWith(position: const Vec2(1100, 800)),
              ),
            ], 'edit');
          case 'sheet':
            workspace.openSheet(app, 'target-sheet');
          case 'close':
            workspace.add(
              continuationController(app.project.copyWith(name: 'Other owner')),
            );
            await workspace.closeDocument(app);
          case 'new-follow':
            await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        }
        await tester.pumpAndSettle();
        final status = workspace.active.status;
        reply.complete(true);
        await tester.pumpAndSettle();
        if (change != 'new-follow') {
          expect(calls, phase == 'late-result' ? 1 : 0);
          expect(workspace.active.status, status);
        }
        expect(
          workspace.active.status,
          isNot(contains('ukazatel myši na cíli')),
        );
        await unmountContinuations(tester);
      });
    }
  }

  for (final block in ['dialog', 'text', 'gesture', 'drawing', 'inactive']) {
    linuxTestWidgets('queued pointer request is suppressed by $block', (
      tester,
    ) async {
      var calls = 0;
      messenger.setMockMethodCallHandler(PointerWarp.channel, (_) async {
        calls++;
        return true;
      });
      final app = continuationController();
      await mountContinuations(tester, app, panel: block == 'text');
      await selectContinuation(tester, app);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      TestGesture? gesture;
      switch (block) {
        case 'dialog':
          unawaited(
            showDialog<void>(
              context: tester.element(find.byType(EditorWorkspace)),
              builder: (_) => const AlertDialog(content: TextField()),
            ),
          );
        case 'text':
          final field = find.byType(TextField).last;
          await tester.tap(field);
        case 'gesture':
          gesture = await tester.startGesture(
            continuationPoint(tester, app, const Vec2(1350, 800)),
          );
        case 'drawing':
          app.setMode(CanvasMode.wire);
        case 'inactive':
          binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      }
      await tester.pumpAndSettle();
      expect(calls, 0);
      if (gesture != null) await gesture.up();
      if (block == 'inactive') {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
      await unmountContinuations(tester);
    });
  }
  for (final block in [
    'dialog',
    'text',
    'gesture',
    'drawing',
    'inactive',
    'unmount',
  ]) {
    linuxTestWidgets(
      'late native success cannot overwrite status after $block',
      (tester) async {
        final reply = Completer<bool>();
        var calls = 0;
        messenger.setMockMethodCallHandler(PointerWarp.channel, (_) {
          calls++;
          return reply.future;
        });
        final app = continuationController();
        await mountContinuations(tester, app, panel: block == 'text');
        await selectContinuation(tester, app);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pump();
        await tester.pump();
        expect(calls, 1);
        TestGesture? gesture;
        switch (block) {
          case 'dialog':
            unawaited(
              showDialog<void>(
                context: tester.element(find.byType(EditorWorkspace)),
                builder: (_) => const AlertDialog(content: TextField()),
              ),
            );
          case 'text':
            await tester.tap(find.byType(TextField).last);
          case 'gesture':
            gesture = await tester.startGesture(
              continuationPoint(tester, app, const Vec2(1350, 800)),
            );
          case 'drawing':
            app.setMode(CanvasMode.wire);
          case 'inactive':
            binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          case 'unmount':
            await unmountContinuations(tester);
        }
        if (block != 'unmount') app.reportStatus('New interaction');
        await tester.pump();
        reply.complete(true);
        await tester.pumpAndSettle();
        if (block != 'unmount') expect(app.status, 'New interaction');
        if (gesture != null) await gesture.up();
        if (block == 'inactive') {
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        }
        await unmountContinuations(tester);
      },
    );
  }
}
