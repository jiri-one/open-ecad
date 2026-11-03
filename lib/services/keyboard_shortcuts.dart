// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum EditorCommand {
  openProject('Otevřít projekt', 'Projekt', allowWhileEditingText: true),
  saveProject('Uložit projekt', 'Projekt', allowWhileEditingText: true),
  saveProjectAs('Uložit projekt jako…', 'Projekt', allowWhileEditingText: true),
  commandPalette('Paleta příkazů', 'Projekt', allowWhileEditingText: true),
  focusAssistant('Psát asistentovi', 'Projekt', allowWhileEditingText: true),
  undo('Vrátit změnu', 'Úpravy'),
  redo('Obnovit změnu', 'Úpravy'),
  copy('Kopírovat výběr', 'Úpravy'),
  paste('Vložit ze schránky', 'Úpravy'),
  duplicate('Duplikovat výběr', 'Úpravy'),
  selectAll('Vybrat vše', 'Úpravy'),
  cancelTool('Zrušit rozpracovanou akci', 'Nástroje'),
  selectTool('Výběr', 'Nástroje'),
  lineTool('Čára', 'Nástroje'),
  rectangleTool('Obdélník', 'Nástroje'),
  textTool('Text', 'Nástroje'),
  wireTool('Vodič', 'Nástroje'),
  panTool('Posun', 'Nástroje'),
  followContinuation('Přejít na protějšek odkazu', 'Navigace'),
  fitSheet('Zobrazit celý list', 'Navigace'),
  rotate('Otočit výběr', 'Úpravy'),
  deleteSelection('Odstranit výběr', 'Úpravy'),
  editProperties('Vlastnosti výběru', 'Úpravy'),
  previousSheet('Předchozí list', 'Navigace'),
  nextSheet('Následující list', 'Navigace'),
  temporaryPan('Dočasný posun při držení klávesy', 'Navigace');

  const EditorCommand(
    this.label,
    this.group, {
    this.allowWhileEditingText = false,
  });

  final String label, group;
  final bool allowWhileEditingText;
}

@immutable
class ShortcutBinding {
  const ShortcutBinding({
    required this.key,
    this.control = false,
    this.shift = false,
    this.alt = false,
  });

  final LogicalKeyboardKey key;
  final bool control, shift, alt;

  static const _modifiers = [
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.altGraph,
    LogicalKeyboardKey.fn,
    LogicalKeyboardKey.fnLock,
    LogicalKeyboardKey.hyper,
    LogicalKeyboardKey.superKey,
    LogicalKeyboardKey.shiftLevel5,
  ];

  static bool _validKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.unidentified || _modifiers.contains(key)) {
      return false;
    }
    if (LogicalKeyboardKey.findKeyByKeyId(key.keyId) != null) return true;
    // Accented keyboard labels do not all have predefined Flutter constants.
    final id = key.keyId;
    return id >= 0x20 &&
        id <= 0x10ffff &&
        !(id >= 0xd800 && id <= 0xdfff) &&
        !LogicalKeyboardKey.isControlCharacter(String.fromCharCode(id));
  }

  bool matches(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    return event.logicalKey == key &&
        control == (keyboard.isControlPressed || keyboard.isMetaPressed) &&
        shift == keyboard.isShiftPressed &&
        alt == keyboard.isAltPressed;
  }

  static ShortcutBinding? fromEvent(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.synthesized ||
        !_validKey(event.logicalKey)) {
      return null;
    }
    final keyboard = HardwareKeyboard.instance;
    return ShortcutBinding(
      key: event.logicalKey,
      control: keyboard.isControlPressed || keyboard.isMetaPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
    );
  }

  String get label => [
    if (control) 'Ctrl',
    if (shift) 'Shift',
    if (alt) 'Alt',
    switch (key) {
      LogicalKeyboardKey.escape => 'Esc',
      LogicalKeyboardKey.space => 'Space',
      LogicalKeyboardKey.pageUp => 'PgUp',
      LogicalKeyboardKey.pageDown => 'PgDown',
      _ => key.keyLabel,
    },
  ].join(' ');

  @override
  bool operator ==(Object other) =>
      other is ShortcutBinding &&
      key == other.key &&
      control == other.control &&
      shift == other.shift &&
      alt == other.alt;

  @override
  int get hashCode => Object.hash(key, control, shift, alt);
}

@immutable
class KeyboardShortcuts {
  const KeyboardShortcuts.defaults() : _overrides = const {};

