// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../services/interface_preferences.dart';

Future<void> showInterfaceSettingsDialog(
  BuildContext context, {
  required InterfacePreferences preferences,
}) async {
  try {
    await showDialog<void>(
      context: context,
      builder: (_) => InterfaceSettingsDialog(preferences: preferences),
    );
  } finally {
    preferences.preview(null);
  }
}

class InterfaceSettingsDialog extends StatefulWidget {
  const InterfaceSettingsDialog({super.key, required this.preferences});
  final InterfacePreferences preferences;

  @override
  State<InterfaceSettingsDialog> createState() =>
      _InterfaceSettingsDialogState();
}

class _InterfaceSettingsDialogState extends State<InterfaceSettingsDialog> {
  double _draft = 1;
  bool _loading = true, _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.preferences.load();
      if (!mounted) return;
      setState(() {
        _draft = widget.preferences.scale;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Nastavení se nepodařilo načíst. Zkuste dialog otevřít znovu.';
      });
    }
  }

  void _preview(double value) {
    setState(() => _draft = value);
    widget.preferences.preview(value);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.preferences.save(_draft);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Nastavení se nepodařilo uložit. Zkuste to znovu.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('Písmo rozhraní'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Výchozí velikost vychází z nastavení systému. Zde ji můžete dále zvětšit.',
            ),
            const SizedBox(height: 16),
            Text('Zvětšení písma: ${(_draft * 100).round()} %'),
            Slider(
              key: const ValueKey('interface-text-scale'),
              value: _draft,
              min: InterfacePreferences.minScale,
              max: InterfacePreferences.maxScale,
              divisions: 20,
              label: '${(_draft * 100).round()} %',
              onChanged: _loading || _saving ? null : _preview,
            ),
            const Text('Přívod čerpadla · svorka X1:12'),
            const SizedBox(height: 12),
            const Text(
              'Změna platí pro všechny projekty. Měřítko výkresu a velikost textů při exportu se nemění.',
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
      actions: [
        TextButton(
          onPressed: _loading || _saving ? null : () => _preview(1),
          child: const Text('Podle systému'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _loading || _saving ? null : _save,
          child: const Text('Uložit'),
        ),
      ],
    ),
  );
}
