// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/keyboard_shortcuts.dart';
import 'package:open_ecad/widgets/keyboard_shortcuts_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _defaults = KeyboardShortcuts.defaults();
const _custom = ShortcutBinding(
  key: LogicalKeyboardKey.keyQ,
  control: true,
  alt: true,
);

class _ControlledStore implements SharedPreferences {
  final persisted = <String, Object>{};
  final cache = <String, Object>{};
  final writes = <String>[];
  bool failWrites = false;
  bool throwWrites = false;
  Completer<bool>? nextWrite;

  @override
  Object? get(String key) => cache[key];

  @override
  Future<bool> setString(String key, String value) async {
    // The real plugin updates its cache even when persistence fails.
    cache[key] = value;
    writes.add(value);
    final pending = nextWrite;
    nextWrite = null;
    if (throwWrites) throw StateError('Synthetic write failure');
    final success = pending == null ? !failWrites : await pending.future;
    if (success) persisted[key] = value;
    return success;
  }

  @override
  Future<void> reload() async {
    cache
      ..clear()
      ..addAll(persisted);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
  bool meta = false,
  bool shift = false,
  bool alt = false,
}) async {
  final modifiers = [
    if (control) LogicalKeyboardKey.controlLeft,
    if (meta) LogicalKeyboardKey.metaLeft,
    if (shift) LogicalKeyboardKey.shiftLeft,
    if (alt) LogicalKeyboardKey.altLeft,
  ];
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier);
  }
  await tester.sendKeyEvent(key);
  for (final modifier in modifiers.reversed) {
    await tester.sendKeyUpEvent(modifier);
  }
  await tester.pump();
}

