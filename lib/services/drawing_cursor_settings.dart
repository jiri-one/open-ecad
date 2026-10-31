// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DrawingCursorColor { automatic, black, white, red, cyan }

@immutable
class DrawingCursorSettings {
  const DrawingCursorSettings({
    this.enabled = true,
    this.armLength = 8,
    this.strokeWidth = 1,
    this.color = DrawingCursorColor.automatic,
  }) : assert(armLength >= minArmLength && armLength <= maxArmLength),
       assert(strokeWidth >= minStrokeWidth && strokeWidth <= maxStrokeWidth);

  static const defaults = DrawingCursorSettings();
  static const minArmLength = 4.0, maxArmLength = 32.0;
  static const minStrokeWidth = 0.5, maxStrokeWidth = 3.0;

  final bool enabled;
  final double armLength, strokeWidth;
  final DrawingCursorColor color;

  DrawingCursorSettings copyWith({
    bool? enabled,
    double? armLength,
    double? strokeWidth,
    DrawingCursorColor? color,
  }) => DrawingCursorSettings(
    enabled: enabled ?? this.enabled,
    armLength: armLength ?? this.armLength,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    color: color ?? this.color,
  );

  static DrawingCursorSettings _decode(Object? stored) {
    if (stored is! String) return defaults;
    final Object? decoded;
    try {
      decoded = jsonDecode(stored);
    } on FormatException {
      return defaults;
    }
    if (decoded is! Map<String, dynamic>) return defaults;
    final values = decoded;
    double number(String key, double fallback, double min, double max) {
      final value = values[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    return DrawingCursorSettings(
      enabled: decoded['enabled'] is bool ? decoded['enabled'] as bool : true,
      armLength: number(
        'armLength',
        defaults.armLength,
        minArmLength,
        maxArmLength,
      ),
      strokeWidth: number(
        'strokeWidth',
        defaults.strokeWidth,
        minStrokeWidth,
        maxStrokeWidth,
      ),
      color:
          DrawingCursorColor.values
              .where((color) => color.name == values['color'])
              .firstOrNull ??
          DrawingCursorColor.automatic,
    );
  }

  String _encode() => jsonEncode({
    'enabled': enabled,
    'armLength': armLength,
    'strokeWidth': strokeWidth,
    'color': color.name,
  });

  @override
  bool operator ==(Object other) =>
      other is DrawingCursorSettings &&
      enabled == other.enabled &&
      armLength == other.armLength &&
      strokeWidth == other.strokeWidth &&
      color == other.color;

  @override
  int get hashCode => Object.hash(enabled, armLength, strokeWidth, color);
}

class DrawingCursorPreferences extends ChangeNotifier {
  DrawingCursorPreferences({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const storageKey = 'open_ecad.drawing_cursor.v1';
  final Future<SharedPreferences> Function() _loadPreferences;
  Future<SharedPreferences>? _preferences;
  Future<void> _pending = Future<void>.value();
  DrawingCursorSettings _value = DrawingCursorSettings.defaults;
  bool _disposed = false;

  DrawingCursorSettings get value => _value;

  Future<SharedPreferences> _store() async {
    try {
      return await (_preferences ??= _loadPreferences());
    } catch (_) {
      _preferences = null;
      rethrow;
    }
  }

  Future<void> load() => _enqueue(() async {
    final preferences = await _store();
    _publish(DrawingCursorSettings._decode(preferences.get(storageKey)));
  });

  Future<void> save(DrawingCursorSettings settings) => _enqueue(() async {
    final preferences = await _store();
    if (_disposed) return;
    if (!await preferences.setString(storageKey, settings._encode())) {
      throw StateError('Nastavení kreslicího kurzoru se nepodařilo uložit.');
    }
    _publish(settings);
  });

  Future<void> reset() => save(DrawingCursorSettings.defaults);

  Future<void> _enqueue(Future<void> Function() operation) {
    if (_disposed) {
      return Future<void>.error(StateError('Preferences disposed.'));
    }
    // Serial writes keep a slow save from overwriting a newer selection.
    final next = _pending.then((_) async {
      if (!_disposed) await operation();
    });
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _publish(DrawingCursorSettings settings) {
    if (_disposed || _value == settings) return;
    _value = settings;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
