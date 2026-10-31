import 'dart:async';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/pointer_warp.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'continuation_fixtures.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => messenger.setMockMethodCallHandler(PointerWarp.channel, null));

  for (final lateResult in [false, true]) {
    testWidgets(
      'Escape cancels a pending follow (request already sent=$lateResult)',
      (tester) async {
        final reply = Completer<bool>();
        var calls = 0;
        messenger.setMockMethodCallHandler(PointerWarp.channel, (_) {
          calls++;
          return reply.future;
        });
        final app = continuationController();
        await mountContinuations(tester, app);
        await selectContinuation(tester, app);
        final original = app.project;
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pump();
        expect(calls, 0);
        if (lateResult) {
          await tester.pump();
          expect(calls, 1);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        final status = app.status;
        expect(app.viewport.continuationFocus, isNull);
        await tester.pump();
        expect(calls, lateResult ? 1 : 0);
        reply.complete(true);
        await tester.pumpAndSettle();
        expect(app.status, status);
        expect(app.project, same(original));
        expect(app.canUndo, isFalse);
        await unmountContinuations(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  }

  testWidgets(
    'opening and closing the editor invalidates an older pointer result',
    (tester) async {
      final reply = Completer<bool>();
      messenger.setMockMethodCallHandler(
        PointerWarp.channel,
        (_) => reply.future,
      );
      final app = continuationController();
      await mountContinuations(tester, app);
      await selectContinuation(tester, app);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await continuationClick(tester, 'Zrušit');
      final status = app.status;
      reply.complete(true);
      await tester.pumpAndSettle();
      expect(app.status, status);
      expect(app.status, isNot(contains('ukazatel myši na cíli')));
      await unmountContinuations(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  for (final lateResult in [false, true]) {
    testWidgets(
      'a new status with identical text still invalidates follow (sent=$lateResult)',
      (tester) async {
        final reply = Completer<bool>();
        var calls = 0;
        messenger.setMockMethodCallHandler(PointerWarp.channel, (_) {
          calls++;
          return reply.future;
        });
        final app = continuationController();
        await mountContinuations(tester, app);
        await selectContinuation(tester, app);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pump();
        if (lateResult) await tester.pump();
        final status = app.status;
        app.reportStatus(status);
        await tester.pump();
        expect(calls, lateResult ? 1 : 0);
        reply.complete(true);
        await tester.pumpAndSettle();
        expect(app.status, status);
        await unmountContinuations(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  }

  testWidgets(
    'a new click cancels follow before its deferred pointer request',
    (tester) async {
      var calls = 0;
      messenger.setMockMethodCallHandler(PointerWarp.channel, (_) async {
        calls++;
        return true;
      });
      final app = continuationController();
      await mountContinuations(tester, app);
      await selectContinuation(tester, app);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      final selected = app.selectedIds.toSet();
      await tester.tapAt(continuationPoint(tester, app, const Vec2(1350, 800)));
      await tester.pumpAndSettle();
      expect(app.selectedIds, selected);
      expect(calls, 0);
      expect(app.status, isNot(contains('ukazatel myši na cíli')));
      await unmountContinuations(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
