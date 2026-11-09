// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/theme.dart';

class WorkspacePanels extends StatefulWidget {
  const WorkspacePanels({
    super.key,
    required this.project,
    required this.editor,
    required this.inspector,
    required this.showProject,
    required this.showInspector,
    this.onResizeActiveChanged,
  });

  static const projectWidthKey = 'open_ecad.project_panel_width';
  static const inspectorWidthKey = 'open_ecad.inspector_panel_width';
  final Widget project, editor, inspector;
  final bool showProject, showInspector;
  final ValueChanged<bool>? onResizeActiveChanged;

  @override
  State<WorkspacePanels> createState() => _WorkspacePanelsState();
}

enum _Panel { project, inspector }

class _WorkspacePanelsState extends State<WorkspacePanels> {
  static const _projectMinimum = 220.0, _inspectorMinimum = 260.0;
  static const _editorMinimum = 320.0, _handleWidth = 8.0;
  double? _projectWidth, _inspectorWidth;
  double? _displayProjectWidth, _displayInspectorWidth;
  ({double width, bool project, bool inspector})? _displayViewport;
  _Panel? _resizing;
  int? _pointer;
  bool _edited = false;
  Future<void> _pendingWrite = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!mounted || _edited) return;
      double? width(String key, double minimum) {
        final value = preferences.get(key);
        return value is num && value.isFinite && value >= minimum
            ? value.toDouble()
            : null;
      }

      setState(() {
        _projectWidth = width(WorkspacePanels.projectWidthKey, _projectMinimum);
        _inspectorWidth = width(
          WorkspacePanels.inspectorWidthKey,
          _inspectorMinimum,
        );
      });
    } catch (_) {}
  }

  void _save() {
    final project = _projectWidth, inspector = _inspectorWidth;
    _pendingWrite = _pendingWrite
        .then((_) async {
          final preferences = await SharedPreferences.getInstance();
          for (final entry
              in {
                WorkspacePanels.projectWidthKey: project,
                WorkspacePanels.inspectorWidthKey: inspector,
              }.entries) {
            if (entry.value == null) {
              await preferences.remove(entry.key);
            } else {
              await preferences.setDouble(entry.key, entry.value!);
            }
          }
        })
        .catchError((Object _) {});
  }

  void _finishResize() {
    if (!mounted || _resizing == null) return;
    setState(() {
      _resizing = null;
      _pointer = null;
    });
    widget.onResizeActiveChanged?.call(false);
    _save();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final compact = bounds.maxWidth < 1120;
      final projectVisible = widget.showProject && bounds.maxWidth >= 950;
      final inspectorVisible = widget.showInspector && bounds.maxWidth >= 680;
      final viewport = (
        width: bounds.maxWidth,
        project: projectVisible,
        inspector: inspectorVisible,
      );
      final retainDisplayWidths = _displayViewport == viewport;
      final projectMinimum = projectVisible ? _projectMinimum : 0.0;
      final inspectorMinimum = inspectorVisible ? _inspectorMinimum : 0.0;
      final budget = math.max(
        0.0,
        bounds.maxWidth -
            _editorMinimum -
            (projectVisible ? _handleWidth : 0) -
            (inspectorVisible ? _handleWidth : 0),
      );
      var projectWidth =
          projectVisible
              ? ((retainDisplayWidths ? _displayProjectWidth : null) ??
                      _projectWidth ??
                      (compact ? 240.0 : 285.0))
                  .clamp(projectMinimum, budget - inspectorMinimum)
              : 0.0;
      var inspectorWidth =
          inspectorVisible
              ? ((retainDisplayWidths ? _displayInspectorWidth : null) ??
                      _inspectorWidth ??
                      (compact ? 300.0 : 330.0))
                  .clamp(inspectorMinimum, budget - projectMinimum)
              : 0.0;
      if (projectWidth + inspectorWidth > budget) {
        final surplus =
            projectWidth + inspectorWidth - projectMinimum - inspectorMinimum;
        final available = budget - projectMinimum - inspectorMinimum;
        projectWidth =
            projectMinimum +
            (projectWidth - projectMinimum) * available / surplus;
        inspectorWidth = budget - projectWidth;
      }
      final active = switch (_resizing) {
        _Panel.project => projectVisible,
        _Panel.inspector => inspectorVisible,
        null => false,
      };
      if (_resizing != null && !active) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _finishResize());
      }

      Widget handle(_Panel panel) {
        final isProject = panel == _Panel.project;
        final width = isProject ? projectWidth : inspectorWidth;
        final minimum = isProject ? projectMinimum : inspectorMinimum;
        final maximum = math.max(
          minimum,
          budget - (isProject ? inspectorWidth : projectWidth),
        );
        void resize(double value) {
          setState(() {
            _edited = true;
            _displayViewport = viewport;
            _displayProjectWidth = projectVisible ? projectWidth : null;
            _displayInspectorWidth = inspectorVisible ? inspectorWidth : null;
            if (isProject) {
              _projectWidth = value.clamp(minimum, maximum);
              _displayProjectWidth = _projectWidth;
            } else {
              _inspectorWidth = value.clamp(minimum, maximum);
              _displayInspectorWidth = _inspectorWidth;
            }
          });
          if (_resizing == null) _save();
        }

        return _PanelResizeHandle(
          key: ValueKey('workspace-${panel.name}-resize'),
          label:
              isProject
                  ? 'Šířka panelu projektu'
                  : 'Šířka panelu asistenta a vlastností',
          width: width,
          minimum: minimum,
          maximum: maximum,
          extent: _handleWidth,
          direction: isProject ? 1 : -1,
          active: _resizing == panel,
          onResize: resize,
          onStart: (pointer) {
            if (_resizing != null) return false;
            setState(() {
              _resizing = panel;
              _pointer = pointer;
            });
            widget.onResizeActiveChanged?.call(true);
            return true;
          },
          onEnd: _finishResize,
          onReset: () {
            setState(() {
              _edited = true;
              if (isProject) {
                _projectWidth = null;
                _displayProjectWidth = null;
              } else {
                _inspectorWidth = null;
                _displayInspectorWidth = null;
              }
            });
            _save();
          },
        );
      }

      return Listener(
        onPointerUp: (event) {
          if (event.pointer == _pointer) _finishResize();
        },
        onPointerCancel: (event) {
          if (event.pointer == _pointer) _finishResize();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (projectVisible) ...[
                  SizedBox(
                    key: const ValueKey('workspace-project-panel'),
                    width: projectWidth,
                    child: widget.project,
                  ),
                  handle(_Panel.project),
                ],
                Expanded(
                  key: const ValueKey('workspace-editor-column'),
                  child: SizedBox(
                    key: const ValueKey('workspace-editor-area'),
                    child: widget.editor,
                  ),
                ),
                if (inspectorVisible) ...[
                  handle(_Panel.inspector),
                  SizedBox(
                    key: const ValueKey('workspace-inspector-panel'),
                    width: inspectorWidth,
                    child: widget.inspector,
                  ),
                ],
              ],
            ),
            if (active)
              const Positioned.fill(
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: ColoredBox(color: Colors.transparent),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _PanelResizeHandle extends StatefulWidget {
  const _PanelResizeHandle({
    super.key,
    required this.label,
    required this.width,
    required this.minimum,
    required this.maximum,
    required this.extent,
    required this.direction,
    required this.active,
    required this.onResize,
    required this.onStart,
    required this.onEnd,
    required this.onReset,
  });

  final String label;
  final double width, minimum, maximum, extent, direction;
  final bool active;
  final ValueChanged<double> onResize;
  final bool Function(int) onStart;
  final VoidCallback onEnd, onReset;

  @override
  State<_PanelResizeHandle> createState() => _PanelResizeHandleState();
}

class _PanelResizeHandleState extends State<_PanelResizeHandle> {
  final _focus = FocusNode();
  bool _hover = false, _focused = false;
  int? _pointer;
  double? _dragWidth;

  @override
  void didUpdateWidget(covariant _PanelResizeHandle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dragWidth != null) _dragWidth = widget.width;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _end() {
    if (_dragWidth == null) return;
    _dragWidth = null;
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    final c = EcadColors.of(context);
    final highlighted = widget.active || _hover || _focused;
    void resize(double change) => widget.onResize(
      (widget.width + change).clamp(widget.minimum, widget.maximum),
    );
    return Semantics(
      label: widget.label,
      slider: true,
      value: '${widget.width.round()} px',
      increasedValue:
          '${(widget.width + 16).clamp(widget.minimum, widget.maximum).round()} px',
      decreasedValue:
          '${(widget.width - 16).clamp(widget.minimum, widget.maximum).round()} px',
      onIncrease: widget.width < widget.maximum ? () => resize(16) : null,
      onDecrease: widget.width > widget.minimum ? () => resize(-16) : null,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft):
              () => resize(-16 * widget.direction),
          const SingleActivator(LogicalKeyboardKey.arrowRight):
              () => resize(16 * widget.direction),
          const SingleActivator(LogicalKeyboardKey.home): widget.onReset,
        },
        child: FocusableActionDetector(
          focusNode: _focus,
          mouseCursor: SystemMouseCursors.resizeLeftRight,
          onShowHoverHighlight: (value) => setState(() => _hover = value),
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          child: Tooltip(
            message:
                '${widget.label} · tažením nebo šipkami · dvojklik obnoví výchozí',
            child: Listener(
              onPointerDown: (event) {
                _pointer = event.pointer;
                _focus.requestFocus();
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onDoubleTap: widget.onReset,
                onHorizontalDragStart: (_) {
                  if (_pointer != null && widget.onStart(_pointer!)) {
                    _dragWidth = widget.width;
                  }
                },
                onHorizontalDragUpdate: (details) {
                  if (_dragWidth == null) return;
                  _dragWidth = (_dragWidth! +
                          details.delta.dx * widget.direction)
                      .clamp(widget.minimum, widget.maximum);
                  widget.onResize(_dragWidth!);
                },
                onHorizontalDragEnd: (_) => _end(),
                onHorizontalDragCancel: _end,
                child: SizedBox(
                  width: widget.extent,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      VerticalDivider(
                        width: highlighted ? 2 : 1,
                        thickness: highlighted ? 2 : 1,
                        color: highlighted ? c.accent : c.border,
                      ),
                      Container(
                        width: 3,
                        height: 28,
                        color: highlighted ? c.accent : c.border,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
