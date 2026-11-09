// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../services/drawing_cursor_settings.dart';

Future<void> showDrawingCursorDialog(
  BuildContext context, {
  required DrawingCursorPreferences preferences,
}) => showDialog<void>(
  context: context,
  builder: (context) => DrawingCursorDialog(preferences: preferences),
);

class DrawingCursorDialog extends StatefulWidget {
  const DrawingCursorDialog({super.key, required this.preferences});
  final DrawingCursorPreferences preferences;

  @override
  State<DrawingCursorDialog> createState() => _DrawingCursorDialogState();
}

class _DrawingCursorDialogState extends State<DrawingCursorDialog> {
  late DrawingCursorSettings _draft = widget.preferences.value;
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.preferences.save(_draft);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Nastavení se nepodařilo uložit. Zkuste to znovu.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('Kreslicí kurzor'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Vlastní křížek v kreslicí ploše'),
                value: _draft.enabled,
                onChanged:
                    _saving
                        ? null
                        : (value) => setState(() {
                          _draft = _draft.copyWith(enabled: value);
                        }),
              ),
              const Text(
                'Velikost v obrazových bodech se při přiblížení výkresu nemění.',
              ),
              const SizedBox(height: 16),
              Text('Délka ramene: ${_draft.armLength.toStringAsFixed(0)} px'),
              Slider(
                key: const ValueKey('drawing-cursor-arm-length'),
                value: _draft.armLength,
                min: DrawingCursorSettings.minArmLength,
                max: DrawingCursorSettings.maxArmLength,
                divisions: 28,
                label: '${_draft.armLength.toStringAsFixed(0)} px',
                onChanged:
                    _saving
                        ? null
                        : (value) => setState(() {
                          _draft = _draft.copyWith(armLength: value);
                        }),
              ),
              Text('Tloušťka: ${_draft.strokeWidth.toStringAsFixed(1)} px'),
              Slider(
                key: const ValueKey('drawing-cursor-stroke-width'),
                value: _draft.strokeWidth,
                min: DrawingCursorSettings.minStrokeWidth,
                max: DrawingCursorSettings.maxStrokeWidth,
                divisions: 5,
                label: '${_draft.strokeWidth.toStringAsFixed(1)} px',
                onChanged:
                    _saving
                        ? null
                        : (value) => setState(() {
                          _draft = _draft.copyWith(strokeWidth: value);
                        }),
              ),
              DropdownButtonFormField<DrawingCursorColor>(
                itemHeight: null,
                key: ValueKey(_draft.color),
                initialValue: _draft.color,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Barva křížku'),
                selectedItemBuilder:
                    (_) => [
                      for (final color in DrawingCursorColor.values)
                        Text(
                          _colorLabel(color),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                items: [
                  for (final color in DrawingCursorColor.values)
                    DropdownMenuItem(
                      value: color,
                      child: Text(_colorLabel(color)),
                    ),
                ],
                onChanged:
                    _saving
                        ? null
                        : (value) => setState(() {
                          if (value != null) {
                            _draft = _draft.copyWith(color: value);
                          }
                        }),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _saving
                  ? null
                  : () => setState(() {
                    _draft = DrawingCursorSettings.defaults;
                    _error = null;
                  }),
          child: const Text('Výchozí'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Uložit'),
        ),
      ],
    ),
  );
}

String _colorLabel(DrawingCursorColor color) => switch (color) {
  DrawingCursorColor.automatic => 'Automatická podle pozadí',
  DrawingCursorColor.black => 'Černá',
  DrawingCursorColor.white => 'Bílá',
  DrawingCursorColor.red => 'Červená',
  DrawingCursorColor.cyan => 'Tyrkysová',
};
