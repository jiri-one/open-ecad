import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/system_typography.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const channel = MethodChannel('open_ecad/system_typography');

  SystemTypographyService createService() {
    final service = SystemTypographyService();
    addTearDown(service.dispose);
    return service;
  }

  Future<ByteData?> notifyFontChanged() => messenger.handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(const MethodCall('fontChanged')),
    null,
  );

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    binding.platformDispatcher.clearTextScaleFactorTestValue();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('starts with a 14 logical pixel fallback and no family override', () {
    expect(createService().value, const SystemTypography(fontSize: 14));
  });

  test('unsupported platforms and web do not use the native channel', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return {'fontFamily': 'Noto Sans', 'fontSize': 16.0};
    });
    for (final platform in TargetPlatform.values) {
      if (!kIsWeb && platform == TargetPlatform.linux) continue;
      debugDefaultTargetPlatformOverride = platform;
      final service = createService();
      await service.load();
      expect(service.value, const SystemTypography());
    }
    expect(calls, 0);
  });

  group('Linux', skip: kIsWeb, () {
    test(
      'GTK resolution changes reload independently of font family and size',
      () async {
        var scale = 1.5;
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => {
            'fontFamily': 'Noto Sans',
            'fontSize': 16.0,
            'fontScale': scale,
          },
        );
        final service = createService();
        await service.load();
        expect(service.value.fontScale, 1.5);
        scale = 2;
        await notifyFontChanged();
        expect(service.value.fontScale, 2);
        expect(service.value.fontSize, 16);
        for (final invalid in [null, '2', 0, -1, double.nan, double.infinity]) {
          messenger.setMockMethodCallHandler(
            channel,
            (_) async => {
              'fontFamily': 'Noto Sans',
              'fontSize': 16.0,
              'fontScale': invalid,
            },
          );
          await service.load();
          expect(service.value.fontScale, isNull);
        }
      },
    );

    test(
      'keeps native logical pixels independent of system text scale',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {'fontFamily': 'Noto Sans', 'fontSize': 44 / 3};
        });
        final service = createService();
        for (final scale in [1.0, 1.5, 2.0]) {
          binding.platformDispatcher.textScaleFactorTestValue = scale;
          await service.load();
          expect(service.value.fontFamily, 'Noto Sans');
          expect(service.value.fontSize, closeTo(14.6666667, 0.000001));
        }
        expect(calls.map((call) => call.method), everyElement('getFont'));
        expect(calls.map((call) => call.arguments), everyElement(isNull));
      },
    );

    test('reloads font changes and only notifies for changed values', () async {
      var font = {'fontFamily': 'Noto Sans', 'fontSize': 14.0};
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return font;
      });
      final service = createService();
      var notifications = 0;
      service.addListener(() => notifications++);
      await service.load();
      await notifyFontChanged();
      expect(notifications, 1);

      font = {'fontFamily': 'DejaVu Sans', 'fontSize': 18.0};
      await notifyFontChanged();
      expect(calls, 3);
      expect(notifications, 2);
      expect(
        service.value,
        const SystemTypography(fontFamily: 'DejaVu Sans', fontSize: 18),
      );
    });

    test('missing plugin and platform errors fall back safely', () async {
      final service = createService();
      await service.load();
      expect(service.value, const SystemTypography());

      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'fontFamily': 'Noto Sans', 'fontSize': 18.0},
      );
      await service.load();
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'unavailable');
      });
      await notifyFontChanged();
      expect(service.value, const SystemTypography());
    });

    test(
      'malformed responses and partial fields use independent fallbacks',
      () async {
        final service = createService();
        for (final response in [null, 'Sans 12', 12, [], {}]) {
          messenger.setMockMethodCallHandler(channel, (_) async => response);
          await service.load();
          expect(service.value, const SystemTypography());
        }
        for (final size in [null, '18', 0, -1, double.nan, double.infinity]) {
          messenger.setMockMethodCallHandler(
            channel,
            (_) async => {'fontFamily': 'Noto Sans', 'fontSize': size},
          );
          await service.load();
          expect(service.value.fontFamily, 'Noto Sans');
          expect(service.value.fontSize, 14);
        }
        for (final family in [null, '', '  ', 123]) {
          messenger.setMockMethodCallHandler(
            channel,
            (_) async => {'fontFamily': family, 'fontSize': 18},
          );
          await service.load();
          expect(service.value.fontFamily, isNull);
          expect(service.value.fontSize, 18.0);
        }
      },
    );

    test('a stale load cannot overwrite a newer notification', () async {
      final firstResponse = Completer<Object?>();
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        if (++calls == 1) return firstResponse.future;
        return {'fontFamily': 'DejaVu Sans', 'fontSize': 18.0};
      });
      final service = createService();
      final firstLoad = service.load();
      await notifyFontChanged();
      firstResponse.complete({'fontFamily': 'Noto Sans', 'fontSize': 14.0});
      await firstLoad;
      expect(
        service.value,
        const SystemTypography(fontFamily: 'DejaVu Sans', fontSize: 18),
      );
    });

    test('disposal removes callbacks and ignores a pending reply', () async {
      final response = Completer<Object?>();
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return response.future;
      });
      final service = SystemTypographyService();
      var notifications = 0;
      service.addListener(() => notifications++);
      final pending = service.load();
      service.dispose();
      response.complete({'fontFamily': 'Noto Sans', 'fontSize': 18.0});
      await pending;
      expect(await notifyFontChanged(), isNull);
      await service.load();
      expect(calls, 1);
      expect(notifications, 0);
      expect(service.value, const SystemTypography());
    });

    test('disposing one service leaves another subscribed', () async {
      var font = {'fontFamily': 'Noto Sans', 'fontSize': 14.0};
      messenger.setMockMethodCallHandler(channel, (_) async => font);
      final first = SystemTypographyService();
      final second = createService();
      await first.load();
      await second.load();
      first.dispose();
      font = {'fontFamily': 'DejaVu Sans', 'fontSize': 18.0};
      await notifyFontChanged();
      expect(
        second.value,
        const SystemTypography(fontFamily: 'DejaVu Sans', fontSize: 18),
      );
    });

    test('loading and disposal preserve other channel handlers', () async {
      const other = MethodChannel('open_ecad/pointer_warp');
      var received = 0;
      other.setMethodCallHandler((_) async => received++);
      addTearDown(() => other.setMethodCallHandler(null));
      final service = SystemTypographyService();
      await service.load();
      service.dispose();
      await messenger.handlePlatformMessage(
        other.name,
        other.codec.encodeMethodCall(const MethodCall('unrelated')),
        null,
      );
      expect(received, 1);
    });
  });
}
