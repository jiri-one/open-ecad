// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../services/frame_layout.dart';
import '../services/document_layout.dart';
import '../services/frame_template_files.dart';
import 'frame_dialog.dart';
import 'frame_settings_draft.dart';
import 'frame_template_editor.dart';
import 'frame_template_preview.dart';

Future<FrameSettingsDraft?> editFrameSettings(
  BuildContext context,
  EditorController app, {
  String? sheetId,
  FrameSettingsDraft? draft,
  FrameEditGuard? guard,
  FrameTemplateFiles files = const FrameTemplateFiles(),
}) => showDialog<FrameSettingsDraft>(
  context: context,
  builder:
      (_) => FrameSettingsDialog(
        app: app,
        sheetId: sheetId,
        initialDraft: draft,
        guard: guard,
        files: files,
      ),
);

class FrameSettingsDialog extends StatefulWidget {
  const FrameSettingsDialog({
    super.key,
    required this.app,
    this.sheetId,
    this.initialDraft,
    this.guard,
    this.files = const FrameTemplateFiles(),
  });
  final EditorController app;
  final String? sheetId;
  final FrameSettingsDraft? initialDraft;
  final FrameEditGuard? guard;
  final FrameTemplateFiles files;
  @override
  State<FrameSettingsDialog> createState() => _FrameSettingsDialogState();
}

class _FrameSettingsDialogState extends State<FrameSettingsDialog> {
  late final guard =
      widget.guard ?? FrameEditGuard(widget.app, sheetId: widget.sheetId);
  late final draft = FrameSettingsDraft(
    widget.initialDraft?.project ?? guard.project,
    sheetId: widget.sheetId,
  );
  final customKey = TextEditingController();
  late final extraKeys = <String>{
    ...draft.fields.keys,
    ...draft.original.documentFields.keys,
  };
  late String? managedId =
      draft.selectedTemplate?.id ?? draft.templates.firstOrNull?.id;
  String? error;
  String? notice;
  bool busy = false;
  bool get fileOperationCurrent =>
      mounted && guard.current && (ModalRoute.of(context)?.isCurrent ?? false);
  FrameTemplate? get managed =>
      draft.templates.where((t) => t.id == managedId).firstOrNull;
  Sheet get previewSheet =>
      draft.project.sheetById(widget.sheetId ?? '') ??
      draft.project.pages.first;

  @override
  void dispose() {
    customKey.dispose();
    super.dispose();
  }

  void _save() {
    try {
      if (!guard.current) {
        throw const FormatException(FrameEditGuard.staleMessage);
      }
      layoutDocument(draft.project).requireExportable();
      if (widget.initialDraft != null) {
        Navigator.pop(context, draft);
        return;
      }
      final commands = draft.commands();
      if (commands.isEmpty ||
          widget.app.execute(
            commands,
            widget.sheetId == null
                ? 'Rámečky a údaje projektu uloženy'
                : 'Rámeček a údaje listu uloženy',
            expectedRevision: guard.project.revision,
          )) {
        Navigator.pop(context, draft);
      } else {
        setState(() => error = widget.app.status);
      }
    } catch (e) {
      setState(() => error = frameError(e));
    }
  }

  Future<void> _edit(FrameTemplate template) async {
    final edited = await editFrameTemplate(
      context,
      template: template,
      project: draft.project,
      sheet: previewSheet,
      canCommit: () => mounted && guard.current,
      sharedUses: draft.uses(template.id),
    );
    if (!mounted || edited == null) return;
    if (!guard.current) {
      setState(() => error = FrameEditGuard.staleMessage);
      return;
    }
    setState(() {
      draft.replace(edited);
      error = null;
    });
  }

