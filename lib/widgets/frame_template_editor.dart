// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';

import '../services/frame_layout.dart';
import '../services/document_layout.dart';
import 'frame_dialog.dart';
import 'frame_settings_draft.dart';
import 'frame_template_preview.dart';

Future<FrameTemplate?> editFrameTemplate(
  BuildContext context, {
  required FrameTemplate template,
  required EcadProject project,
  required Sheet sheet,
  required bool Function() canCommit,
  int sharedUses = 0,
}) => showDialog<FrameTemplate>(
  context: context,
  builder:
      (_) => FrameTemplateEditor(
        template: template,
        project: project,
        sheet: sheet,
        canCommit: canCommit,
        sharedUses: sharedUses,
      ),
);

class FrameTemplateEditor extends StatefulWidget {
  const FrameTemplateEditor({
    super.key,
    required this.template,
    required this.project,
    required this.sheet,
    required this.canCommit,
    this.sharedUses = 0,
  });
  final FrameTemplate template;
  final EcadProject project;
  final Sheet sheet;
  final bool Function() canCommit;
  final int sharedUses;

  @override
  State<FrameTemplateEditor> createState() => _FrameTemplateEditorState();
}

class _FrameTemplateEditorState extends State<FrameTemplateEditor> {
  late FrameTemplate draft = widget.template;
  late final name = TextEditingController(text: frameTemplateName(draft));
  final text = TextEditingController();
  final customBinding = TextEditingController();
  final invalidNumbers = <String>{};
  final numericText = <String, String>{};
  String? selected;
  String? error;
  bool detail = true;
  SizeMm? paper;

  FrameField? get field =>
      draft.titleBlock.fields.where((f) => f.id == selected).firstOrNull;

  @override
  void initState() {
    super.initState();
    _select(draft.titleBlock.fields.firstOrNull?.id);
  }

  @override
  void dispose() {
    name.dispose();
    text.dispose();
    customBinding.dispose();
    super.dispose();
  }

  void _select(String? id) {
    selected = id;
    text.text = field?.text ?? '';
  }

  void _change(FrameTemplate value) => setState(() {
    draft = value;
    error = null;
  });
  void _field(FrameField value) => _change(
    draft.copyWith(
      titleBlock: draft.titleBlock.copyWith(
        fields: [
          for (final f in draft.titleBlock.fields) f.id == value.id ? value : f,
        ],
      ),
    ),
  );

  void _move(String id, Vec2 delta) {
    final f = draft.titleBlock.fields.firstWhere((f) => f.id == id);
    final r = f.rectMm;
    final x = (r.x + delta.x).clamp(
      0.0,
      math.max(0.0, draft.titleBlock.widthMm - r.width),
    );
    final y = (r.y + delta.y).clamp(
      0.0,
      math.max(0.0, draft.titleBlock.heightMm - r.height),
    );
    for (final axis in ['x', 'y']) {
      numericText.remove('field-$id-$axis');
      invalidNumbers.remove('field-$id-$axis');
    }
    _field(f.copyWith(rectMm: r.copyWith(x: x.toDouble(), y: y.toDouble())));
  }

  Widget _number(
    String key,
    String label,
    num value,
    ValueChanged<double> changed, {
    bool integer = false,
  }) => SizedBox(
    width: 145,
    child: _FrameNumberInput(
      key: ValueKey(key),
      label: label,
      value: value.toDouble(),
      rawValue: numericText[key],
      onText: (source) => numericText[key] = source,
      integer: integer,
      onChanged: changed,
      onValidity: (valid) {
        if (valid) {
          invalidNumbers.remove(key);
        } else {
          invalidNumbers.add(key);
        }
      },
    ),
  );

