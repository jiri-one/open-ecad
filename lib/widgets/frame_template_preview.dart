// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';

import '../services/frame_layout.dart';

class FrameTemplatePreview extends StatefulWidget {
  const FrameTemplatePreview({
    super.key,
    required this.frame,
    this.selectedFieldId,
    this.onSelect,
    this.onMove,
    this.detail = false,
  });

  final PreparedFrameLayout frame;
  final String? selectedFieldId;
  final ValueChanged<String?>? onSelect;
  final void Function(String id, Vec2 deltaMm)? onMove;
  final bool detail;

  @override
  State<FrameTemplatePreview> createState() => _FrameTemplatePreviewState();
}

class _FrameTemplatePreviewState extends State<FrameTemplatePreview> {
  String? dragging;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final geometry = widget.frame.source.geometry;
      final bounds =
          widget.detail && geometry.titleBlockRectMm != null
              ? _rect(geometry.titleBlockRectMm!).inflate(4)
              : _rect(geometry.paperRectMm);
      final scale = math.max(
        .001,
        math.min(
          (box.maxWidth - 16) / bounds.width,
          (box.maxHeight - 16) / bounds.height,
        ),
      );
      final offset =
          Offset(
            (box.maxWidth - bounds.width * scale) / 2,
            (box.maxHeight - bounds.height * scale) / 2,
          ) -
          bounds.topLeft * scale;
      String? hit(Offset position) {
        final p = (position - offset) / scale;
        for (final field in geometry.titleFieldSlots.reversed) {
          if (_rect(field.rectMm).contains(p)) return field.id;
        }
        return null;
      }

      return GestureDetector(
        key: const ValueKey('frame-preview-canvas'),
        behavior: HitTestBehavior.opaque,
        onTapUp:
            widget.onSelect == null
                ? null
                : (event) => widget.onSelect!(hit(event.localPosition)),
        onPanDown:
            widget.onMove == null
                ? null
                : (event) {
                  dragging = hit(event.localPosition);
                  widget.onSelect?.call(dragging);
                },
        onPanUpdate:
            widget.onMove == null
                ? null
                : (event) {
                  if (dragging case final id?) {
                    widget.onMove!(
                      id,
                      Vec2(event.delta.dx / scale, event.delta.dy / scale),
                    );
                  }
                },
        onPanEnd: (_) => dragging = null,
        onPanCancel: () => dragging = null,
        child: ClipRect(
          child: CustomPaint(
            painter: _FramePreviewPainter(
              widget.frame,
              offset,
              scale,
              widget.selectedFieldId,
              widget.onSelect != null,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      );
    },
  );
}

Rect _rect(RectMm r) => Rect.fromLTWH(r.x, r.y, r.width, r.height);

class _FramePreviewPainter extends CustomPainter {
  _FramePreviewPainter(
    this.frame,
    this.offset,
    this.scale,
    this.selected,
    this.editable,
  );
  final PreparedFrameLayout frame;
  final Offset offset;
  final double scale;
  final String? selected;
  final bool editable;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);
    final geometry = frame.source.geometry;
    canvas.drawRect(_rect(geometry.paperRectMm), Paint()..color = Colors.white);
    canvas.drawRect(
      _rect(geometry.contentRectMm),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / scale
        ..color = const Color(0xff94a3b8),
    );
    paintFrameLayout(canvas, frame);
    for (final field in geometry.titleFieldSlots) {
      final overflow = frame.overflowFieldIds.contains(field.id);
      if (editable || overflow) {
        canvas.drawRect(
          _rect(field.rectMm),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = (field.id == selected || overflow ? 2 : 1) / scale
            ..color =
                overflow
                    ? Colors.red
                    : field.id == selected
                    ? Colors.blue
                    : const Color(0x665c6b80),
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FramePreviewPainter oldDelegate) => true;
}