  Future<void> _fileOperation(bool importing) async {
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      if (importing) {
        final template = await widget.files.importTemplate(
          canCommit: () => fileOperationCurrent,
        );
        if (!mounted) return;
        if (template != null) {
          setState(() {
            draft.templates.add(template);
            managedId = template.id;
            notice =
                'Šablona byla načtena jako nová definice. Vyberte ji pro projekt nebo list.';
          });
        }
      } else {
        final template = managed;
        if (template == null) return;
        final path = await widget.files.exportTemplate(
          template,
          canCommit: () => fileOperationCurrent,
        );
        if (!mounted) return;
        if (!guard.current) {
          throw const FormatException(FrameEditGuard.staleMessage);
        }
        if (path != null) {
          setState(
            () =>
                notice =
                    'Definice šablony exportována. Údaje projektu ani kresba nejsou součástí souboru.',
          );
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = frameError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _selection() {
    final selection =
        draft.choice.mode == FrameMode.template
            ? 'template:${draft.choice.templateId}'
            : draft.choice.mode.name;
    final base =
        widget.sheetId != null && draft.choice.mode == FrameMode.inherit
            ? resolveSheetFrame(
              draft.project,
              previewSheet.copyWith(frame: const FrameChoice.inherit()),
            )
            : null;
    Widget part(
      String key,
      String label,
      bool? value,
      bool inherited,
      void Function(bool?) change,
    ) => DropdownButtonFormField<int>(
      key: ValueKey(
        'frame-part-$key-${value ?? 'inherit'}-${draft.choice.mode.name}',
      ),
      initialValue:
          value == null
              ? -1
              : value
              ? 1
              : 0,
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem(
          value: -1,
          child: Text(
            '${draft.choice.mode == FrameMode.inherit ? 'Z projektu' : 'Výchozí'} (${inherited ? 'zapnuto' : 'vypnuto'})',
          ),
        ),
        const DropdownMenuItem(value: 1, child: Text('Zapnuto')),
        const DropdownMenuItem(value: 0, child: Text('Vypnuto')),
      ],
      onChanged: (v) => setState(() => change(v == -1 ? null : v == 1)),
    );
    PreparedFrameLayout? frame;
    String? previewError;
    List<String> diagnostics = const [];
    try {
      final sheet =
          widget.sheetId == null
              ? previewSheet.copyWith(frame: const FrameChoice.inherit())
              : previewSheet;
      final candidate = draft.project.copyWith(
        pages: [
          for (final p in draft.project.pages) p.id == sheet.id ? sheet : p,
        ],
      );
      final page = previewDocumentFrames(
        candidate,
        source: draft.original,
      ).firstPageFor(sheet.id);
      frame = page.frame;
      diagnostics = page.diagnostics;
    } catch (e) {
      previewError = frameError(e);
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('frame-choice-$selection'),
          initialValue: selection,
          isExpanded: true,
          decoration: InputDecoration(
            labelText:
                widget.sheetId == null
                    ? 'Výchozí rámeček projektu'
                    : 'Rámeček listu',
          ),
          items: [
            if (widget.sheetId != null)
              const DropdownMenuItem(
                value: 'inherit',
                child: Text('Z projektu'),
              ),
            const DropdownMenuItem(value: 'none', child: Text('Bez rámečku')),
            for (final t in draft.templates)
              DropdownMenuItem(
                value: 'template:${t.id}',
                child: Text(
                  frameTemplateName(t),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged:
              (v) => setState(() {
                draft.choice =
                    v == 'inherit'
                        ? const FrameChoice.inherit()
                        : v == 'none'
                        ? const FrameChoice.none()
                        : FrameChoice.template(v!.substring(9));
              }),
        ),
        const SizedBox(height: 14),
        if (draft.choice.mode != FrameMode.none) ...[
          if (draft.choice.mode == FrameMode.inherit &&
              draft.project.defaultFrame.mode == FrameMode.none)
            const Text(
              'Projekt nemá rámeček. Pro tento list vyberte šablonu, pokud chcete zobrazit některou jeho část.',
            ),
          part(
            'border',
            'Obvodový rámeček',
            draft.choice.border,
            base?.border ?? (draft.choice.mode != FrameMode.inherit),
            (v) => draft.choice = draft.choice.copyWith(border: v),
          ),
          const SizedBox(height: 14),
          part(
            'title',
            'Popisové razítko',
            draft.choice.titleBlock,
            base?.titleBlock ?? (draft.choice.mode != FrameMode.inherit),
            (v) => draft.choice = draft.choice.copyWith(titleBlock: v),
          ),
          const SizedBox(height: 14),
          part(
            'zones',
            'Souřadnicové zóny',
            draft.choice.zones,
            base?.zones ?? (draft.choice.mode != FrameMode.inherit),
            (v) => draft.choice = draft.choice.copyWith(zones: v),
          ),
        ],
        const SizedBox(height: 12),
        if (draft.selectedTemplate case final template?) ...[
          Text(
            'Šablona „${frameTemplateName(template)}“ je sdílená; používá ji ${draft.uses(template.id)} listů.',
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: busy ? null : () => _edit(template),
                child: const Text('Upravit sdílenou šablonu…'),
              ),
              TextButton(
                key: const ValueKey('frame-independent-copy'),
                onPressed:
                    busy
                        ? null
                        : () => setState(() {
                          managedId = draft.copyForSelection(template).id;
                        }),
                child: const Text('Vytvořit a použít samostatnou kopii'),
              ),
            ],
          ),
        ],
        const Text(
          'Změna rámečku neposouvá ani nezmenšuje existující kresbu. Náhled zobrazuje rámeček bez kresby listu. Šedý obrys označuje prostor pro kresbu.',
        ),
        SizedBox(
          height: 240,
          child:
              frame == null
                  ? Center(child: Text(previewError!))
                  : FrameTemplatePreview(frame: frame),
        ),
        if (frame != null && frame.overflowFieldIds.isNotEmpty)
          Text(
            'Některý text přesahuje pole razítka (červený obrys).',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        for (final diagnostic in diagnostics)
          Text(
            diagnostic,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }

  Widget _metadata() => ListView(
    padding: const EdgeInsets.symmetric(vertical: 12),
    children: [
      Text(
        widget.sheetId == null
            ? 'Údaje projektu se použijí na listech, které nemají vlastní hodnotu.'
            : '„Z projektu“ dědí hodnotu. „Potlačit“ uloží prázdnou hodnotu pouze pro tento list. Revize výkresu není pořadí úprav projektu.',
      ),
      const SizedBox(height: 12),
      for (final key in {...frameDocumentLabels.keys, ...extraKeys})
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _FrameDocumentRow(
            key: ValueKey('document-$key'),
            label: frameDocumentLabels[key] ?? 'Vlastní údaj: $key',
            value: draft.fields[key],
            inherited:
                widget.sheetId == null
                    ? null
                    : draft.original.documentFields[key] ?? '',
            sheet: widget.sheetId != null,
            onChanged: (value) {
              setState(() {
                if (value == null) {
                  draft.fields.remove(key);
                } else {
                  draft.fields[key] = value;
                }
              });
            },
          ),
        ),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('frame-metadata-key'),
              controller: customKey,
              decoration: const InputDecoration(
                labelText: 'Klíč nového údaje',
                hintText: 'naprZakazka',
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              final key = customKey.text.trim();
              if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$').hasMatch(key)) {
                setState(
                  () =>
                      error =
                          'Klíč musí začínat písmenem; použijte písmena bez diakritiky, číslice a podtržítko (nejvýše 64 znaků).',
                );
                return;
              }
              setState(() {
                extraKeys.add(key);
                customKey.clear();
                error = null;
              });
            },
            child: const Text('Přidat údaj'),
          ),
        ],
      ),
    ],
  );

