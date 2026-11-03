// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../services/wire_hover_info.dart';
import 'canvas_hover_overlay.dart';

class WireHoverOverlay extends StatelessWidget {
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
  Widget build(BuildContext context) => CanvasHoverOverlay(
    info: info,
    localPosition: localPosition,
    contextIdentity: contextIdentity,
    active: active,
    suppressed: suppressed,
    delay: delay,
    maxWidth: maxWidth,
    avoidRect: avoidRect,
    child: child,
  );
}
