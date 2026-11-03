// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/keyboard_shortcuts.dart';
import 'sheet_types.dart';

Future<void> showKeyboardShortcutsDialog(
  BuildContext context, {
  required KeyboardShortcutPreferences preferences,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (context) => KeyboardShortcutsDialog(preferences: preferences),
);

class KeyboardShortcutsDialog extends StatefulWidget {
  const KeyboardShortcutsDialog({super.key, required this.preferences});

  final KeyboardShortcutPreferences preferences;

  @override
  State<KeyboardShortcutsDialog> createState() =>
      _KeyboardShortcutsDialogState();
}

class _KeyboardShortcutsDialogState extends State<KeyboardShortcutsDialog> {
  final _captureFocus = FocusNode(skipTraversal: true);
  KeyboardShortcuts? _draft;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String _query = '';
  EditorCommand? _captureCommand;
  int? _captureIndex;

  bool get _capturing => _captureCommand != null;
  bool get _editable => !_loading && !_saving && !_capturing && _draft != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // A pending startup load must finish before the editable snapshot exists.
      await widget.preferences.load();
      if (!mounted) return;
      setState(() {
        _draft = widget.preferences.value;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Nastavení se nepodařilo načíst. Zkuste to znovu.';
      });
    }
  }

  Future<void> _save() async {
    if (!_editable || _draft!.hasConflicts) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.preferences.save(_draft!);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Nastavení se nepodařilo uložit. Zkuste to znovu.';
      });
    }
  }

  void _setBindings(EditorCommand command, List<ShortcutBinding> bindings) {
    setState(() {
      _draft = _draft!.withBindings(command, bindings);
      _error = null;
    });
  }

  void _startCapture(EditorCommand command, [int? index]) {
    setState(() {
      _captureCommand = command;
      _captureIndex = index;
      _error = null;
    });
    _captureFocus.requestFocus();
  }

  KeyEventResult _captureKey(FocusNode node, KeyEvent event) {
    final command = _captureCommand;
    if (command == null) return KeyEventResult.ignored;
    final binding = ShortcutBinding.fromEvent(event);
    if (binding != null) {
      final bindings = [..._draft!.bindings(command)];
      final index = _captureIndex;
      if (index == null) {
        bindings.add(binding);
      } else {
        bindings[index] = binding;
      }
      setState(() {
        _draft = _draft!.withBindings(command, bindings);
        _captureCommand = null;
        _captureIndex = null;
      });
    }
    // Escape and Space belong to the chord, not the dialog or focused button.
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _captureFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving && !_capturing,
    child: Focus(
      focusNode: _captureFocus,
      onKeyEvent: _captureKey,
      child: ExcludeFocus(
        excluding: _capturing,
        child: AlertDialog(
          title: const Text('Klávesové zkratky'),
          content: SizedBox(
            width: 760,
            height: math.min(560, MediaQuery.sizeOf(context).height * 0.62),
            child: _content(context),
          ),
          actions: [
            TextButton(
              onPressed:
                  _editable
                      ? () => setState(() {
                        _draft = const KeyboardShortcuts.defaults();
                        _error = null;
                      })
                      : null,
              child: const Text('Vše výchozí'),
            ),
            TextButton(
              onPressed:
                  _saving || _capturing
                      ? null
                      : () => Navigator.of(context).pop(),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: _editable && !_draft!.hasConflicts ? _save : null,
              child: Text(_saving ? 'Ukládání…' : 'Uložit'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _content(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Načítání zkratek…'),
          ],
        ),
      );
    }
    final draft = _draft;
    if (draft == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Zkusit znovu')),
          ],
        ),
      );
    }
    final conflicts = draft.conflicts;
    final query = foldForSearch(_query.trim());
    final commands = EditorCommand.values.where(
      (command) => foldForSearch(
        '${command.label} ${command.group} ${draft.labelFor(command)}',
      ).contains(query),
    );
    final groups = commands.map((command) => command.group).toSet();
    final errorColor = Theme.of(context).colorScheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Ctrl znamená také Cmd na macOS. V textových polích zůstávají běžné '
          'textové zkratky. Projektové příkazy s Ctrl/Cmd fungují i při psaní, '
          'pokud nekolidují s úpravou textu.',
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('shortcuts-search'),
          enabled: !_saving && !_capturing,
          decoration: const InputDecoration(
            labelText: 'Hledat příkaz nebo zkratku',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        if (_capturing) ...[
          const SizedBox(height: 8),
          Material(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Zadejte zkratku: ${_captureCommand!.label}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Text(
                    'Stiskněte klávesu nebo kombinaci. Esc i Space lze přiřadit.',
                  ),
                  TextButton(
                    onPressed:
                        () => setState(() {
                          _captureCommand = null;
                          _captureIndex = null;
                        }),
                    child: const Text('Zrušit zadávání'),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Expanded(
          child:
              groups.isEmpty
                  ? const Center(child: Text('Žádný odpovídající příkaz.'))
                  : SingleChildScrollView(
                    key: const ValueKey('shortcuts-list'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final group in groups) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              group,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          for (final command in commands.where(
                            (command) => command.group == group,
                          ))
                            _commandRow(context, command, conflicts),
                        ],
                      ],
                    ),
                  ),
        ),
        if (conflicts.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Vyřešte konfliktní zkratky před uložením (${conflicts.length}).',
            style: TextStyle(color: errorColor),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: errorColor)),
        ],
      ],
    );
  }

  Widget _commandRow(
    BuildContext context,
    EditorCommand command,
    Map<ShortcutBinding, List<EditorCommand>> conflicts,
  ) {
    final bindings = _draft!.bindings(command);
    final errorColor = Theme.of(context).colorScheme.error;
    return Padding(
      key: ValueKey('shortcut-${command.name}'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(command.label)),
              IconButton(
                key: ValueKey('shortcut-clear-${command.name}'),
                tooltip: 'Vymazat zkratky: ${command.label}',
                onPressed:
                    _editable && bindings.isNotEmpty
                        ? () => _setBindings(command, [])
                        : null,
                icon: const Icon(Icons.block, size: 20),
              ),
              IconButton(
                key: ValueKey('shortcut-default-${command.name}'),
                tooltip: 'Výchozí zkratky: ${command.label}',
                onPressed:
                    _editable
                        ? () => _setBindings(
                          command,
                          const KeyboardShortcuts.defaults().bindings(command),
                        )
                        : null,
                icon: const Icon(Icons.restart_alt, size: 20),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (bindings.isEmpty) const Text('Bez zkratky'),
              for (var index = 0; index < bindings.length; index++)
                InputChip(
                  key: ValueKey('shortcut-binding-${command.name}-$index'),
                  label: Text(bindings[index].label),
                  tooltip: 'Změnit zkratku: ${command.label}',
                  side:
                      conflicts.containsKey(bindings[index])
                          ? BorderSide(color: errorColor)
                          : null,
                  onPressed:
                      _editable ? () => _startCapture(command, index) : null,
                  onDeleted:
                      _editable
                          ? () => _setBindings(command, [
                            ...bindings.take(index),
                            ...bindings.skip(index + 1),
                          ])
                          : null,
                  deleteButtonTooltipMessage: 'Odebrat zkratku',
                ),
              ActionChip(
                key: ValueKey('shortcut-add-${command.name}'),
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('Přidat'),
                tooltip: 'Přidat zkratku: ${command.label}',
                onPressed: _editable ? () => _startCapture(command) : null,
              ),
            ],
          ),
          for (final binding in bindings)
            if (conflicts.containsKey(binding))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${binding.label}: stejnou zkratku má '
                  '${conflicts[binding]!.where((c) => c != command).map((c) => c.label).join(', ')}.',
                  style: TextStyle(color: errorColor),
                ),
              ),
          const Divider(),
        ],
      ),
    );
  }
}