  Widget _templates() => ListView(
    padding: const EdgeInsets.symmetric(vertical: 12),
    children: [
      const Text(
        'Šablony jsou uložené v projektu a sdílené jeho listy. Pro použití v jiném projektu exportujte definici do souboru .oecadframe a tam ji importujte. Import vždy vytvoří novou šablonu.',
      ),
      const SizedBox(height: 14),
      DropdownButtonFormField<String>(
        key: ValueKey('managed-template-$managedId'),
        initialValue: managedId,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Spravovaná šablona'),
        items: [
          for (final t in draft.templates)
            DropdownMenuItem(
              value: t.id,
              child: Text(
                frameTemplateName(t),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: busy ? null : (v) => setState(() => managedId = v),
      ),
      const SizedBox(height: 8),
      if (managed case final template?) ...[
        Text(
          'Používá ${draft.uses(template.id)} listů${draft.project.defaultFrame.templateId == template.id ? ' • výchozí šablona projektu' : ''}.',
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: busy ? null : () => _edit(template),
              child: const Text('Upravit rozvržení / název…'),
            ),
            OutlinedButton(
              key: const ValueKey('frame-duplicate'),
              onPressed:
                  busy
                      ? null
                      : () => setState(() {
                        final copy = template.copyWith(
                          id: newId('frame'),
                          name: '${frameTemplateName(template)} – kopie',
                        );
                        draft.templates.add(copy);
                        managedId = copy.id;
                      }),
              child: const Text('Duplikovat'),
            ),
            OutlinedButton(
              key: const ValueKey('frame-delete-template'),
              onPressed:
                  busy
                      ? null
                      : () {
                        try {
                          draft.delete(template.id);
                          setState(() {
                            managedId = draft.templates.firstOrNull?.id;
                            error = null;
                          });
                        } catch (e) {
                          setState(() => error = frameError(e));
                        }
                      },
              child: const Text('Odstranit'),
            ),
            OutlinedButton(
              key: const ValueKey('frame-export'),
              onPressed: busy ? null : () => _fileOperation(false),
              child: const Text('Exportovat definici…'),
            ),
          ],
        ),
      ],
      const Divider(height: 32),
      Wrap(
        spacing: 8,
        children: [
          FilledButton.tonal(
            key: const ValueKey('frame-new-template'),
            onPressed:
                busy
                    ? null
                    : () => setState(() {
                      final next = FrameTemplate(
                        id: newId('frame'),
                        name: 'Nový rámeček',
                        titleBlock: FrameTitleBlock(widthMm: 180, heightMm: 36),
                      );
                      draft.templates.add(next);
                      managedId = next.id;
                    }),
            child: const Text('Nová prázdná šablona'),
          ),
          OutlinedButton(
            key: const ValueKey('frame-import'),
            onPressed: busy ? null : () => _fileOperation(true),
            child: const Text('Importovat definici…'),
          ),
        ],
      ),
      if (notice != null)
        Padding(padding: const EdgeInsets.only(top: 12), child: Text(notice!)),
    ],
  );

  @override
  Widget build(BuildContext context) => FrameDialog(
    title:
        widget.sheetId == null
            ? 'Rámečky a údaje projektu'
            : 'Rámeček a údaje listu',
    error: error,
    busy: busy,
    onSave: _save,
    saveLabel: widget.initialDraft == null ? 'Uložit' : 'Použít v návrhu',
    child: DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Výběr rámečku'),
              Tab(text: 'Údaje'),
              Tab(text: 'Šablony'),
            ],
          ),
          Expanded(
            child: AbsorbPointer(
              absorbing: busy,
              child: TabBarView(
                children: [_selection(), _metadata(), _templates()],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _FrameDocumentRow extends StatefulWidget {
  const _FrameDocumentRow({
    super.key,
    required this.label,
    required this.value,
    required this.inherited,
    required this.sheet,
    required this.onChanged,
  });
  final String label;
  final String? value, inherited;
  final bool sheet;
  final ValueChanged<String?> onChanged;
  @override
  State<_FrameDocumentRow> createState() => _FrameDocumentRowState();
}

class _FrameDocumentRowState extends State<_FrameDocumentRow> {
  late int mode =
      widget.value == null
          ? 0
          : widget.value!.isEmpty
          ? 1
          : 2;
  late final text = TextEditingController(text: widget.value ?? '');
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DropdownButtonFormField<int>(
        initialValue: mode,
        decoration: InputDecoration(labelText: widget.label),
        items: [
          DropdownMenuItem(
            value: 0,
            child: Text(widget.sheet ? 'Z projektu' : 'Neuvedeno'),
          ),
          const DropdownMenuItem(
            value: 1,
            child: Text('Potlačit (prázdný text)'),
          ),
          const DropdownMenuItem(value: 2, child: Text('Vlastní hodnota')),
        ],
        onChanged:
            (v) => setState(() {
              mode = v!;
              widget.onChanged(
                mode == 0
                    ? null
                    : mode == 1
                    ? ''
                    : text.text,
              );
            }),
      ),
      if (mode == 2)
        TextField(
          controller: text,
          maxLength: FrameLimits.text,
          decoration: const InputDecoration(
            labelText: 'Hodnota',
            counterText: '',
          ),
          onChanged: widget.onChanged,
        ),
      if (mode == 0 && widget.sheet)
        Text(
          'Z projektu: ${widget.inherited!.isEmpty ? '(prázdné)' : widget.inherited}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
    ],
  );
}
