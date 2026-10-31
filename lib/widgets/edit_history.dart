// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';

Future<void> showEditHistoryDialog({
  required BuildContext context,
  required List<EditHistoryEntry> undoHistory,
  required List<EditHistoryEntry> redoHistory,
  required ValueChanged<int> onUndoSteps,
  required ValueChanged<int> onRedoSteps,
  int historyLimit = 100,
}) {
  final undo = List<EditHistoryEntry>.unmodifiable(undoHistory);
  final redo = List<EditHistoryEntry>.unmodifiable(redoHistory);
  var chosen = false;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      void choose(int count, ValueChanged<int> callback) {
        if (chosen) return;
        chosen = true;
        Navigator.of(dialogContext).pop();
        callback(count);
      }

      return AlertDialog(
        constraints: const BoxConstraints(maxWidth: 840),
        title: const Text('Historie úprav'),
        content: SizedBox(
          width: 760,
          height: MediaQuery.sizeOf(dialogContext).height * .65,
          child: EditHistoryView(
            undoHistory: undo,
            redoHistory: redo,
            historyLimit: historyLimit,
            onUndoSteps: (count) => choose(count, onUndoSteps),
            onRedoSteps: (count) => choose(count, onRedoSteps),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Zavřít'),
          ),
        ],
      );
    },
  );
}

class EditHistoryView extends StatelessWidget {
  const EditHistoryView({
    super.key,
    required this.undoHistory,
    required this.redoHistory,
    this.onUndoSteps,
    this.onRedoSteps,
    this.historyLimit = 100,
  });

  final List<EditHistoryEntry> undoHistory;
  final List<EditHistoryEntry> redoHistory;
  final ValueChanged<int>? onUndoSteps;
  final ValueChanged<int>? onRedoSteps;
  final int historyLimit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state =
        undoHistory.isNotEmpty
            ? 'Po akci: ${_label(undoHistory.first)}'
            : redoHistory.isNotEmpty
            ? 'Nejstarší dostupný stav.'
            : 'V této relaci zatím nejsou zaznamenané úpravy.';
    return ListView(
      key: const ValueKey('edit-history-scroll'),
      primary: false,
      children: [
        Card(
          margin: EdgeInsets.zero,
          color: theme.colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Aktuální stav', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(state),
                const SizedBox(height: 4),
                Text(
                  'K vrácení: ${undoHistory.length} · K obnovení: ${redoHistory.length}',
                ),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'Nejbližší krok je nahoře. Výběr zahrne zvolenou akci '
            'i všechny kroky nad ní v daném seznamu.',
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final undo = _HistorySection(
              undo: true,
              entries: undoHistory,
              onSteps: onUndoSteps,
            );
            final redo = _HistorySection(
              undo: false,
              entries: redoHistory,
              onSteps: onRedoSteps,
            );
            if (constraints.maxWidth >= 600) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: undo),
                  const SizedBox(width: 16),
                  Expanded(child: redo),
                ],
              );
            }
            return Column(children: [undo, const SizedBox(height: 16), redo]);
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(
            'Maximální počet uchovaných úprav v této relaci: $historyLimit. '
            'Starší kroky nad tento limit nejsou dostupné. '
            'Otevření nebo obnova projektu začíná novou historii. '
            'Nová úprava zruší kroky k obnovení.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _HistorySection extends StatefulWidget {
  const _HistorySection({
    required this.undo,
    required this.entries,
    required this.onSteps,
  });

  final bool undo;
  final List<EditHistoryEntry> entries;
  final ValueChanged<int>? onSteps;

  @override
  State<_HistorySection> createState() => _HistorySectionState();
}

class _HistorySectionState extends State<_HistorySection> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final undo = widget.undo;
    final entries = widget.entries;
    final onSteps = widget.onSteps;
    final empty = undo ? 'Není co vrátit.' : 'Není co obnovit.';
    final verb = undo ? 'Vrátit' : 'Obnovit';
    final shortcut = undo ? 'Ctrl+Z' : 'Ctrl+Y';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                undo ? 'Akce k vrácení' : 'Akce k obnovení',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip:
                  entries.isEmpty
                      ? '$empty ($shortcut)'
                      : '$verb: ${_label(entries.first)} ($shortcut)',
              onPressed:
                  entries.isEmpty || onSteps == null
                      ? null
                      : () => onSteps(entries.first.steps),
              icon: Icon(undo ? Icons.undo : Icons.redo),
            ),
          ],
        ),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(empty),
          )
        else
          SizedBox(
            height: 280,
            child: Scrollbar(
              controller: _scrollController,
              thumbVisibility: true,
              child: ListView.builder(
                key: ValueKey(undo ? 'edit-history-undo' : 'edit-history-redo'),
                controller: _scrollController,
                primary: false,
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final steps = entry.steps;
                  final action = switch (steps) {
                    1 => '$verb tento krok',
                    >= 2 && <= 4 => '$verb tyto $steps kroky',
                    _ => '$verb těchto $steps kroků',
                  };
                  return ListTile(
                    enabled: onSteps != null,
                    title: Text(_label(entry)),
                    subtitle: Text(action),
                    onTap: onSteps == null ? null : () => onSteps(steps),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

String _label(EditHistoryEntry entry) =>
    entry.label.trim().isEmpty ? 'Úprava bez názvu' : entry.label;
