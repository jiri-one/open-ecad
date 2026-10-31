import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/pointer_warp.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const target = PointerWarpTarget(
    position: Offset(31.5, 47.25),
    viewId: 7,
    devicePixelRatio: 2,
    physicalSize: Size(1600, 1200),
  );

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(PointerWarp.channel, null);
  });

  test(
    'sends view logical coordinates and matching physical metrics once',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(PointerWarp.channel, (call) async {
        calls.add(call);
        return true;
      });
      expect(await PointerWarp.move(target), isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'warp');
      expect(calls.single.arguments, {
        'x': 31.5,
        'y': 47.25,
        'viewId': 7,
        'devicePixelRatio': 2.0,
        'physicalWidth': 1600.0,
        'physicalHeight': 1200.0,
      });
    },
  );

  for (final response in [
    false,
    null,
    'true',
    1,
    {'moved': true},
  ]) {
    test('unverified native response $response is fallback', () async {
      messenger.setMockMethodCallHandler(
        PointerWarp.channel,
        (_) async => response,
      );
      expect(await PointerWarp.move(target), isFalse);
    });
  }

  test('absent plugin and platform errors leave a safe fallback', () async {
    expect(await PointerWarp.move(target), isFalse);
    messenger.setMockMethodCallHandler(PointerWarp.channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(await PointerWarp.move(target), isFalse);
  });

  test('other platforms never send a native request', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(PointerWarp.channel, (_) async {
      calls++;
      return true;
    });
    for (final platform in TargetPlatform.values.where(
      (p) => p != TargetPlatform.linux,
    )) {
      debugDefaultTargetPlatformOverride = platform;
      expect(await PointerWarp.move(target), isFalse);
    }
    expect(calls, 0);
  });

  test(
    'nonfinite, out of bounds and invalid view metrics never cross the channel',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(PointerWarp.channel, (_) async {
        calls++;
        return true;
      });
      final bad = [
        for (final position in [
          const Offset(-0.1, 20),
          const Offset(20, -0.1),
          const Offset(800, 20),
          const Offset(20, 600),
          const Offset(double.nan, 20),
          const Offset(20, double.infinity),
        ])
          PointerWarpTarget(
            position: position,
            viewId: 7,
            devicePixelRatio: 2,
            physicalSize: target.physicalSize,
          ),
        for (final dpr in [0.0, -1.0, double.nan, double.infinity])
          PointerWarpTarget(
            position: target.position,
            viewId: 7,
            devicePixelRatio: dpr,
            physicalSize: target.physicalSize,
          ),
        for (final size in [
          Size.zero,
          const Size(-1, 20),
          const Size(20, double.nan),
          const Size(double.infinity, 20),
        ])
          PointerWarpTarget(
            position: Offset.zero,
            viewId: 7,
            devicePixelRatio: 2,
            physicalSize: size,
          ),
        PointerWarpTarget(
          position: target.position,
          viewId: -1,
          devicePixelRatio: 2,
          physicalSize: target.physicalSize,
        ),
      ];
      for (final target in bad) {
        expect(await PointerWarp.move(target), isFalse);
      }
      expect(calls, 0);
    },
  );
}
