// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';

import '../app/controller.dart';

String graphicKindLabel(DrawingKind kind) => switch (kind) {
  DrawingKind.path => 'Vektorová grafika',
  DrawingKind.text => 'Text',
  DrawingKind.image => 'Obrázek',
};

class GraphicInspector extends StatefulWidget {
  const GraphicInspector({
    super.key,
    required this.graphic,
    required this.controller,
  });
  final DrawingElement graphic;
  final EditorController controller;

  @override
  State<GraphicInspector> createState() => _GraphicInspectorState();
}

class _GraphicInspectorState extends State<GraphicInspector> {
  late final fields = <String, TextEditingController>{
    'X': TextEditingController(text: '${widget.graphic.position.x}'),
    'Y': TextEditingController(text: '${widget.graphic.position.y}'),
    'Šířka': TextEditingController(text: '${widget.graphic.width}'),
    'Výška': TextEditingController(text: '${widget.graphic.height}'),
    'Otočení (°)': TextEditingController(text: '${widget.graphic.rotation}'),
    'Tloušťka čáry': TextEditingController(
      text: '${widget.graphic.strokeWidth}',
    ),
    'Barva čáry': TextEditingController(text: widget.graphic.stroke ?? ''),
    'Barva výplně': TextEditingController(text: widget.graphic.fill ?? ''),
    'Text': TextEditingController(text: widget.graphic.text),
  };
  late bool bold = widget.graphic.bold;
  String? error;

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  void save() {
    try {
      double number(String key) {
        final value = double.tryParse(fields[key]!.text.replaceAll(',', '.'));
        if (value == null || !value.isFinite) {
          throw const FormatException('Zadejte platná čísla.');
        }
        return value;
      }

      String? color(String key) {
        final value = fields[key]!.text.trim();
        if (value.isEmpty) return null;
        if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
          throw const FormatException(
            'Barvu zadejte jako #RRGGBB, nebo pole vymažte.',
          );
        }
        return value;
      }

      final old = widget.graphic;
      final width = number('Šířka');
      final height = number('Výška');
      final sx = old.width == 0 ? 1.0 : width / old.width;
      final sy = old.height == 0 ? 1.0 : height / old.height;
      final changed = old.copyWith(
        position: Vec2(number('X'), number('Y')),
        width: width,
        height: height,
        rotation: number('Otočení (°)'),
        path:
            old.path
                .map(
                  (segment) => PathSegment(
                    verb: segment.verb,
                    points:
                        segment.points
                            .map((p) => Vec2(p.x * sx, p.y * sy))
                            .toList(),
                  ),
                )
                .toList(),
        strokeWidth: number('Tloušťka čáry'),
        stroke: color('Barva čáry'),
        fill: color('Barva výplně'),
        text: fields['Text']!.text,
        bold: bold,
      );
      requireValidDrawingElement(changed);
      if (!widget.controller.updateGraphic(changed)) {
        setState(() => error = widget.controller.status);
      }
    } on FormatException catch (e) {
      setState(() => error = e.message);
    } on EcadException catch (e) {
      setState(() => error = e.message);
    }
  }

  Widget field(String label, {int lines = 1, String? hint}) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: fields[label],
      enabled:
          !(widget.graphic.kind == DrawingKind.path &&
              ((label == 'Šířka' && widget.graphic.width == 0) ||
                  (label == 'Výška' && widget.graphic.height == 0))),
      minLines: lines,
      maxLines: lines,
      cursorOpacityAnimates: false,
      style: const TextStyle(fontSize: 12),
      decoration: InputDecoration(labelText: label, hintText: hint),
      onSubmitted: lines == 1 ? (_) => save() : null,
    ),
  );

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      Text(
        graphicKindLabel(widget.graphic.kind),
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Text(
        'Grafický objekt bez elektrických vývodů.',
        style: TextStyle(fontSize: 11),
      ),
      const SizedBox(height: 24),
      if (widget.graphic.kind == DrawingKind.text) ...[
        field('Text', lines: 4),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Tučné písmo'),
          value: bold,
          onChanged: (value) => setState(() => bold = value ?? false),
        ),
      ],
      Row(
        children: [
          Expanded(child: field('X')),
          const SizedBox(width: 12),
          Expanded(child: field('Y')),
        ],
      ),
      Row(
        children: [
          Expanded(child: field('Šířka')),
          const SizedBox(width: 12),
          Expanded(child: field('Výška')),
        ],
      ),
      field('Otočení (°)'),
      if (widget.graphic.kind == DrawingKind.path) ...[
        field('Tloušťka čáry'),
        field('Barva čáry', hint: '#000000'),
      ],
      if (widget.graphic.kind != DrawingKind.image)
        field('Barva výplně', hint: '#000000'),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(error!, style: const TextStyle(fontSize: 12)),
        ),
      FilledButton(onPressed: save, child: const Text('Použít vlastnosti')),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: widget.controller.deleteSelection,
        icon: const Icon(Icons.delete_outline),
        label: const Text('Odstranit grafiku'),
      ),
    ],
  );
}