  KeyboardShortcuts._(Map<EditorCommand, List<ShortcutBinding>> overrides)
    : _overrides = Map.unmodifiable(overrides);

  final Map<EditorCommand, List<ShortcutBinding>> _overrides;

  static const _defaults = <EditorCommand, List<ShortcutBinding>>{
    EditorCommand.openProject: [
      ShortcutBinding(key: LogicalKeyboardKey.keyO, control: true),
    ],
    EditorCommand.saveProject: [
      ShortcutBinding(key: LogicalKeyboardKey.keyS, control: true),
    ],
    EditorCommand.saveProjectAs: [
      ShortcutBinding(key: LogicalKeyboardKey.keyS, control: true, shift: true),
    ],
    EditorCommand.commandPalette: [
      ShortcutBinding(key: LogicalKeyboardKey.keyK, control: true),
    ],
    EditorCommand.focusAssistant: [
      ShortcutBinding(key: LogicalKeyboardKey.keyL, control: true),
    ],
    EditorCommand.undo: [
      ShortcutBinding(key: LogicalKeyboardKey.keyZ, control: true),
    ],
    EditorCommand.redo: [
      ShortcutBinding(key: LogicalKeyboardKey.keyY, control: true),
      ShortcutBinding(key: LogicalKeyboardKey.keyZ, control: true, shift: true),
    ],
    EditorCommand.copy: [
      ShortcutBinding(key: LogicalKeyboardKey.keyC, control: true),
    ],
    EditorCommand.paste: [
      ShortcutBinding(key: LogicalKeyboardKey.keyV, control: true),
    ],
    EditorCommand.duplicate: [
      ShortcutBinding(key: LogicalKeyboardKey.keyD, control: true),
    ],
    EditorCommand.selectAll: [
      ShortcutBinding(key: LogicalKeyboardKey.keyA, control: true),
    ],
    EditorCommand.cancelTool: [ShortcutBinding(key: LogicalKeyboardKey.escape)],
    EditorCommand.selectTool: [ShortcutBinding(key: LogicalKeyboardKey.keyV)],
    EditorCommand.lineTool: [ShortcutBinding(key: LogicalKeyboardKey.keyL)],
    EditorCommand.rectangleTool: [
      ShortcutBinding(key: LogicalKeyboardKey.keyB),
    ],
    EditorCommand.textTool: [ShortcutBinding(key: LogicalKeyboardKey.keyT)],
    EditorCommand.wireTool: [ShortcutBinding(key: LogicalKeyboardKey.keyW)],
    EditorCommand.panTool: [ShortcutBinding(key: LogicalKeyboardKey.keyH)],
    EditorCommand.followContinuation: [
      ShortcutBinding(key: LogicalKeyboardKey.keyF),
    ],
    EditorCommand.fitSheet: [ShortcutBinding(key: LogicalKeyboardKey.home)],
    EditorCommand.rotate: [ShortcutBinding(key: LogicalKeyboardKey.keyR)],
    EditorCommand.deleteSelection: [
      ShortcutBinding(key: LogicalKeyboardKey.delete),
      ShortcutBinding(key: LogicalKeyboardKey.backspace),
    ],
    EditorCommand.editProperties: [ShortcutBinding(key: LogicalKeyboardKey.f4)],
    EditorCommand.previousSheet: [
      ShortcutBinding(key: LogicalKeyboardKey.pageUp),
    ],
    EditorCommand.nextSheet: [
      ShortcutBinding(key: LogicalKeyboardKey.pageDown),
    ],
    EditorCommand.temporaryPan: [
      ShortcutBinding(key: LogicalKeyboardKey.space),
    ],
  };

  List<ShortcutBinding> bindings(EditorCommand command) =>
      _overrides[command] ?? _defaults[command]!;

  KeyboardShortcuts withBindings(
    EditorCommand command,
    List<ShortcutBinding> bindings,
  ) {
    if (bindings.any((binding) => !ShortcutBinding._validKey(binding.key))) {
      throw ArgumentError.value(bindings, 'bindings', 'Neplatná klávesa.');
    }
    return KeyboardShortcuts._({
      ..._overrides,
      command: List.unmodifiable(bindings.toSet()),
    });
  }

  bool matches(EditorCommand command, KeyEvent event) =>
      bindings(command).any((binding) => binding.matches(event));

  EditorCommand? commandFor(KeyEvent event) =>
      EditorCommand.values
          .where((command) => matches(command, event))
          .firstOrNull;