  Widget _numbers(List<Widget> children) =>
      Wrap(spacing: 12, runSpacing: 12, children: children);
  Widget _section(String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 14),
    child: Text(label, style: Theme.of(context).textTheme.titleSmall),
  );
  Widget _scroll(List<Widget> children) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  Widget _dimensions() {
    final m = draft.marginsMm, z = draft.zones, b = draft.titleBlock;
    return _scroll([
      TextField(
        key: const ValueKey('frame-template-name'),
        controller: name,
        decoration: const InputDecoration(labelText: 'Název šablony'),
        onChanged: (v) => _change(draft.copyWith(name: v)),
      ),
      _section('Okraje papíru (mm)'),
      _numbers([
        _number(
          'margin-left',
          'Levý',
          m.left,
          (v) => _change(draft.copyWith(marginsMm: m.copyWith(left: v))),
        ),
        _number(
          'margin-right',
          'Pravý',
          m.right,
          (v) => _change(draft.copyWith(marginsMm: m.copyWith(right: v))),
        ),
        _number(
          'margin-top',
          'Horní',
          m.top,
          (v) => _change(draft.copyWith(marginsMm: m.copyWith(top: v))),
        ),
        _number(
          'margin-bottom',
          'Dolní',
          m.bottom,
          (v) => _change(draft.copyWith(marginsMm: m.copyWith(bottom: v))),
        ),
        _number(
          'content-padding',
          'Odstup kresby',
          draft.contentPaddingMm,
          (v) => _change(draft.copyWith(contentPaddingMm: v)),
        ),
        _number(
          'stroke-width',
          'Tloušťka čar',
          draft.strokeWidthMm,
          (v) => _change(draft.copyWith(strokeWidthMm: v)),
        ),
      ]),
      _section('Razítko v pravém dolním rohu (mm)'),
      _numbers([
        _number(
          'title-width',
          'Šířka',
          b.widthMm,
          (v) => _change(draft.copyWith(titleBlock: b.copyWith(widthMm: v))),
        ),
        _number(
          'title-height',
          'Výška',
          b.heightMm,
          (v) => _change(draft.copyWith(titleBlock: b.copyWith(heightMm: v))),
        ),
      ]),
      _section('Souřadnicové zóny'),
      _numbers([
        _number(
          'zones-columns',
          'Počet sloupců',
          z.columns,
          (v) => _change(draft.copyWith(zones: z.copyWith(columns: v.toInt()))),
          integer: true,
        ),
        _number(
          'zones-rows',
          'Počet řádků',
          z.rows,
          (v) => _change(draft.copyWith(zones: z.copyWith(rows: v.toInt()))),
          integer: true,
        ),
        _number(
          'zones-band',
          'Pásmo (mm)',
          z.bandMm,
          (v) => _change(draft.copyWith(zones: z.copyWith(bandMm: v))),
        ),
        _number(
          'zones-tick',
          'Značka (mm)',
          z.tickMm,
          (v) => _change(draft.copyWith(zones: z.copyWith(tickMm: v))),
        ),
        _number(
          'zones-font',
          'Písmo (mm)',
          z.fontSizeMm,
          (v) => _change(draft.copyWith(zones: z.copyWith(fontSizeMm: v))),
        ),
      ]),
    ]);
  }

  void _insert(String binding) {
    final selection = text.selection;
    final start = selection.isValid ? selection.start : text.text.length;
    final end = selection.isValid ? selection.end : start;
    final token = '{{$binding}}';
    final next = text.text.replaceRange(start, end, token);
    text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + token.length),
    );
    if (field case final f?) _field(f.copyWith(text: next));
  }

  Widget _fields() {
    final f = field;
    String? bindingError;
    if (f != null) {
      try {
        validateFrameText(f.text);
      } catch (e) {
        bindingError = frameError(e);
      }
    }
    return _scroll([
      const Text(
        'Vyberte pole kliknutím v náhledu nebo v seznamu. Tažením změníte jeho polohu. Souřadnice jsou od levého horního rohu razítka.',
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        itemHeight: null,
        key: ValueKey('field-picker-$selected'),
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Pole razítka'),
        items: [
          for (var i = 0; i < draft.titleBlock.fields.length; i++)
            DropdownMenuItem(
              value: draft.titleBlock.fields[i].id,
              child: Text(
                '${i + 1}. ${draft.titleBlock.fields[i].text.isEmpty ? 'Prázdné pole' : draft.titleBlock.fields[i].text}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) => setState(() => _select(v)),
      ),
      Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            key: const ValueKey('frame-add-field'),
            onPressed: () {
              final next = FrameField(
                id: newId('field'),
                rectMm: RectMm(
                  x: 1,
                  y: 1,
                  width: math.max(
                    .1,
                    math.min(40, draft.titleBlock.widthMm - 2),
                  ),
                  height: math.max(
                    .1,
                    math.min(8, draft.titleBlock.heightMm - 2),
                  ),
                ),
                text: 'Nové pole',
              );
              setState(() {
                draft = draft.copyWith(
                  titleBlock: draft.titleBlock.copyWith(
                    fields: [...draft.titleBlock.fields, next],
                  ),
                );
                _select(next.id);
              });
            },
            icon: const Icon(Icons.add),
            label: const Text('Přidat pole'),
          ),
          TextButton.icon(
            onPressed:
                f == null
                    ? null
                    : () => setState(() {
                      invalidNumbers.removeWhere(
                        (key) => key.startsWith('field-${f.id}-'),
                      );
                      numericText.removeWhere(
                        (key, _) => key.startsWith('field-${f.id}-'),
                      );
                      draft = draft.copyWith(
                        titleBlock: draft.titleBlock.copyWith(
                          fields:
                              draft.titleBlock.fields
                                  .where((v) => v.id != f.id)
                                  .toList(),
                        ),
                      );
                      _select(draft.titleBlock.fields.firstOrNull?.id);
                    }),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Odstranit pole'),
          ),
        ],
      ),
      if (f != null) ...[
        TextField(
          key: const ValueKey('frame-field-text'),
          controller: text,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(
            labelText: 'Text a vazby',
            errorText: bindingError,
          ),
          onChanged: (v) => _field(f.copyWith(text: v)),
        ),
        PopupMenuButton<String>(
          tooltip: 'Vložit údaj do textu',
          onSelected: _insert,
          itemBuilder:
              (_) => [
                for (final e in _bindingLabels.entries)
                  PopupMenuItem(value: e.key, child: Text(e.value)),
                for (final e in frameDocumentLabels.entries)
                  PopupMenuItem(
                    value: 'document.${e.key}',
                    child: Text(e.value),
                  ),
                for (final key in {
                  ...widget.project.documentFields.keys,
                  ...widget.sheet.documentFields.keys,
                }.where((k) => !frameDocumentLabels.containsKey(k)))
                  PopupMenuItem(
                    value: 'document.$key',
                    child: Text('Vlastní údaj: $key'),
                  ),
              ],
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Icon(Icons.add_link),
                SizedBox(width: 8),
                Text('Vložit údaj…'),
              ],
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('frame-custom-binding'),
                controller: customBinding,
                decoration: const InputDecoration(
                  labelText: 'Klíč vlastního údaje',
                  hintText: 'naprZakazka',
                ),
              ),
            ),
            IconButton(
              tooltip: 'Vložit vlastní údaj',
              onPressed: () {
                final key = customBinding.text.trim();
                try {
                  if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$').hasMatch(key)) {
                    throw const FormatException(
                      'Klíč musí začínat písmenem; použijte písmena bez diakritiky, číslice a podtržítko (nejvýše 64 znaků).',
                    );
                  }
                  validateFrameText('{{document.$key}}');
                  _insert('document.$key');
                } catch (e) {
                  setState(() => error = frameError(e));
                }
              },
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        _section('Poloha a velikost pole (mm)'),
        _numbers([
          _number(
            'field-${f.id}-x',
            'X',
            f.rectMm.x,
            (v) => _field(f.copyWith(rectMm: f.rectMm.copyWith(x: v))),
          ),
          _number(
            'field-${f.id}-y',
            'Y',
            f.rectMm.y,
            (v) => _field(f.copyWith(rectMm: f.rectMm.copyWith(y: v))),
          ),
          _number(
            'field-${f.id}-width',
            'Šířka pole',
            f.rectMm.width,
            (v) => _field(f.copyWith(rectMm: f.rectMm.copyWith(width: v))),
          ),
          _number(
            'field-${f.id}-height',
            'Výška pole',
            f.rectMm.height,
            (v) => _field(f.copyWith(rectMm: f.rectMm.copyWith(height: v))),
          ),
          _number(
            'field-${f.id}-font',
            'Písmo',
            f.fontSizeMm,
            (v) => _field(f.copyWith(fontSizeMm: v)),
          ),
          _number(
            'field-${f.id}-min-font',
            'Nejmenší písmo',
            f.minFontSizeMm,
            (v) => _field(f.copyWith(minFontSizeMm: v)),
          ),
        ]),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Tučné písmo'),
          value: f.bold,
          onChanged: (v) => _field(f.copyWith(bold: v)),
        ),
        DropdownButtonFormField<FrameTextAlign>(
          itemHeight: null,
          isExpanded: true,
          key: ValueKey('align-${f.id}-${f.align}'),
          initialValue: f.align,
          decoration: const InputDecoration(labelText: 'Zarovnání'),
          items: const [
            DropdownMenuItem(value: FrameTextAlign.left, child: Text('Vlevo')),
            DropdownMenuItem(
              value: FrameTextAlign.center,
              child: Text('Na střed'),
            ),
            DropdownMenuItem(
              value: FrameTextAlign.right,
              child: Text('Vpravo'),
            ),
          ],
          onChanged: (v) => _field(f.copyWith(align: v)),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<FrameTextOverflow>(
          itemHeight: null,
          isExpanded: true,
          key: ValueKey('overflow-${f.id}-${f.overflow}'),
          initialValue: f.overflow,
          decoration: const InputDecoration(labelText: 'Dlouhý text'),
          items: const [
            DropdownMenuItem(
              value: FrameTextOverflow.shrink,
              child: Text(
                'Zmenšit až na nejmenší písmo',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem(
              value: FrameTextOverflow.wrap,
              child: Text(
                'Zalomit do více řádků',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          onChanged: (v) => _field(f.copyWith(overflow: v)),
        ),
      ],
    ]);
  }

  Widget _lines() => _scroll([
    const Text(
      'Oddělovače razítka: koncové body v mm od jeho levého horního rohu. Změnou obou bodů posunete celou čáru.',
    ),
    TextButton.icon(
      key: const ValueKey('frame-add-line'),
      onPressed:
          () => _change(
            draft.copyWith(
              titleBlock: draft.titleBlock.copyWith(
                lines: [
                  ...draft.titleBlock.lines,
                  FrameLine(
                    Vec2(0, draft.titleBlock.heightMm / 2),
                    Vec2(
                      draft.titleBlock.widthMm,
                      draft.titleBlock.heightMm / 2,
                    ),
                  ),
                ],
              ),
            ),
          ),
      icon: const Icon(Icons.add),
      label: const Text('Přidat oddělovač'),
    ),
    for (var i = 0; i < draft.titleBlock.lines.length; i++) ...[
      Row(
        children: [
          Expanded(child: _section('Oddělovač ${i + 1}')),
          IconButton(
            tooltip: 'Odstranit oddělovač ${i + 1}',
            onPressed: () {
              invalidNumbers.removeWhere((key) => key.startsWith('line-'));
              numericText.removeWhere((key, _) => key.startsWith('line-'));
              _change(
                draft.copyWith(
                  titleBlock: draft.titleBlock.copyWith(
                    lines: [...draft.titleBlock.lines]..removeAt(i),
                  ),
                ),
              );
            },
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      _numbers([
        _number(
          'line-$i-x1',
          'Začátek X',
          draft.titleBlock.lines[i].from.x,
          (v) => _line(i, from: Vec2(v, draft.titleBlock.lines[i].from.y)),
        ),
        _number(
          'line-$i-y1',
          'Začátek Y',
          draft.titleBlock.lines[i].from.y,
          (v) => _line(i, from: Vec2(draft.titleBlock.lines[i].from.x, v)),
        ),
        _number(
          'line-$i-x2',
          'Konec X',
          draft.titleBlock.lines[i].to.x,
          (v) => _line(i, to: Vec2(v, draft.titleBlock.lines[i].to.y)),
        ),
        _number(
          'line-$i-y2',
          'Konec Y',
          draft.titleBlock.lines[i].to.y,
          (v) => _line(i, to: Vec2(draft.titleBlock.lines[i].to.x, v)),
        ),
      ]),
    ],
  ]);

  void _line(int index, {Vec2? from, Vec2? to}) => _change(
    draft.copyWith(
      titleBlock: draft.titleBlock.copyWith(
        lines: [
          for (var i = 0; i < draft.titleBlock.lines.length; i++)
            i == index
                ? draft.titleBlock.lines[i].copyWith(from: from, to: to)
                : draft.titleBlock.lines[i],
        ],
      ),
    ),
  );

  EcadProject _candidate() => widget.project.copyWith(
    frameTemplates: [
      for (final template in widget.project.frameTemplates)
        if (template.id != draft.id) template,
      draft,
    ],
  );

  PreparedFrameLayout _prepare() {
    draft.validate();
    final effective = resolveSheetFrame(widget.project, widget.sheet);
    final candidate = _candidate().copyWith(
      pages: [
        for (final sheet in widget.project.pages)
          if (sheet.id == widget.sheet.id)
            sheet.copyWith(
              frame: FrameChoice.template(
                draft.id,
                border: effective?.border,
                titleBlock: effective?.titleBlock,
                zones: effective?.zones,
              ),
              paperSizeMm: paper ?? sheet.paperSizeMm,
            )
          else
            sheet,
      ],
    );
    final page = previewDocumentFrames(
      candidate,
      source: widget.project,
    ).firstPageFor(widget.sheet.id);
    if (page.layoutError case final message?) {
      throw FormatException(message);
    }
    return page.frame;
  }

  void _save() {
    try {
      if (!widget.canCommit()) {
        throw const FormatException(FrameEditGuard.staleMessage);
      }
      if (invalidNumbers.isNotEmpty) {
        throw const FormatException(
          'Doplňte platná čísla ve všech rozpracovaných polích.',
        );
      }
      draft = draft.copyWith(name: name.text.trim());
      layoutDocument(_candidate()).requireExportable();
      Navigator.pop(context, draft);
    } catch (e) {
      setState(() => error = frameError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    PreparedFrameLayout? prepared;
    String? previewError;
    try {
      prepared = _prepare();
    } catch (e) {
      previewError = frameError(e);
    }
    final controls = DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [Tab(text: 'Rámeček'), Tab(text: 'Pole'), Tab(text: 'Čáry')],
          ),
          Expanded(
            child: TabBarView(children: [_dimensions(), _fields(), _lines()]),
          ),
        ],
      ),
    );
    final preview = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilterChip(
              label: const Text('Detail razítka'),
              selected: detail,
              onSelected: (v) => setState(() => detail = v),
            ),
            PopupMenuButton<SizeMm>(
              tooltip: 'Papír náhledu',
              onSelected: (v) => setState(() => paper = v),
              itemBuilder:
                  (_) => const [
                    PopupMenuItem(
                      value: SizeMm.a3Landscape,
                      child: Text('A3 na šířku'),
                    ),
                    PopupMenuItem(
                      value: SizeMm.a4Landscape,
                      child: Text('A4 na šířku'),
                    ),
                  ],
              child: Text(
                'Papír náhledu: ${(paper ?? widget.sheet.paperSizeMm).width} × ${(paper ?? widget.sheet.paperSizeMm).height} mm',
              ),
            ),
          ],
        ),
        Expanded(
          child:
              prepared == null
                  ? Center(
                    child: Text(
                      previewError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  )
                  : FrameTemplatePreview(
                    frame: prepared,
                    selectedFieldId: selected,
                    detail: detail,
                    onSelect: (v) => setState(() => _select(v)),
                    onMove: _move,
                  ),
        ),
        if (prepared != null && prepared.overflowFieldIds.isNotEmpty)
          Text(
            'Text se nevejde do ${prepared.overflowFieldIds.length} polí (červený obrys). Zvětšete pole nebo upravte písmo.',
            key: const ValueKey('frame-overflow'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const Text(
          'Náhled rámečku bez kresby listu. Šedý obrys: prostor pro kresbu. Modrý: vybrané pole. Export obsahuje pouze definici šablony.',
          style: TextStyle(fontSize: 14),
        ),
      ],
    );
    return FrameDialog(
      title: 'Upravit šablonu rámečku',
      width: 1180,
      onSave: _save,
      error: error,
      saveLabel: 'Použít v návrhu',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Sdílená šablona • používá ji ${widget.sharedUses} listů. Změny se do projektu zapíší až uložením nastavení.',
          ),
          const SizedBox(height: 8),
          Expanded(
            child: LayoutBuilder(
              builder:
                  (_, box) =>
                      box.maxWidth >= 760
                          ? Row(
                            children: [
                              SizedBox(width: 340, child: controls),
                              const VerticalDivider(width: 24),
                              Expanded(child: preview),
                            ],
                          )
                          : Column(
                            children: [
                              SizedBox(
                                height: math.min(200, box.maxHeight * .4),
                                child: preview,
                              ),
                              const Divider(),
                              Expanded(child: controls),
                            ],
                          ),
            ),
          ),
        ],
      ),
    );
  }
}

