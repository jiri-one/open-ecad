// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/drawing_cursor_settings.dart';

class DrawingCursorRegion extends StatefulWidget {
  const DrawingCursorRegion({
    super.key,
    required this.settings,
    required this.backgroundColor,
    required this.child,
    this.active = true,
    this.resetKey,
  });

  final DrawingCursorSettings settings;
  final Color backgroundColor;
  final Widget child;
  final bool active;
  final Object? resetKey;

  // A descendant MouseRegion otherwise overrides the wrapper's cursor.
  static MouseCursor cursorOf(
    BuildContext context, {
    required MouseCursor fallback,
  }) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<_DrawingCursorScope>();
    return scope?.active == true ? SystemMouseCursors.none : fallback;
  }

  @override
  State<DrawingCursorRegion> createState() => _DrawingCursorRegionState();
}

class _DrawingCursorRegionState extends State<DrawingCursorRegion>
    with WidgetsBindingObserver {
  final _position = ValueNotifier<Offset?>(null);
  bool _active = false, _inside = false, _appActive = true, _viewFocused = true;
  int? _device;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant DrawingCursorRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetKey != widget.resetKey) _clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    setState(() {
      _appActive = state == AppLifecycleState.resumed;
      _clear();
    });
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (!mounted || event.viewId != View.of(context).viewId) return;
    setState(() {
      _viewFocused = event.state == ViewFocusState.focused;
      _clear();
    });
  }

  void _clear() {
    _inside = false;
    _device = null;
    _position.value = null;
  }

  void _track(PointerEvent event, {bool hitTested = false}) {
    if (!mounted || !_active || event.kind != PointerDeviceKind.mouse) return;
    if (hitTested) _inside = true;
    if (!_inside) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null ||
        !box.hasSize ||
        !(Offset.zero & box.size).contains(event.localPosition)) {
      _clear();
      return;
    }
    _device = event.device;
    _position.value = event.localPosition;
  }

  void _exit(PointerEvent event) {
    if (mounted && event.device == _device) _clear();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _active =
        widget.active &&
        widget.settings.enabled &&
        _appActive &&
        _viewFocused &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.isCurrentOf(context) != false;
    if (!_active) _clear();
    return _DrawingCursorScope(
      active: _active,
      child: MouseRegion(
        cursor: _active ? SystemMouseCursors.none : MouseCursor.defer,
        onEnter: (event) => _track(event, hitTested: true),
        onHover: (event) => _track(event, hitTested: true),
        onExit: _exit,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) => _track(event, hitTested: true),
          onPointerMove: _track,
          onPointerUp: _track,
          onPointerCancel: _exit,
          child: Stack(
            children: [
              widget.child,
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      key: const ValueKey('drawing-cursor-overlay'),
                      painter: _DrawingCursorPainter(
                        position: _position,
                        settings: widget.settings,
                        background: widget.backgroundColor,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DrawingCursorScope extends InheritedWidget {
  const _DrawingCursorScope({required this.active, required super.child});
  final bool active;

  @override
  bool updateShouldNotify(_DrawingCursorScope oldWidget) =>
      active != oldWidget.active;
}

class _DrawingCursorPainter extends CustomPainter {
  _DrawingCursorPainter({
    required this.position,
    required this.settings,
    required this.background,
  }) : super(repaint: position);

  final ValueNotifier<Offset?> position;
  final DrawingCursorSettings settings;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final point = position.value;
    if (point == null) return;
    final color = switch (settings.color) {
      DrawingCursorColor.automatic =>
        background.computeLuminance() > 0.179 ? Colors.black : Colors.white,
      DrawingCursorColor.black => Colors.black,
      DrawingCursorColor.white => Colors.white,
      DrawingCursorColor.red => const Color(0xFFD32F2F),
      DrawingCursorColor.cyan => const Color(0xFF00B8D4),
    };
    final paint =
        Paint()
          ..color = color
          ..strokeWidth = settings.strokeWidth
          ..strokeCap = StrokeCap.butt;
    final horizontal = Offset(settings.armLength, 0);
    final vertical = Offset(0, settings.armLength);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawLine(point - horizontal, point + horizontal, paint);
    canvas.drawLine(point - vertical, point + vertical, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DrawingCursorPainter oldDelegate) =>
      position != oldDelegate.position ||
      settings != oldDelegate.settings ||
      background != oldDelegate.background;
}
