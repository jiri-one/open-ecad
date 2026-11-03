import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'drawing_graphics.dart';
import 'drawing_cursor.dart';
import 'canvas_hover_overlay.dart';
import 'schematic_canvas.dart' show CanvasMode;
import '../services/device_hover_info.dart';
import '../services/drawing_cursor_settings.dart';
import '../services/mounting_annotations.dart';
import '../app/controller.dart';
import '../widgets/inventory.dart';
import '../widgets/sheet_settings.dart';
import '../widgets/occurrence_dialog.dart';
import '../widgets/diagnostic_text.dart';

class MountingCanvas extends StatefulWidget {
  const MountingCanvas({
    super.key,
    required this.app,
    this.cursorSettings = DrawingCursorSettings.defaults,
  });
  final DrawingCursorSettings cursorSettings;
  final EditorController app;
  @override
  State<MountingCanvas> createState() => _MountingCanvasState();
}

class _MountingCanvasState extends State<MountingCanvas> {
  MountingPlacement? moving;
  Vec2? start, preview;
  final _activePointers = <int>{};
  final transformation = TransformationController();
  final images = DrawingImageCache();
  EcadProject? diagnosticSnapshot;
  List<Diagnostic> diagnostics = [];
  Offset? doubleTapPosition;
  final _surfaceKey = GlobalKey();
  DeviceHoverInfo? _hoverInfo;
  Offset? _hoverLocal;
  Object? _hoverContext;
  Size? _hoverViewport;
  ProjectResolver? _resolver;

  bool get _hoverAllowed =>
      widget.app.mode == CanvasMode.select &&
      widget.app.pastePreview == null &&
      _activePointers.isEmpty &&
      moving == null;

  @override
  void initState() {
    super.initState();
    transformation.addListener(_zoomChanged);
    _bindNavigation();
    FocusManager.instance.addListener(_dismissHover);
    images.addListener(_imageChanged);
    images.update(widget.app.sheet.graphics);
  }