Future<void> _mount(
  WidgetTester tester,
  KeyboardShortcutPreferences preferences,
) async {
  await tester.binding.setSurfaceSize(const Size(1024, 768));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(splashFactory: InkRipple.splashFactory),
      home: Scaffold(
        body: Builder(
          builder:
              (context) => TextButton(
                onPressed:
                    () => showKeyboardShortcutsDialog(
                      context,
                      preferences: preferences,
                    ),
                child: const Text('Nastavit'),
              ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Nastavit'));
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(const ValueKey('shortcuts-search')), query);
  await tester.pumpAndSettle();
}

Finder _control(String name, EditorCommand command) =>
    find.byKey(ValueKey('shortcut-$name-${command.name}'));

Finder _binding(EditorCommand command, [int index = 0]) =>
    find.byKey(ValueKey('shortcut-binding-${command.name}-$index'));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

bool _canSave(WidgetTester tester) =>
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Uložit'))
        .onPressed !=
    null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults preserve every command and its visible shortcut labels', () {
    const labels = {
      EditorCommand.openProject: 'Ctrl O',
      EditorCommand.exportProjectCopy: 'Ctrl Shift S',
      EditorCommand.commandPalette: 'Ctrl K',
      EditorCommand.focusAssistant: 'Ctrl L',
      EditorCommand.undo: 'Ctrl Z',
      EditorCommand.redo: 'Ctrl Y / Ctrl Shift Z',
      EditorCommand.copy: 'Ctrl C',
      EditorCommand.paste: 'Ctrl V',
      EditorCommand.duplicate: 'Ctrl D',
      EditorCommand.selectAll: 'Ctrl A',
      EditorCommand.cancelTool: 'Esc',
      EditorCommand.selectTool: 'V',
      EditorCommand.lineTool: 'L',
      EditorCommand.rectangleTool: 'B',
      EditorCommand.textTool: 'T',
      EditorCommand.wireTool: 'W',
      EditorCommand.panTool: 'H',
      EditorCommand.followContinuation: 'F',
      EditorCommand.fitSheet: 'Home',
      EditorCommand.rotate: 'R',
      EditorCommand.deleteSelection: 'Delete / Backspace',
      EditorCommand.editProperties: 'F4',
      EditorCommand.previousSheet: 'PgUp',
      EditorCommand.nextSheet: 'PgDown',
      EditorCommand.temporaryPan: 'Space',
    };
    expect(labels.keys.toSet(), EditorCommand.values.toSet());
    for (final entry in labels.entries) {
      expect(_defaults.labelFor(entry.key), entry.value);
      expect(entry.key.label, isNotEmpty);
      expect(entry.key.group, isNotEmpty);
    }
    expect(
      EditorCommand.values.where((command) => command.allowWhileEditingText),
      [
        EditorCommand.openProject,
        EditorCommand.exportProjectCopy,
        EditorCommand.commandPalette,
        EditorCommand.focusAssistant,
      ],
    );
    expect(_defaults.hasConflicts, isFalse);
  });

  test('binding lists are immutable and disabling survives a round trip', () {
    final input = [_custom, _custom];
    final changed = _defaults
        .withBindings(EditorCommand.openProject, input)
        .withBindings(EditorCommand.deleteSelection, []);
    input.clear();
    expect(changed.bindings(EditorCommand.openProject), [_custom]);
    expect(changed.labelFor(EditorCommand.deleteSelection), isEmpty);
    expect(_defaults.labelFor(EditorCommand.openProject), 'Ctrl O');
    expect(
      () => changed.bindings(EditorCommand.openProject).clear(),
      throwsUnsupportedError,
    );
    expect(
      () => _defaults.bindings(EditorCommand.redo).clear(),
      throwsUnsupportedError,
    );
    final restored = KeyboardShortcuts.decode(changed.encode());
    expect(restored, changed);
    expect(restored.hashCode, changed.hashCode);
    expect(
      changed
          .withBindings(
            EditorCommand.openProject,
            _defaults.bindings(EditorCommand.openProject),
          )
          .withBindings(
            EditorCommand.deleteSelection,
            _defaults.bindings(EditorCommand.deleteSelection),
          ),
      _defaults,
    );
  });

  test(
    'Czech keyboard labels can be captured and restored from preferences',
    () async {
      const key = LogicalKeyboardKey(0x011b);
      final binding = ShortcutBinding.fromEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.digit2,
          logicalKey: key,
          timeStamp: Duration.zero,
        ),
      );
      expect(binding, isNotNull);
      expect(binding!.label, 'Ě');
      final settings = _defaults.withBindings(EditorCommand.nextSheet, [
        binding,
      ]);
      final preferences = KeyboardShortcutPreferences();
      final restored = KeyboardShortcutPreferences();
      addTearDown(preferences.dispose);
      addTearDown(restored.dispose);
      await preferences.save(settings);
      await restored.load();
      expect(restored.value, settings);
    },
  );

  test('conflicts identify all owners and cannot be persisted', () async {
    const chord = ShortcutBinding(key: LogicalKeyboardKey.keyS, control: true);
    final changed = _defaults
        .withBindings(EditorCommand.lineTool, [chord])
        .withBindings(EditorCommand.textTool, [chord]);
    expect(changed.hasConflicts, isTrue);
    expect(changed.conflicts[chord], [
      EditorCommand.lineTool,
      EditorCommand.textTool,
    ]);
    expect(() => changed.conflicts.clear(), throwsUnsupportedError);
    expect(() => changed.conflicts[chord]!.clear(), throwsUnsupportedError);
    final store = await SharedPreferences.getInstance();
    final preferences = KeyboardShortcutPreferences();
    addTearDown(preferences.dispose);
    await expectLater(preferences.save(changed), throwsArgumentError);
    expect(preferences.value, _defaults);
    expect(store.containsKey(KeyboardShortcutPreferences.storageKey), isFalse);
    expect(KeyboardShortcuts.decode(changed.encode()), _defaults);
    await preferences.save(_defaults.withBindings(EditorCommand.lineTool, []));
    expect(preferences.value.bindings(EditorCommand.lineTool), isEmpty);
  });

  testWidgets('matching uses exact modifiers and accepts Ctrl or Cmd', (
    tester,
  ) async {
    EditorCommand? command;
    ShortcutBinding? captured;
    final editing = _defaults.withBindings(EditorCommand.openProject, [
      _custom,
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          autofocus: true,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                ShortcutBinding.fromEvent(event) != null) {
              captured = ShortcutBinding.fromEvent(event);
              command = editing.commandFor(event);
              if (command != null) {
                expect(editing.matches(command!, event), true);
              }
            }
            return KeyEventResult.handled;
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    await _chord(tester, LogicalKeyboardKey.keyS, control: true);
    expect(command, isNull);
    expect(captured!.label, 'Ctrl S');
    await _chord(tester, LogicalKeyboardKey.keyS, meta: true);
    expect(command, isNull);
    expect(captured!.label, 'Ctrl S');
    await _chord(tester, LogicalKeyboardKey.keyS, control: true, shift: true);
    expect(command, EditorCommand.exportProjectCopy);
    await _chord(tester, LogicalKeyboardKey.keyS, control: true, alt: true);
    expect(command, isNull);
    await _chord(tester, LogicalKeyboardKey.keyS);
    expect(command, isNull);
    await _chord(tester, LogicalKeyboardKey.keyQ, meta: true, alt: true);
    expect(command, EditorCommand.openProject);
    expect(captured, _custom);
    await _chord(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(command, EditorCommand.undo);
    await _chord(tester, LogicalKeyboardKey.keyZ, meta: true, shift: true);
    expect(command, EditorCommand.redo);
    await _chord(tester, LogicalKeyboardKey.keyY, control: true);
    expect(command, EditorCommand.redo);
    await _chord(tester, LogicalKeyboardKey.keyV);
    expect(command, EditorCommand.selectTool);
    await _chord(tester, LogicalKeyboardKey.keyV, control: true);
    expect(command, EditorCommand.paste);
    await _chord(tester, LogicalKeyboardKey.delete);
    expect(command, EditorCommand.deleteSelection);
    await _chord(tester, LogicalKeyboardKey.backspace);
    expect(command, EditorCommand.deleteSelection);
    await _chord(tester, LogicalKeyboardKey.pageUp);
    expect(command, EditorCommand.previousSheet);
    await _chord(tester, LogicalKeyboardKey.pageDown);
    expect(command, EditorCommand.nextSheet);
    await _chord(tester, LogicalKeyboardKey.space);
    expect(command, EditorCommand.temporaryPan);
    await _chord(tester, LogicalKeyboardKey.space, shift: true);
    expect(command, isNull);
  });

  test(
    'capture ignores modifiers, unknown, repeat, release and synthetic keys',
    () {
      for (final key in [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.controlRight,
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.altRight,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.altGraph,
        LogicalKeyboardKey.fn,
        LogicalKeyboardKey.unidentified,
        const LogicalKeyboardKey(0x7fffffffffffffff),
      ]) {
        expect(
          ShortcutBinding.fromEvent(
            KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.keyA,
              logicalKey: key,
              timeStamp: Duration.zero,
            ),
          ),
          isNull,
        );
        expect(
          () => _defaults.withBindings(EditorCommand.lineTool, [
            ShortcutBinding(key: key),
          ]),
          throwsArgumentError,
        );
      }
      for (final event in [
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: LogicalKeyboardKey.keyA,
          timeStamp: Duration.zero,
        ),
        const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: LogicalKeyboardKey.keyA,
          timeStamp: Duration.zero,
        ),
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: LogicalKeyboardKey.keyA,
          timeStamp: Duration.zero,
          synthesized: true,
        ),
      ]) {
        expect(ShortcutBinding.fromEvent(event), isNull);
      }
    },
  );

  test(
    'preferences load lazily, round trip, reset and keep unrelated values',
    () async {
      SharedPreferences.setMockInitialValues({'unrelated': 'untouched'});
      final store = await SharedPreferences.getInstance();
      var loads = 0, notifications = 0;
      final preferences = KeyboardShortcutPreferences(
        loadPreferences: () async {
          loads++;
          return store;
        },
      );
      addTearDown(preferences.dispose);
      preferences.addListener(() => notifications++);
      expect(loads, 0);
      expect(preferences.value, _defaults);
      await preferences.load();
      expect(loads, 1);
      expect(notifications, 0);
      final changed = _defaults
          .withBindings(EditorCommand.openProject, [_custom])
          .withBindings(EditorCommand.cancelTool, []);
      await preferences.save(changed);
      expect(notifications, 1);
      final restored = KeyboardShortcutPreferences();
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.value, changed);
      await preferences.save(changed);
      expect(notifications, 1);
      await preferences.reset();
      await restored.load();
      expect(restored.value, _defaults);
      expect(notifications, 2);
      expect(loads, 1);
      expect(store.getKeys(), {
        'unrelated',
        KeyboardShortcutPreferences.storageKey,
      });
      expect(store.getString('unrelated'), 'untouched');
    },
  );

  test(
    'corrupt stored values and invalid key or modifier types restore defaults',
    () async {
      final valid = {
        'key': LogicalKeyboardKey.keyQ.keyId,
        'control': false,
        'shift': false,
        'alt': false,
      };
      final corruptBindings = [
        {...valid, 'key': '81'},
        {...valid, 'key': 81.5},
        {...valid, 'key': -1},
        {...valid, 'key': 0xd800},
        {...valid, 'key': 0x110000},
        {...valid, 'key': 0x7fffffffffffffff},
        {...valid, 'key': LogicalKeyboardKey.unidentified.keyId},
        {...valid, 'key': LogicalKeyboardKey.controlLeft.keyId},
        {...valid, 'control': 'false'},
        {...valid, 'shift': 1},
        {...valid, 'alt': null},
        {...valid}..remove('control'),
        null,
        'Ctrl Q',
      ];
      for (final stored in [
        17,
        false,
        'broken JSON',
        '[]',
        'null',
        '{"unknown":[]}',
        '{"openProject":{}}',
        for (final binding in corruptBindings)
          jsonEncode({
            'lineTool': [],
            'openProject': [binding],
          }),
      ]) {
        SharedPreferences.setMockInitialValues({
          KeyboardShortcutPreferences.storageKey: stored,
        });
        final preferences = KeyboardShortcutPreferences();
        await preferences.load();
        expect(preferences.value, _defaults, reason: '$stored');
        preferences.dispose();
      }
      expect(
        KeyboardShortcuts.decode('{"openProject":[]}'),
        _defaults.withBindings(EditorCommand.openProject, []),
      );
    },
  );

  test(
    'queued loads and saves publish only completed writes in order',
    () async {
      final ready = Completer<SharedPreferences>();
      final firstWrite = Completer<bool>();
      final store = _ControlledStore()..nextWrite = firstWrite;
      final preferences = KeyboardShortcutPreferences(
        loadPreferences: () => ready.future,
      );
      addTearDown(preferences.dispose);
      final first = _defaults.withBindings(EditorCommand.openProject, [
        _custom,
      ]);
      final last = _defaults.withBindings(EditorCommand.lineTool, []);
      final published = <KeyboardShortcuts>[];
      preferences.addListener(() => published.add(preferences.value));
      final loading = preferences.load();
      final savingFirst = preferences.save(first);
      final savingLast = preferences.save(last);
      ready.complete(store);
      await loading;
      await Future<void>.delayed(Duration.zero);
      expect(store.writes.length, 1);
      expect(preferences.value, _defaults);
      firstWrite.complete(true);
      await Future.wait([savingFirst, savingLast]);
      expect(published, [first, last]);
      expect(store.writes, [first.encode(), last.encode()]);
      await preferences.load();
      expect(preferences.value, last);
    },
  );

  test(
    'loader failures retry and failed writes never leak through the cache',
    () async {
      final store = _ControlledStore();
      var loads = 0;
      final preferences = KeyboardShortcutPreferences(
        loadPreferences: () async {
          if (loads++ == 0) throw StateError('Synthetic loader failure');
          return store;
        },
      );
      addTearDown(preferences.dispose);
      await expectLater(preferences.load(), throwsStateError);
      await preferences.load();
      expect(loads, 2);
      final first = _defaults.withBindings(EditorCommand.lineTool, []);
      final last = _defaults.withBindings(EditorCommand.openProject, [_custom]);
      await preferences.save(first);
      var notifications = 0;
      preferences.addListener(() => notifications++);
      for (final throws in [false, true]) {
        store.failWrites = true;
        store.throwWrites = throws;
        await expectLater(preferences.save(last), throwsStateError);
        expect(preferences.value, first);
        await preferences.load();
        expect(preferences.value, first);
        expect(notifications, 0);
      }
      store.failWrites = false;
      store.throwWrites = false;
      await preferences.save(last);
      expect(preferences.value, last);
      expect(notifications, 1);
    },
  );

  test('disposal suppresses pending notifications and queued writes', () async {
    final store = _ControlledStore();
    final ready = Completer<SharedPreferences>();
    final preferences = KeyboardShortcutPreferences(
      loadPreferences: () => ready.future,
    );
    var notifications = 0;
    preferences.addListener(() => notifications++);
    final loading = preferences.load();
    final saving = preferences.save(
      _defaults.withBindings(EditorCommand.lineTool, []),
    );
    await Future<void>.delayed(Duration.zero);
    preferences.dispose();
    ready.complete(store);
    await Future.wait([loading, saving]);
    expect(notifications, 0);
    expect(store.writes, isEmpty);
    await expectLater(preferences.reset(), throwsStateError);
    final writing = Completer<bool>();
    store.nextWrite = writing;
    final active = KeyboardShortcutPreferences(
      loadPreferences: () async => store,
    );
    active.addListener(() => notifications++);
    final pending = active.save(
      _defaults.withBindings(EditorCommand.lineTool, []),
    );
    await Future<void>.delayed(Duration.zero);
    active.dispose();
    writing.complete(true);
    await pending;
    expect(notifications, 0);
    expect(active.value, _defaults);
  });

  testWidgets(
    'search, clearing and Cancel leave stored preferences unchanged',
    (tester) async {
      final preferences = KeyboardShortcutPreferences();
      addTearDown(preferences.dispose);
      await _mount(tester, preferences);
      await _open(tester);
      expect(find.textContaining('Cmd na macOS'), findsOneWidget);
      await _search(tester, 'Ctrl Shift S');
      expect(find.text(EditorCommand.exportProjectCopy.label), findsOneWidget);
      expect(find.text(EditorCommand.selectTool.label), findsNothing);
      await _tap(tester, _control('clear', EditorCommand.exportProjectCopy));
      await _search(tester, EditorCommand.exportProjectCopy.label);
      expect(find.text('Bez zkratky'), findsOneWidget);
      expect(preferences.value, _defaults);
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      expect(find.byType(KeyboardShortcutsDialog), findsNothing);
      final store = await SharedPreferences.getInstance();
      expect(
        store.containsKey(KeyboardShortcutPreferences.storageKey),
        isFalse,
      );
    },
  );

  testWidgets(
    'capture replaces and adds alternatives; individual removal saves',
    (tester) async {
      final preferences = KeyboardShortcutPreferences();
      addTearDown(preferences.dispose);
      await _mount(tester, preferences);
      await _open(tester);
      await _search(tester, EditorCommand.openProject.label);
      await _tap(tester, _binding(EditorCommand.openProject));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('Zrušit zadávání'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('Ctrl Alt Q'), findsOneWidget);
      await _tap(tester, _control('add', EditorCommand.openProject));
      await _chord(tester, LogicalKeyboardKey.f8);
      expect(find.text('F8'), findsOneWidget);
      await _tap(tester, _control('add', EditorCommand.openProject));
      await tester.tap(find.text('Zrušit zadávání'));
      await tester.pumpAndSettle();
      expect(find.text('Ctrl Alt Q'), findsOneWidget);
      await _tap(
        tester,
        find.descendant(
          of: _binding(EditorCommand.openProject, 1),
          matching: find.byTooltip('Odebrat zkratku'),
        ),
      );
      expect(find.text('F8'), findsNothing);
      expect(preferences.value, _defaults);
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(find.byType(KeyboardShortcutsDialog), findsNothing);
      expect(preferences.value.bindings(EditorCommand.openProject), [_custom]);
      final restored = KeyboardShortcutPreferences();
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.value, preferences.value);
    },
  );

  testWidgets(
    'Escape and Space capture identify conflicts and block save until fixed',
    (tester) async {
      final preferences = KeyboardShortcutPreferences();
      addTearDown(preferences.dispose);
      await _mount(tester, preferences);
      await _open(tester);
      await _search(tester, EditorCommand.openProject.label);
      await _tap(tester, _binding(EditorCommand.openProject));
      await _chord(tester, LogicalKeyboardKey.escape);
      expect(find.byType(KeyboardShortcutsDialog), findsOneWidget);
      expect(find.text('Esc'), findsOneWidget);
      expect(
        find.text('Esc: stejnou zkratku má ${EditorCommand.cancelTool.label}.'),
        findsOneWidget,
      );
      expect(_canSave(tester), isFalse);
      await _search(tester, EditorCommand.cancelTool.label);
      await _tap(tester, _control('clear', EditorCommand.cancelTool));
      expect(_canSave(tester), isTrue);
      await _search(tester, EditorCommand.openProject.label);
      await _tap(tester, _control('add', EditorCommand.openProject));
      await _chord(tester, LogicalKeyboardKey.space);
      expect(find.text('Space'), findsOneWidget);
      expect(
        find.text(
          'Space: stejnou zkratku má ${EditorCommand.temporaryPan.label}.',
        ),
        findsOneWidget,
      );
      expect(_canSave(tester), isFalse);
      await _search(tester, 'not a command');
      expect(find.text('Žádný odpovídající příkaz.'), findsOneWidget);
      expect(_canSave(tester), isFalse);
      await _search(tester, EditorCommand.temporaryPan.label);
      await _tap(tester, _control('clear', EditorCommand.temporaryPan));
      expect(_canSave(tester), isTrue);
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(
        preferences.value.labelFor(EditorCommand.openProject),
        'Esc / Space',
      );
      expect(preferences.value.bindings(EditorCommand.cancelTool), isEmpty);
      expect(preferences.value.bindings(EditorCommand.temporaryPan), isEmpty);
    },
  );

  testWidgets('per-command and global defaults remain staged until Save', (
    tester,
  ) async {
    final changed = _defaults
        .withBindings(EditorCommand.openProject, [_custom])
        .withBindings(EditorCommand.lineTool, []);
    SharedPreferences.setMockInitialValues({
      KeyboardShortcutPreferences.storageKey: changed.encode(),
    });
    final preferences = KeyboardShortcutPreferences();
    addTearDown(preferences.dispose);
    await _mount(tester, preferences);
    await _open(tester);
    await _search(tester, EditorCommand.openProject.label);
    expect(find.text('Ctrl Alt Q'), findsOneWidget);
    await _tap(tester, _control('default', EditorCommand.openProject));
    expect(find.text('Ctrl O'), findsOneWidget);
    expect(preferences.value, changed);
    await _search(tester, EditorCommand.lineTool.label);
    expect(find.text('Bez zkratky'), findsOneWidget);
    await tester.tap(find.text('Vše výchozí'));
    await tester.pumpAndSettle();
    expect(find.text('L'), findsOneWidget);
    expect(preferences.value, changed);
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();
    expect(preferences.value, _defaults);
  });

  testWidgets('dialog waits for an in-flight load before reading its draft', (
    tester,
  ) async {
    final changed = _defaults.withBindings(EditorCommand.openProject, [
      _custom,
    ]);
    SharedPreferences.setMockInitialValues({
      KeyboardShortcutPreferences.storageKey: changed.encode(),
    });
    final store = await SharedPreferences.getInstance();
    final ready = Completer<SharedPreferences>();
    final preferences = KeyboardShortcutPreferences(
      loadPreferences: () => ready.future,
    );
    addTearDown(preferences.dispose);
    final startup = preferences.load();
    await _mount(tester, preferences);
    await tester.tap(find.text('Nastavit'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Načítání zkratek…'), findsOneWidget);
    expect(_canSave(tester), isFalse);
    ready.complete(store);
    await tester.pumpAndSettle();
    await startup;
    await _search(tester, EditorCommand.openProject.label);
    expect(find.text('Ctrl Alt Q'), findsOneWidget);
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();
    expect(preferences.value, changed);
  });

  testWidgets(
    'load and save errors are visible and retry preserves the draft',
    (tester) async {
      final store = _ControlledStore();
      var loads = 0;
      final preferences = KeyboardShortcutPreferences(
        loadPreferences: () async {
          if (loads++ == 0) throw StateError('Synthetic load failure');
          return store;
        },
      );
      addTearDown(preferences.dispose);
      await _mount(tester, preferences);
      await _open(tester);
      expect(
        find.text('Nastavení se nepodařilo načíst. Zkuste to znovu.'),
        findsOneWidget,
      );
      expect(_canSave(tester), isFalse);
      await tester.tap(find.text('Zkusit znovu'));
      await tester.pumpAndSettle();
      await _search(tester, EditorCommand.openProject.label);
      await _tap(tester, _control('clear', EditorCommand.openProject));
      store.failWrites = true;
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(
        find.text('Nastavení se nepodařilo uložit. Zkuste to znovu.'),
        findsOneWidget,
      );
      expect(find.text('Bez zkratky'), findsOneWidget);
      expect(preferences.value, _defaults);
      store.failWrites = false;
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(find.byType(KeyboardShortcutsDialog), findsNothing);
      expect(preferences.value.bindings(EditorCommand.openProject), isEmpty);
    },
  );

  testWidgets('an active save blocks dismissal and a cancelled load is safe', (
    tester,
  ) async {
    final store = _ControlledStore();
    final writing = Completer<bool>();
    final preferences = KeyboardShortcutPreferences(
      loadPreferences: () async => store,
    );
    addTearDown(preferences.dispose);
    await _mount(tester, preferences);
    await _open(tester);
    await _search(tester, EditorCommand.openProject.label);
    await _tap(tester, _control('clear', EditorCommand.openProject));
    store.nextWrite = writing;
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();
    expect(find.text('Ukládání…'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Zrušit'))
          .onPressed,
      isNull,
    );
    await _chord(tester, LogicalKeyboardKey.escape);
    expect(find.byType(KeyboardShortcutsDialog), findsOneWidget);
    writing.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(KeyboardShortcutsDialog), findsNothing);
    final ready = Completer<SharedPreferences>();
    final loading = KeyboardShortcutPreferences(
      loadPreferences: () => ready.future,
    );
    addTearDown(loading.dispose);
    await _mount(tester, loading);
    await tester.tap(find.text('Nastavit'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();
    ready.complete(store);
    await tester.pumpAndSettle();
    expect(find.byType(KeyboardShortcutsDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dialog controls and capture fit common desktop window sizes', (
    tester,
  ) async {
    final preferences = KeyboardShortcutPreferences();
    addTearDown(preferences.dispose);
    await _mount(tester, preferences);
    await _open(tester);
    for (final size in [const Size(1024, 768), const Size(1440, 900)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpAndSettle();
      await _search(tester, EditorCommand.temporaryPan.label);
      await _tap(tester, _binding(EditorCommand.temporaryPan));
      final dialog = tester.getRect(find.byType(AlertDialog));
      expect(dialog.left, greaterThanOrEqualTo(0));
      expect(dialog.top, greaterThanOrEqualTo(0));
      expect(dialog.right, lessThanOrEqualTo(size.width));
      expect(dialog.bottom, lessThanOrEqualTo(size.height));
      expect(find.text('Zrušit zadávání').hitTestable(), findsOneWidget);
      expect(find.text('Uložit').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Zrušit zadávání'));
      await tester.pumpAndSettle();
    }
  });
}