const _bindingLabels = <String, String>{
  'project.name': 'Název projektu',
  'project.description': 'Popis projektu',
  'sheet.name': 'Název listu',
  'sheet.number': 'Číslo listu',
  'sheet.designation': 'Úplné označení listu',
  'sheet.documentCode': 'Kód dokumentu listu',
  'sheet.type': 'Typ listu',
  'page.number': 'Označení fyzické strany',
  'page.index': 'Pořadí strany v dokumentu',
  'page.count': 'Počet stran dokumentu',
  'page.inSheet': 'Pořadí strany v listu',
  'page.sheetCount': 'Počet stran listu',
  'view.scale': 'Měřítko montážního pohledu',
};

class _FrameNumberInput extends StatefulWidget {
  const _FrameNumberInput({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onValidity,
    required this.onText,
    this.rawValue,
    this.integer = false,
  });
  final String label;
  final double value;
  final bool integer;
  final ValueChanged<double> onChanged;
  final ValueChanged<bool> onValidity;
  final ValueChanged<String> onText;
  final String? rawValue;
  @override
  State<_FrameNumberInput> createState() => _FrameNumberInputState();
}

class _FrameNumberInputState extends State<_FrameNumberInput> {
  late final controller = TextEditingController(
    text: widget.rawValue ?? _format(widget.value),
  );
  late bool valid = _parse(controller.text) != null;
  double? _parse(String source) {
    final value = double.tryParse(source.replaceAll(',', '.'));
    return value != null &&
            value.isFinite &&
            (!widget.integer || value == value.roundToDouble())
        ? value
        : null;
  }

  String _format(double v) =>
      (v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(3))
          .replaceAll('.', ',');
  @override
  void didUpdateWidget(covariant _FrameNumberInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.rawValue == null && oldWidget.rawValue != null) ||
        (widget.value != oldWidget.value &&
            double.tryParse(controller.text.replaceAll(',', '.')) !=
                widget.value)) {
      controller.text = _format(widget.value);
      valid = true;
      widget.onValidity(true);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    decoration: InputDecoration(
      labelText: widget.label,
      errorText:
          valid
              ? null
              : widget.integer
              ? 'Celé číslo'
              : 'Platné číslo',
    ),
    keyboardType: const TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    ),
    onChanged: (source) {
      final value = double.tryParse(source.replaceAll(',', '.'));
      final ok =
          value != null &&
          value.isFinite &&
          (!widget.integer || value == value.roundToDouble());
      setState(() => valid = ok);
      widget.onText(source);
      widget.onValidity(ok);
      if (ok) widget.onChanged(value);
    },
  );
}