  void _imageChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant MountingCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.app, widget.app)) {
      oldWidget.app.viewport.unbindNavigation(this);
      _bindNavigation();
      _activePointers.clear();
      moving = null;
      preview = null;
      _clearHover();
    }
    images.update(widget.app.sheet.graphics);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_dismissHover);
    widget.app.viewport.unbindNavigation(this);
    transformation.removeListener(_zoomChanged);
    images.removeListener(_imageChanged);
    images.dispose();
    transformation.dispose();
    super.dispose();
  }

  void _bindNavigation() {
    widget.app.viewport.bindNavigation(
      this,
      hasActiveGesture: () => _activePointers.isNotEmpty || moving != null,
      fit: () => transformation.value = Matrix4.identity(),
      zoom: (factor) {
        final current = transformation.value.getMaxScaleOnAxis();
        final next = (current * factor).clamp(.5, 8.0);
        transformation.value =
            transformation.value.clone()
              ..scaleByDouble(next / current, next / current, 1, 1);
      },
    );
  }

  void _zoomChanged() {
    _dismissHover();
    widget.app.viewport.reportZoom(transformation.value.getMaxScaleOnAxis());
  }

  void _clearHover() {
    _hoverInfo = null;
    _hoverLocal = null;
  }

  void _dismissHover() {
    if (mounted && _hoverLocal != null) setState(_clearHover);
  }

  void _pointerStarted(PointerEvent event) => setState(() {
    _activePointers.add(event.pointer);
    _clearHover();
  });

  void _pointerEnded(PointerEvent event) => setState(() {
    _activePointers.remove(event.pointer);
    _clearHover();
  });

  void _hover(
    PointerHoverEvent event,
    double scale,
    MountingTransform transform,
    MountingLayout layout,
  ) {
    final surface = _surfaceKey.currentContext?.findRenderObject();
    if (!_hoverAllowed || surface is! RenderBox || !surface.hasSize) {
      _dismissHover();
      return;
    }
    // RenderBox includes the InteractiveViewer transform and centered paper offset.
    final local = surface.globalToLocal(event.position);
    final sheetPoint = local / scale;
    final viewport = transform.view.viewport;
    final clip = Rect.fromLTWH(
      viewport.x,
      viewport.y,
      viewport.width,
      viewport.height,
    );
    MountingPlacement? hit;
    if (surface.size.contains(local) && clip.contains(sheetPoint)) {
      final point = transform.toMountingMm(Vec2(sheetPoint.dx, sheetPoint.dy));
      for (final placement in layout.placements.reversed) {
        final component = _resolver!.components[placement.componentId];
        if (component == null) continue;
        final size = _resolver!.dimensionsFor(component);
        final relative = (point - placement.centerMm).rotated(
          -placement.rotation,
        );
        if (size.width != null &&
            size.height != null &&
            relative.x.abs() <= size.width! / 2 &&
            relative.y.abs() <= size.height! / 2) {
          hit = placement;
          break;
        }
      }
    }
    final info =
        hit == null
            ? null
            : resolveMountingHoverInfo(
              resolver: _resolver!,
              sheetId: widget.app.sheet.id,
              placementId: hit.id,
            );
    final position = info == null ? null : event.localPosition;
    if (_hoverInfo?.targetIdentity == info?.targetIdentity &&
        _hoverLocal == position) {
      return;
    }
    setState(() {
      _hoverInfo = info;
      _hoverLocal = position;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app, layout = app.activeLayout;
    if (!identical(diagnosticSnapshot, app.project)) {
      diagnosticSnapshot = app.project;
      _resolver = ProjectResolver(app.project);
      _clearHover();
      diagnostics = validateProject(app.project);
    }
    final hoverContext = (
      app,
      app.documentSessionId,
      app.documentGeneration,
      app.sheet.id,
      app.mode,
      app.showingProposal,
      app.pastePreview,
    );
    if (_hoverContext != hoverContext) {
      _hoverContext = hoverContext;
      _clearHover();
    }
    if (layout == null) {
      return Center(
        child: FilledButton(
          onPressed: () => editMountingView(context, app),
          child: const Text('Nastavit montážní pohled'),
        ),
      );
    }
    final sheet = app.sheet, view = app.sheet.mountingView!;
    final transform = MountingTransform(sheet, view);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 42, 8, 0),
          child: Wrap(
            spacing: 10,
            children: [
              Text('${layout.name} · mm · 1:${decimal(view.scaleDenominator)}'),
              TextButton(
                onPressed: () => editMountingView(context, app),
                child: const Text('Pohled a měřítko'),
              ),
              TextButton(
                onPressed: () => showMountPlacementDialog(context, app),
                child: const Text('Umístit komponentu'),
              ),
              TextButton(
                onPressed: () => transformation.value = Matrix4.identity(),
                child: const Text('Celý list'),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (_hoverViewport != constraints.biggest) {
                _hoverViewport = constraints.biggest;
                _clearHover();
              }
              final scale = (constraints.maxWidth / sheet.width).clamp(
                .05,
                constraints.maxHeight / sheet.height,
              );
              Vec2 mm(Offset local) => transform.toMountingMm(
                Vec2(local.dx / scale, local.dy / scale),
              );
              MountingPlacement? hitTest(Vec2 point) {
                final resolver = _resolver!;
                return layout.placements.reversed.where((p) {
                  final bounds = resolver.mountingBounds(p);
                  return bounds != null &&
                      point.x >= bounds.x &&
                      point.y >= bounds.y &&
                      point.x <= bounds.x + bounds.width &&
                      point.y <= bounds.y + bounds.height;
                }).firstOrNull;
              }

              return CanvasHoverOverlay(
                contextIdentity: app,
                info: _hoverInfo,
                localPosition: _hoverLocal,
                suppressed: !_hoverAllowed,
                maxWidth: 360,
                maxLines: 12,
                child: MouseRegion(
                  onExit: (_) => _dismissHover(),
                  child: DrawingCursorRegion(
                    settings: widget.cursorSettings,
                    backgroundColor: Colors.white,
                    resetKey: (app.documentSessionId, app.sheet.id),
                    child: Listener(
                      onPointerDown: _pointerStarted,
                      onPointerUp: _pointerEnded,
                      onPointerCancel: _pointerEnded,
                      onPointerPanZoomStart: _pointerStarted,
                      onPointerPanZoomEnd: _pointerEnded,
                      onPointerSignal: (_) => _dismissHover(),
                      onPointerHover:
                          (event) => _hover(event, scale, transform, layout),
                      child: InteractiveViewer(
                        transformationController: transformation,
                        minScale: .5,
                        maxScale: 8,
                        panEnabled: moving == null,
                        child: Center(
                          child: GestureDetector(
                            key: _surfaceKey,
                            dragStartBehavior: DragStartBehavior.down,
                            onDoubleTapDown:
                                (e) => doubleTapPosition = e.localPosition,
                            onDoubleTap: () {
                              if (app.showingProposal ||
                                  doubleTapPosition == null) {
                                return;
                              }
                              final hit = hitTest(mm(doubleTapPosition!));
                              if (hit == null) return;
                              app.select({hit.id});
                              editComponent(
                                context,
                                app,
                                component: app.project.componentById(
                                  hit.componentId,
                                ),
                              );
                            },
                            onTapDown: (e) {
                              final hit = hitTest(mm(e.localPosition));
                              app.select(hit == null ? {} : {hit.id});
                              if (hit != null) {
                                app.setPanel(SidePanel.properties);
                              }
                            },
                            onPanStart: (e) {
                              final point = mm(e.localPosition);
                              final hit = hitTest(point);
                              if (hit != null) {
                                setState(() {
                                  moving = hit;
                                  start = point;
                                  preview = hit.centerMm;
                                  app.select({hit.id});
                                });
                              }
                            },
                            onPanUpdate: (e) {
                              if (moving != null) {
                                setState(() {
                                  final pos =
                                      moving!.centerMm +
                                      mm(e.localPosition) -
                                      start!;
                                  preview = Vec2(
                                    pos.x.roundToDouble(),
                                    pos.y.roundToDouble(),
                                  );
                                });
                              } else {
                                transformation.value =
                                    transformation.value.clone()
                                      ..translateByDouble(
                                        e.delta.dx,
                                        e.delta.dy,
                                        0,
                                        1,
                                      );
                              }
                            },
                            onPanEnd: (_) {
                              if (moving != null && preview != null) {
                                app.updatePlacement(
                                  moving!.copyWith(centerMm: preview),
                                );
                              }
                              setState(() {
                                moving = null;
                                preview = null;
                              });
                            },
                            onPanCancel:
                                () => setState(() {
                                  moving = null;
                                  preview = null;
                                }),
                            child: CustomPaint(
                              key: const ValueKey('mounting-surface'),
                              size: Size(
                                sheet.width * scale,
                                sheet.height * scale,
                              ),
                              painter: _MountingPainter(
                                app,
                                scale,
                                moving?.id,
                                preview,
                                images,
                                diagnostics,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MountingPainter extends CustomPainter {
  _MountingPainter(
    this.app,
    this.scale,
    this.movingId,
    this.preview,
    this.images,
    this.diagnostics,
  );
  final DrawingImageCache images;
  final List<Diagnostic> diagnostics;
  final EditorController app;
  final double scale;
  final String? movingId;
  final Vec2? preview;
  void text(Canvas canvas, String text, Offset at, {double size = 11}) {
    final p = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.black,
          fontSize: size,
          fontFamily: 'NotoSans',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(canvas, at);
    p.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final sheet = app.sheet,
        view = sheet.mountingView!,
        layout = app.activeLayout!;
    final t = MountingTransform(sheet, view), u = t.unitsPerMm;
    Offset point(Vec2 mm) {
      final p = t.toSheet(mm);
      return Offset(p.x, p.y);
    }

    canvas.scale(scale);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, sheet.width, sheet.height),
      Paint()..color = Colors.white,
    );
    if (sheet.showFrame) {
      text(
        canvas,
        '${fullPageDesignation(sheet)} · ${sheet.name} · 1:${decimal(view.scaleDenominator)}',
        const Offset(45, 40),
        size: 18,
      );
    }
    for (final graphic in sheet.graphics) {
      final visual = DrawingVisual(graphic);
      visual.paint(
        canvas,
        ink: Colors.black,
        paper: Colors.white,
        highContrast: false,
        displayScale: scale,
        image: images.imageFor(graphic),
      );
      visual.dispose();
    }
    final vp = view.viewport;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(vp.x, vp.y, vp.width, vp.height));
    final origin = point(Vec2.zero);
    canvas.drawRect(
      Rect.fromLTWH(
        origin.dx,
        origin.dy,
        layout.widthMm * u,
        layout.heightMm * u,
      ),
      Paint()
        ..color = Colors.blueGrey
        ..style = PaintingStyle.stroke,
    );
    if (app.showGrid) {
      for (var x = 0.0; x <= layout.widthMm; x += 50) {
        canvas.drawLine(
          point(Vec2(x, 0)),
          point(Vec2(x, layout.heightMm)),
          Paint()..color = const Color(0xffeeeeee),
        );
      }
    }
    final placements = [
      for (final original in layout.placements)
        original.id == movingId
            ? original.copyWith(centerMm: preview)
            : original,
    ];
    for (final p in placements) {
      final dimensions = app.resolver.dimensionsFor(
        app.project.componentById(p.componentId)!,
      );
      final pos = point(p.centerMm);
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(p.rotation * 3.141592653589793 / 180);
      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: dimensions.width! * u,
        height: dimensions.height! * u,
      );
      canvas.drawRect(rect, Paint()..color = const Color(0xfff1f5f9));
      canvas.drawRect(
        rect,
        Paint()
          ..color =
              (app.selectedIds.contains(p.id) ? Colors.blue : Colors.black)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      canvas.restore();
      if (view.showComponentDimensions) {
        text(
          canvas,
          '${decimal(dimensions.width)} × ${decimal(dimensions.height)} mm',
          pos + const Offset(3, 18),
          size: 9,
        );
      }
    }
    paintMountingAnnotations(
      canvas,
      layoutMountingAnnotations(app.resolver, sheet, placements: placements),
    );
    canvas.restore();
    if (view.showSurfaceDimensions) {
      text(
        canvas,
        'Plocha ${decimal(layout.widthMm)} × ${decimal(layout.heightMm)} mm',
        Offset(vp.x, vp.y + vp.height + 16),
      );
    }
    final issues = diagnostics.where((d) => d.layoutId == layout.id).toList();
    if (issues.isNotEmpty) {
      text(
        canvas,
        issues.map((i) => diagnosticText(app.project, i)).take(3).join('\n'),
        Offset(45, sheet.height - 70),
        size: 10,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MountingPainter oldDelegate) => true;
}