  String labelFor(EditorCommand command) =>
      bindings(command).map((binding) => binding.label).join(' / ');

  Map<ShortcutBinding, List<EditorCommand>> get conflicts {
    final owners = <ShortcutBinding, List<EditorCommand>>{};
    for (final command in EditorCommand.values) {
      for (final binding in bindings(command)) {
        (owners[binding] ??= []).add(command);
      }
    }
    return Map.unmodifiable({
      for (final entry in owners.entries)
        if (entry.value.length > 1)
          entry.key: List<EditorCommand>.unmodifiable(entry.value),
    });
  }

  bool get hasConflicts => conflicts.isNotEmpty;

  String encode() => jsonEncode({
    for (final command in EditorCommand.values)
      command.name: [
        for (final binding in bindings(command))
          {
            'key': binding.key.keyId,
            'control': binding.control,
            'shift': binding.shift,
            'alt': binding.alt,
          },
      ],
  });

  static KeyboardShortcuts decode(Object? stored) {
    const defaults = KeyboardShortcuts.defaults();
    if (stored is! String) return defaults;
    final Object? decoded;
    try {
      decoded = jsonDecode(stored);
    } on FormatException {
      return defaults;
    }
    if (decoded is! Map<String, dynamic>) return defaults;
    var settings = defaults;
    for (final entry in decoded.entries) {
      final command =
          EditorCommand.values.where((c) => c.name == entry.key).firstOrNull;
      if (command == null || entry.value is! List) return defaults;
      final bindings = <ShortcutBinding>[];
      for (final value in entry.value as List) {
        if (value is! Map<String, dynamic> ||
            value['key'] is! int ||
            value['control'] is! bool ||
            value['shift'] is! bool ||
            value['alt'] is! bool) {
          return defaults;
        }
        final id = value['key'] as int;
        final key =
            LogicalKeyboardKey.findKeyByKeyId(id) ?? LogicalKeyboardKey(id);
        if (!ShortcutBinding._validKey(key)) return defaults;
        bindings.add(
          ShortcutBinding(
            key: key,
            control: value['control'] as bool,
            shift: value['shift'] as bool,
            alt: value['alt'] as bool,
          ),
        );
      }
      settings = settings.withBindings(command, bindings);
    }
    return settings.hasConflicts ? defaults : settings;
  }

  @override
  bool operator ==(Object other) =>
      other is KeyboardShortcuts &&
      EditorCommand.values.every(
        (command) => listEquals(bindings(command), other.bindings(command)),
      );

  @override
  int get hashCode => Object.hashAll(
    EditorCommand.values.map((command) => Object.hashAll(bindings(command))),
  );
}

class KeyboardShortcutPreferences extends ChangeNotifier {
  KeyboardShortcutPreferences({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const storageKey = 'open_ecad.keyboard_shortcuts.v1';
  final Future<SharedPreferences> Function() _loadPreferences;
  Future<SharedPreferences>? _preferences;
  Future<void> _pending = Future<void>.value();
  KeyboardShortcuts _value = const KeyboardShortcuts.defaults();
  bool _disposed = false;
  bool _reloadRequired = false;

  KeyboardShortcuts get value => _value;

  Future<SharedPreferences> _store() async {
    try {
      final preferences = await (_preferences ??= _loadPreferences());
      if (_reloadRequired) {
        // SharedPreferences changes its cache before the disk write succeeds.
        await preferences.reload();
        _reloadRequired = false;
      }
      return preferences;
    } catch (_) {
      _preferences = null;
      rethrow;
    }
  }

  Future<void> load() => _enqueue(() async {
    final preferences = await _store();
    _publish(KeyboardShortcuts.decode(preferences.get(storageKey)));
  });

  Future<void> save(KeyboardShortcuts settings) => _enqueue(() async {
    if (settings.hasConflicts) {
      throw ArgumentError('Jedna zkratka nesmí patřit více příkazům.');
    }
    final preferences = await _store();
    if (_disposed) return;
    try {
      if (!await preferences.setString(storageKey, settings.encode())) {
        throw StateError('Klávesové zkratky se nepodařilo uložit.');
      }
    } catch (_) {
      _reloadRequired = true;
      rethrow;
    }
    _publish(settings);
  });

  Future<void> reset() => save(const KeyboardShortcuts.defaults());

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

  void _publish(KeyboardShortcuts settings) {
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
