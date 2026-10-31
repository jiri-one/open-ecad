// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/wire_hover_info.dart';

class WireHoverOverlay extends StatefulWidget {
  const WireHoverOverlay({
    super.key,
    required this.child,
    required this.info,
    required this.localPosition,
    required this.contextIdentity,
    this.active = true,
    this.suppressed = false,
    this.delay = const Duration(milliseconds: 350),
    this.maxWidth = 320,
    this.avoidRect,
  }) : assert(delay >= Duration.zero),
       assert(maxWidth > 0 && maxWidth < double.infinity);

  final Widget child;
  final WireHoverInfo? info;
  final Offset? localPosition;
  final Object contextIdentity;
  final bool active;
  final bool suppressed;
  final Duration delay;
  final double maxWidth;
  final Rect? avoidRect;

  @override
  State<WireHoverOverlay> createState() => _WireHoverOverlayState();
}

class _WireHoverOverlayState extends State<WireHoverOverlay> {
  Timer? _timer;
  bool _visible = false;

  bool _eligible(WireHoverOverlay value) =>
      value.active &&
      !value.suppressed &&
      value.info != null &&
      value.localPosition != null &&
      value.localPosition!.dx.isFinite &&
      value.localPosition!.dy.isFinite &&
      value.localPosition!.dx >= 0 &&
      value.localPosition!.dy >= 0;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void didUpdateWidget(covariant WireHoverOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_eligible(widget) ||
        !_eligible(oldWidget) ||
        !identical(widget.contextIdentity, oldWidget.contextIdentity) ||
        !identical(widget.info?.project, oldWidget.info?.project) ||
        widget.info?.sheetId != oldWidget.info?.sheetId ||
        widget.info?.wireId != oldWidget.info?.wireId ||
        widget.info?.tooltip != oldWidget.info?.tooltip ||
        widget.delay != oldWidget.delay) {
      _restart();
    }
  }

  void _restart() {
    _timer?.cancel();
    _timer = null;
    _visible = false;
    if (!_eligible(widget)) return;
    _timer = Timer(widget.delay, () {
      _timer = null;
      if (mounted && _eligible(widget)) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      widget.child,
      if (_visible && _eligible(widget))
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                final position = widget.localPosition!;
                if (!size.isFinite ||
                    size.width < 80 ||
                    size.height < 48 ||
                    !(Offset.zero & size).contains(position)) {
                  return const SizedBox.shrink();
                }
                return CustomSingleChildLayout(
                  delegate: _BubbleLayout(
                    position: position,
                    maxWidth: widget.maxWidth,
                    avoidRect: widget.avoidRect,
                  ),
                  child: _Bubble(info: widget.info!),
                );
              },
            ),
          ),
        ),
    ],
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.info});

  final WireHoverInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      label: info.semanticsLabel,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.inverseSurface,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Text.rich(
              TextSpan(
                text: info.label,
                style: const TextStyle(fontWeight: FontWeight.w600),
                children: [
                  if (info.detail.isNotEmpty)
                    TextSpan(
                      text: '\n${info.detail}',
                      style: const TextStyle(fontWeight: FontWeight.normal),
                    ),
                ],
              ),
              style: (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
                color: colors.onInverseSurface,
                fontSize: 12,
                height: 1.3,
              ),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }
}

class _BubbleLayout extends SingleChildLayoutDelegate {
  _BubbleLayout({
    required this.position,
    required this.maxWidth,
    required this.avoidRect,
  });

  final Offset position;
  final double maxWidth;
  final Rect? avoidRect;
  static const _margin = 8.0;
  static const _gap = 18.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(
          math.min(maxWidth, math.max(0, constraints.maxWidth - 2 * _margin)),
          math.min(180, math.max(0, constraints.maxHeight - 2 * _margin)),
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final candidates = [
      position + const Offset(_gap, _gap),
      position + Offset(_gap, -_gap - childSize.height),
      position + Offset(-_gap - childSize.width, _gap),
      position + Offset(-_gap - childSize.width, -_gap - childSize.height),
    ].map(
      (candidate) => Offset(
        candidate.dx.clamp(_margin, size.width - childSize.width - _margin),
        candidate.dy.clamp(_margin, size.height - childSize.height - _margin),
      ),
    );
    final pointerArea = Rect.fromCircle(center: position, radius: 10);
    var best = candidates.first;
    var bestOverlap = double.infinity;
    for (final candidate in candidates) {
      final bubble = candidate & childSize;
      final overlap =
          _overlap(bubble, pointerArea) +
          (avoidRect == null ? 0 : _overlap(bubble, avoidRect!.inflate(4)));
      if (overlap < bestOverlap) {
        best = candidate;
        bestOverlap = overlap;
      }
      if (overlap == 0) break;
    }
    return best;
  }

  static double _overlap(Rect a, Rect b) {
    final intersection = a.intersect(b);
    return intersection.isEmpty ? 0 : intersection.width * intersection.height;
  }

  @override
  bool shouldRelayout(_BubbleLayout oldDelegate) =>
      oldDelegate.position != position ||
      oldDelegate.maxWidth != maxWidth ||
      oldDelegate.avoidRect != avoidRect;
}
