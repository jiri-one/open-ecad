// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';

import 'sheet_filter.dart';

Future<SheetFilter?> showSheetFilterDialog(
  BuildContext context, {
  required SheetFilter initial,
  required Listenable changes,
  required Iterable<Sheet> Function() sheets,
}) => showDialog<SheetFilter>(
  context: context,
  builder:
      (_) =>
          SheetFilterDialog(initial: initial, changes: changes, sheets: sheets),
);

class SheetFilterDialog extends StatefulWidget {
  const SheetFilterDialog({
    super.key,
    required this.initial,
    required this.changes,
    required this.sheets,
  });
  final SheetFilter initial;
  final Listenable changes;
  final Iterable<Sheet> Function() sheets;

  @override
  State<SheetFilterDialog> createState() => _SheetFilterDialogState();
}

class _SheetFilterDialogState extends State<SheetFilterDialog> {
  late final Map<String, TextEditingController> _fields;
  late final Set<SheetType> _types;
  SheetPaperFormat? _format;
  SheetOrientation? _orientation;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _fields = {
      for (final entry
          in {
            'query': initial.query,
            'name': initial.name,
            'number': initial.number,
            'function': initial.function,
            'location': initial.location,
            'product': initial.product,
            'documentCode': initial.documentCode,
          }.entries)
        entry.key: TextEditingController(text: entry.value),
    };
    _types = {...initial.types};
    _format = initial.paperFormat;
    _orientation = initial.orientation;
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  SheetFilter get _draft => SheetFilter(
    query: _fields['query']!.text,
    name: _fields['name']!.text,
    number: _fields['number']!.text,
    function: _fields['function']!.text,
    location: _fields['location']!.text,
    product: _fields['product']!.text,
    documentCode: _fields['documentCode']!.text,
    types: _types,
    paperFormat: _format,
    orientation: _orientation,
  );

  void _apply() => Navigator.of(context).pop(_draft);

  void _reset() => setState(() {
    for (final field in _fields.values) {
      field.clear();
    }
    _types.clear();
    _format = null;
    _orientation = null;
  });

  Widget _field(String name, String label, {String? hint}) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      key: ValueKey('sheet-filter-$name'),
      controller: _fields[name],
      decoration: InputDecoration(
        labelText: label,
        helper: hint == null ? null : Text(hint),
      ),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _apply(),
    ),
  );

  Widget _dialog() {
    final sheets = widget.sheets().toList();
    final draft = _draft;
    final count = sheets.where(draft.matches).length;
    final formats =
        {
            for (final sheet in sheets) sheetPaperFormat(sheet),
            if (_format != null) _format!,
          }.toList()
          ..sort((a, b) {
            final result = a.shortSide.compareTo(b.shortSide);
            return result == 0 ? a.longSide.compareTo(b.longSide) : result;
          });
    return AlertDialog(
      title: const Text('Filtr listů'),
      scrollable: true,
      insetPadding: const EdgeInsets.all(24),
      content: SizedBox(
        width: 600,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Nalezeno: $count / ${sheets.length}',
              key: const ValueKey('sheet-filter-result-count'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Vyplněná kritéria se kombinují. Text stačí zadat částečně a bez diakritiky.',
            ),
            const SizedBox(height: 20),
            _field(
              'query',
              'Rychlé hledání',
              hint: 'Název, číslo, typ nebo úplné označení listu.',
            ),
            _field('name', 'Název listu'),
            _field('number', 'Číslo listu'),
            const Text(
              'Typ listu',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilterChip(
                  label: const Text('Všechny typy'),
                  selected: _types.isEmpty,
                  onSelected: (_) => setState(_types.clear),
                ),
                for (final type in SheetType.values)
                  FilterChip(
                    key: ValueKey('sheet-filter-type-${type.name}'),
                    label: Text(type.label),
                    selected: _types.contains(type),
                    onSelected:
                        (selected) => setState(() {
                          if (selected) {
                            _types.add(type);
                          } else {
                            _types.remove(type);
                          }
                        }),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            _field('function', 'Označení funkce (=)'),
            _field('location', 'Označení umístění (+)'),
            _field(
              'product',
              'Označení produktu (-)',
              hint: 'Přístroj nebo sestava ve struktuře listu.',
            ),
            _field('documentCode', 'Kód dokumentu (&)'),
            DropdownButtonFormField<SheetPaperFormat>(
              key: const ValueKey('sheet-filter-paper-format'),
              initialValue: _format,
              itemHeight: null,
              isDense: false,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Formát papíru'),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('Všechny formáty'),
                ),
                for (final format in formats)
                  DropdownMenuItem(
                    value: format,
                    child: Text(sheetPaperFormatLabel(format)),
                  ),
              ],
              onChanged: (value) => setState(() => _format = value),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<SheetOrientation>(
              key: const ValueKey('sheet-filter-orientation'),
              initialValue: _orientation,
              itemHeight: null,
              isDense: false,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Orientace'),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('Libovolná orientace'),
                ),
                for (final orientation in SheetOrientation.values)
                  DropdownMenuItem(
                    value: orientation,
                    child: Text(orientation.label),
                  ),
              ],
              onChanged: (value) => setState(() => _orientation = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _reset, child: const Text('Vymazat kritéria')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušit'),
        ),
        FilledButton(onPressed: _apply, child: const Text('Použít filtr')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.changes,
    builder: (context, _) => _dialog(),
  );
}
