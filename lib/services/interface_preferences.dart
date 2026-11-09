// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class InterfacePreferences extends ChangeNotifier {
  InterfacePreferences({Future<SharedPreferences> Function()? loadPreferences})
    : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const storageKey = 'open_ecad.interface_text_scale';
  static const minScale = 1.0, maxScale = 2.0;
  final Future<SharedPreferences> Function() _loadPreferences;
  Future<void> _pending = Future<void>.value();
  double _scale = 1;
  double? _preview;
  bool _disposed = false;

  double get scale => _scale;
  double get effectiveScale => _preview ?? _scale;

  Future<void> load() => _enqueue(() async {
    final preferences = await _loadPreferences();
    final stored = preferences.get(storageKey);
    _scale =
        stored is num && stored.isFinite
            ? stored.toDouble().clamp(minScale, maxScale)
            : minScale;
    if (!_disposed) notifyListeners();
  });

  Future<void> save(double scale) {
    if (!scale.isFinite || scale < minScale || scale > maxScale) {
      return Future<void>.error(ArgumentError.value(scale, 'scale'));
    }
    return _enqueue(() async {
      final preferences = await _loadPreferences();
      if (_disposed) return;
      if (!await preferences.setDouble(storageKey, scale)) {
        throw StateError('Velikost písma se nepodařilo uložit.');
      }
      _scale = scale;
      if (!_disposed) notifyListeners();
    });
  }

  void preview(double? scale) {
    if (_disposed) return;
    assert(scale == null || (scale >= minScale && scale <= maxScale));
    _preview = scale;
    notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    if (_disposed) return Future.error(StateError('Preferences disposed.'));
    final next = _pending.then((_) async {
      if (!_disposed) await operation();
    });
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
