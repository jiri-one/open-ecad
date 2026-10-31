import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PointerWarpTarget {
  const PointerWarpTarget({
    required this.position,
    required this.viewId,
    required this.devicePixelRatio,
    required this.physicalSize,
  });

  final Offset position;
  final int viewId;
  final double devicePixelRatio;
  final Size physicalSize;

  bool get valid =>
      viewId >= 0 &&
      devicePixelRatio.isFinite &&
      devicePixelRatio > 0 &&
      physicalSize.width.isFinite &&
      physicalSize.height.isFinite &&
      physicalSize.width > 0 &&
      physicalSize.height > 0 &&
      position.dx.isFinite &&
      position.dy.isFinite &&
      position.dx >= 0 &&
      position.dy >= 0 &&
      position.dx * devicePixelRatio < physicalSize.width &&
      position.dy * devicePixelRatio < physicalSize.height;
}

class PointerWarp {
  static const channel = MethodChannel('open_ecad/pointer_warp');

  /// Only a native, verified arrival counts as success; fallback stays in Dart.
  static Future<bool> move(PointerWarpTarget target) async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.linux ||
        !target.valid) {
      return false;
    }
    try {
      return await channel.invokeMethod<Object?>('warp', {
            'x': target.position.dx,
            'y': target.position.dy,
            'viewId': target.viewId,
            'devicePixelRatio': target.devicePixelRatio,
            'physicalWidth': target.physicalSize.width,
            'physicalHeight': target.physicalSize.height,
          }) ==
          true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
