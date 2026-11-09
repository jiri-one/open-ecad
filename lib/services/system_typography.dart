import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class SystemTypography {
  const SystemTypography({this.fontFamily, this.fontSize = 14, this.fontScale});

  final String? fontFamily;

  final double? fontSize;
  final double? fontScale;

  @override
  bool operator ==(Object other) =>
      other is SystemTypography &&
      fontFamily == other.fontFamily &&
      fontSize == other.fontSize &&
      fontScale == other.fontScale;

  @override
  int get hashCode => Object.hash(fontFamily, fontSize, fontScale);
}

class SystemTypographyService extends ChangeNotifier {
  static const _channel = MethodChannel('open_ecad/system_typography');
  static final _subscribers = <SystemTypographyService>{};

  SystemTypography _value = const SystemTypography();
  SystemTypography get value => _value;

  bool _disposed = false;
  int _request = 0;

  Future<void> load() async {
    if (_disposed || kIsWeb || defaultTargetPlatform != TargetPlatform.linux) {
      return;
    }
    if (_subscribers.isEmpty) {
      _channel.setMethodCallHandler(_handleMethodCall);
    }
    _subscribers.add(this);

    final request = ++_request;
    var next = const SystemTypography();
    try {
      final result = await _channel.invokeMethod<Object?>('getFont');
      if (result is Map) {
        final family = result['fontFamily'];
        final size = result['fontSize'];
        final scale = result['fontScale'];
        next = SystemTypography(
          fontFamily:
              family is String && family.trim().isNotEmpty
                  ? family.trim()
                  : null,
          fontSize:
              size is num && size.isFinite && size > 0 ? size.toDouble() : 14,
          fontScale:
              scale is num && scale.isFinite && scale > 0
                  ? scale.toDouble()
                  : null,
        );
      }
    } on MissingPluginException {
      next = const SystemTypography();
    } on PlatformException {
      next = const SystemTypography();
    }

    if (_disposed || request != _request || next == _value) return;
    _value = next;
    notifyListeners();
  }

  static Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'fontChanged') throw MissingPluginException();
    await Future.wait([
      for (final service in List.of(_subscribers)) service.load(),
    ]);
  }

  @override
  void dispose() {
    _disposed = true;
    if (_subscribers.remove(this) && _subscribers.isEmpty) {
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }
}
