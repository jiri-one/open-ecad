import 'package:flutter/material.dart';
import '../app/workspace_controller.dart';
import '../services/project_persistence.dart';

Future<void> showRecoveryDialog(
  BuildContext context,
  WorkspaceController workspace,
) async {
  final selected = await showDialog<String>(
    context: context,
    builder: (_) => _RecoveryDialog(workspace.active.persistence),
  );
  if (selected != null && context.mounted) await workspace.restore(selected);
}

class _RecoveryDialog extends StatefulWidget {
  const _RecoveryDialog(this.persistence);
  final ProjectPersistence persistence;
  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
  late final copies = _load();

  Future<List<({String id, WorkingCopy? copy, String? error})>> _load() async {
    final result = <({String id, WorkingCopy? copy, String? error})>[];
    for (final id in await widget.persistence.listRecoveryIds()) {
      try {
        result.add((
          id: id,
          copy: await widget.persistence.loadAutosave(sessionId: id),
          error: null,
        ));
      } catch (e) {
        result.add((id: id, copy: null, error: '$e'));
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Obnovit pracovní kopii'),
    content: SizedBox(
      width: 600,
      height: 360,
      child: FutureBuilder(
        future: copies,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Text('${snapshot.error}');
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snapshot.data!;
          if (rows.isEmpty) return const Text('Žádné pracovní kopie.');
          return ListView(
            children: [
              const Text(
                'Kopie jsou od nejnovější. Obnova přidá projekt do pracovního prostoru. Již otevřený projekt pouze aktivuje.',
              ),
              for (final row in rows)
                ListTile(
                  title: Text(row.copy?.project.name ?? 'Nedostupná kopie'),
                  subtitle: Text(
                    row.error ??
                        '${row.copy?.fileName ?? 'Bez souboru'} · revize ${row.copy?.project.revision}${row.copy?.project.revision != row.copy?.savedRevision ? ' · neuložené změny' : ''}',
                  ),
                  onTap:
                      row.copy == null
                          ? null
                          : () => Navigator.pop(context, row.id),
                ),
            ],
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Zrušit'),
      ),
    ],
  );
}
