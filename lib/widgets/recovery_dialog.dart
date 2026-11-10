import 'package:flutter/material.dart';
import '../app/workspace_controller.dart';
import '../services/project_persistence.dart';

Future<void> showRecoveryDialog(
  BuildContext context,
  WorkspaceController workspace,
) async {
  final selected = await showDialog<String>(
    context: context,
    builder: (_) => _RecoveryDialog(workspace),
  );
  if (selected != null && context.mounted) await workspace.restore(selected);
}

class _RecoveryDialog extends StatefulWidget {
  const _RecoveryDialog(this.workspace);
  final WorkspaceController workspace;
  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
  ProjectPersistence get persistence => widget.workspace.active.persistence;
  late var copies = _load();
  String? error;

  Future<List<({String id, SavedProjectSummary? summary, String? error})>>
  _load() async {
    final result =
        <({String id, SavedProjectSummary? summary, String? error})>[];
    for (final id in await persistence.listRecoveryIds()) {
      try {
        result.add((
          id: id,
          summary: await persistence.loadProjectSummary(id),
          error: null,
        ));
      } catch (error) {
        result.add((id: id, summary: null, error: '$error'));
      }
    }
    return result;
  }

  Future<void> remove(SavedProjectSummary summary) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('Odstranit místní projekt „${summary.name}“?'),
            content: SingleChildScrollView(
              child: Text(
                summary.currentFile == null
                    ? 'Projekt a jeho místně uložené změny budou trvale odstraněny.'
                    : 'Místní kopie a její změny budou trvale odstraněny. Zdrojový soubor zůstane na disku.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Zrušit'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Odstranit'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    if (widget.workspace.document(summary.sessionId) != null) {
      setState(() => error = 'Otevřený projekt nejprve zavřete.');
      return;
    }
    try {
      await persistence.removeWorkingCopy(
        summary.sessionId,
        expectedToken: summary.storageToken,
      );
      if (!mounted) return;
      setState(() {
        error = null;
        copies = _load();
      });
    } catch (failure) {
      if (mounted) {
        setState(
          () =>
              error =
                  failure is ProjectStorageConflict
                      ? 'Projekt se mezitím změnil. Obnovte seznam a zkuste odstranění znovu.'
                      : 'Projekt se nepodařilo odstranit: $failure',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        const Expanded(child: Text('Místní projekty')),
        IconButton(
          tooltip: 'Obnovit seznam',
          onPressed:
              () => setState(() {
                error = null;
                copies = _load();
              }),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    content: SizedBox(
      width: 600,
      height: 360,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error != null)
            Text(error!, maxLines: 4, overflow: TextOverflow.ellipsis),
          Expanded(
            child: FutureBuilder(
              future: copies,
              builder: (context, snapshot) {
                if (snapshot.hasError) return Text('${snapshot.error}');
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final rows = snapshot.data!;
                if (rows.isEmpty) {
                  return const Text(
                    'Zatím nemáte žádné místně uložené projekty.',
                  );
                }
                return ListView(
                  children: [
                    const Text(
                      'Výběrem projekt znovu otevřete. Zavřené projekty můžete odstranit a uvolnit místo.',
                    ),
                    for (final row in rows)
                      ListTile(
                        title: Text(row.summary?.name ?? 'Nedostupný projekt'),
                        subtitle: Text(
                          row.error ??
                              '${row.summary?.currentFile?.path ?? 'Uloženo v tomto zařízení'}${row.summary?.hasPendingFileChanges == true ? '\nMístní změny čekají na zápis do souboru' : ''}',
                        ),
                        trailing:
                            row.summary == null
                                ? null
                                : IconButton(
                                  tooltip:
                                      widget.workspace.document(row.id) == null
                                          ? 'Odstranit místní projekt'
                                          : 'Otevřený projekt nejprve zavřete',
                                  onPressed:
                                      widget.workspace.document(row.id) != null
                                          ? null
                                          : () => remove(row.summary!),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                        onTap:
                            row.summary == null
                                ? null
                                : () => Navigator.pop(context, row.id),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Zavřít'),
      ),
    ],
  );
}
