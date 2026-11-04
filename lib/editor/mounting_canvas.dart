import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'drawing_graphics.dart';
import 'layout_diagnostics.dart';
import '../services/document_layout.dart';
import '../services/frame_layout.dart';
import '../app/theme.dart';
import 'drawing_cursor.dart';
import 'middle_button_double_click.dart';
import 'sheet_viewport.dart';
import 'canvas_hover_overlay.dart';
import 'schematic_canvas.dart' show CanvasMode;
import '../services/device_hover_info.dart';
import '../services/drawing_cursor_settings.dart';
import '../services/mounting_annotations.dart';
import '../app/controller.dart';
import '../app/navigation_press.dart';
import '../widgets/inventory.dart';
import '../widgets/sheet_settings.dart';
import '../widgets/occurrence_dialog.dart';
import '../widgets/diagnostic_text.dart';

class MountingCanvas extends StatefulWidget {
  const MountingCanvas({
    super.key,
    required this.app,
    this.showControls = true,
    this.isNavigationCurrent,
    this.cursorSettings = DrawingCursorSettings.defaults,
  });
  final DrawingCursorSettings cursorSettings;
  final EditorController app;
  final bool showControls;
  final bool Function()? isNavigationCurrent;
  @override
  State<MountingCanvas> createState() => _MountingCanvasState();
}

class _MountingCanvasState extends State<MountingCanvas> {
  MountingPlacement? moving;
  Vec2? start, preview;
  final _activePointers = <int>{};
  final _middleDoubleClick = MiddleButtonDoubleClick();
  final transformation = SheetViewportController();
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
  String? _hoveredLink;
  bool _navigationConsumed = false, _navigationMoved = false;
  ({
    String placementId,
    DeviceOccurrence target,
    Offset position,
    int pointer,
    NavigationPress guard,
  })?
  _pressedNavigation;
  double _surfaceScale = 1;
  Offset get _paperOrigin {
    final p = SheetTransform(widget.app.sheet).paperBoundsUnits;
    return Offset(p.x, p.y);
  }

  List<MountingAnnotation> _annotations = const [];
  ValueChanged<bool>? _overrideDrawingCursor;

  bool get _linkCursor =>
      _hoveredLink != null &&
      _hoverAllowed &&
      HardwareKeyboard.instance.isControlPressed;

  bool _modifiersChanged(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight) {
      if (mounted) setState(() {});
      _overrideDrawingCursor?.call(_linkCursor);
    }
    return false;
  }

  ({String placementId, DeviceOccurrence target})? _linkAt(Offset global) {
    final app = widget.app;
    if (app.showingProposal ||
        app.mode != CanvasMode.select ||
        app.pastePreview != null) {
      return null;
    }
    final surface = _surfaceKey.currentContext?.findRenderObject();
    if (surface is! RenderBox || !surface.hasSize) return null;
    final local = surface.globalToLocal(global);
    if (!surface.size.contains(local)) return null;
    final point = local / _surfaceScale + _paperOrigin;
    final view = app.sheet.mountingView;
    final layout = app.activeLayout;
    if (view == null ||
        layout == null ||
        !Rect.fromLTWH(
          view.viewport.x,
          view.viewport.y,
          view.viewport.width,
          view.viewport.height,
        ).contains(point)) {
      return null;
    }
    final transform = MountingTransform(app.sheet, view);
    final mm = transform.toMountingMm(Vec2(point.dx, point.dy));
    for (final placement in layout.placements.reversed) {
      final component = _resolver!.components[placement.componentId];
      if (component == null) continue;
      final dimensions = _resolver!.dimensionsFor(component);
      final relative = (mm - placement.centerMm).rotated(-placement.rotation);
      final body =
          dimensions.width != null &&
          dimensions.height != null &&
          relative.x.abs() <= dimensions.width! / 2 &&
          relative.y.abs() <= dimensions.height! / 2;
      final label = _annotations.any(
        (a) => a.placementId == placement.id && a.bounds.contains(point),
      );
      if (!body && !label) continue;
      final target = _resolver!.schematicOccurrence(component.id);
      return target == null
          ? null
          : (placementId: placement.id, target: target);
    }
    return null;
  }

  bool get _hoverAllowed =>
      widget.app.mode == CanvasMode.select &&
      widget.app.pastePreview == null &&
      !widget.app.showingProposal &&
      _activePointers.isEmpty &&
      moving == null;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_modifiersChanged);
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
      _pressedNavigation?.guard.dispose();
      _pressedNavigation = null;
      oldWidget.app.viewport.unbindNavigation(this);
      _bindNavigation();
      _activePointers.clear();
      _middleDoubleClick.reset();
      moving = null;
      preview = null;
      _clearHover();
    }
    images.update(widget.app.sheet.graphics);
  }

  @override
  void dispose() {
    _pressedNavigation?.guard.dispose();
    HardwareKeyboard.instance.removeHandler(_modifiersChanged);
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
    if (transformation.layingOut) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.app.viewport.reportZoom(
            transformation.value.getMaxScaleOnAxis(),
          );
        }
      });
      return;
    }
    if (transformation.value.isIdentity()) {
      setState(_clearHover);
    } else {
      _dismissHover();
    }
    widget.app.viewport.reportZoom(transformation.value.getMaxScaleOnAxis());
  }

  void _clearHover() {
    _hoverInfo = null;
    _hoverLocal = null;
    _hoveredLink = null;
    _overrideDrawingCursor?.call(false);
  }

  void _dismissHover() {
    if (mounted && (_hoverLocal != null || _hoveredLink != null)) {
      setState(_clearHover);
    }
  }

  void _pointerStarted(PointerEvent event) {
    _pressedNavigation?.guard.dispose();
    _pressedNavigation = null;
    final link =
        event is PointerDownEvent &&
                event.buttons == kPrimaryMouseButton &&
                _hoverAllowed &&
                HardwareKeyboard.instance.isControlPressed
            ? _linkAt(event.position)
            : null;
    _navigationConsumed = link != null;
    _navigationMoved = false;
    if (link != null) {
      FocusScope.of(context).unfocus();
      FocusManager.instance.applyFocusChangesIfNeeded();
    }
    _pressedNavigation =
        link == null
            ? null
            : (
              placementId: link.placementId,
              target: link.target,
              position: event.position,
              pointer: event.pointer,
              guard: NavigationPress(
                widget.app,
                context,
                isActive: widget.isNavigationCurrent,
              ),
            );
    setState(() {
      if (event is PointerDownEvent) _middleDoubleClick.down(event);
      _activePointers.add(event.pointer);
      _clearHover();
    });
  }

  void _pointerEnded(PointerEvent event) {
    if (!mounted) return;
    final pressed = _pressedNavigation;
    final current = pressed?.guard.current ?? false;
    if (pressed?.pointer == event.pointer) {
      pressed?.guard.dispose();
      _pressedNavigation = null;
    }
    setState(() {
      _activePointers.remove(event.pointer);
      _clearHover();
      if (event is PointerUpEvent && _middleDoubleClick.up(event)) {
        transformation.value = Matrix4.identity();
      } else if (event is! PointerUpEvent) {
        _middleDoubleClick.reset();
      }
    });
    final app = widget.app;
    if (pressed != null &&
        current &&
        identical(app, pressed.guard.owner) &&
        pressed.pointer == event.pointer &&
        event is PointerUpEvent &&
        HardwareKeyboard.instance.isControlPressed &&
        !_navigationMoved &&
        (event.position - pressed.position).distance < 3 &&
        _linkAt(event.position)?.placementId == pressed.placementId) {
      app.navigateToDevice(pressed.target.sheet.id, pressed.target.device.id);
    }
  }

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
    final sheetPoint = local / scale + _paperOrigin;
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
    final link = _linkAt(event.position);
    final position = info == null ? null : event.localPosition;
    if (_hoverInfo?.targetIdentity == info?.targetIdentity &&
        _hoverLocal == position &&
        _hoveredLink == link?.placementId) {
      return;
    }
    setState(() {
      _hoverInfo = info;
      _hoverLocal = position;
      _hoveredLink = link?.placementId;
      _overrideDrawingCursor?.call(_linkCursor);
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
    final sheet = app.sheet;
    final documentPage = layoutDocument(app.project).firstPageFor(sheet.id);
    final messages = [
      ...documentPage.diagnostics,
      if (layout != null)
        ...diagnostics
            .where((d) => d.layoutId == layout.id)
            .map((d) => diagnosticText(app.project, d)),
    ];
    final bounds = SheetTransform(sheet).paperBoundsUnits;
    final palette = EcadColors.forAppearance(app.appearance).canvasPalette;
    final view =
        sheet.mountingView ??
        MountingView(
          layoutId: '',
          viewport: frameContentUnits(
            sheet,
            documentPage.frame.source.geometry,
          ),
        );
    final transform = MountingTransform(sheet, view);
    return Column(
      children: [
        if (widget.showControls || layout == null || messages.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(
              spacing: 10,
              children: [
                Text(
                  layout == null
                      ? 'Montážní pohled není nastaven'
                      : '${layout.name} · mm · 1:${decimal(view.scaleDenominator)}',
                ),
                TextButton(
                  onPressed: () => editMountingView(context, app),
                  child: Text(
                    layout == null
                        ? 'Nastavit montážní pohled'
                        : 'Pohled a měřítko',
                  ),
                ),
                TextButton(
                  onPressed:
                      layout == null
                          ? null
                          : () => showMountPlacementDialog(context, app),
                  child: const Text('Umístit komponentu'),
                ),
                TextButton(
                  onPressed: () => transformation.value = Matrix4.identity(),
                  child: const Text('Celý list'),
                ),
                LayoutDiagnostics(messages),
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
              final scale = transformation.layout(
                constraints.biggest,
                Size(bounds.width, bounds.height),
              );
              _surfaceScale = scale;
              _annotations =
                  layout == null
                      ? const []
                      : layoutMountingAnnotations(_resolver!, sheet);
              Vec2 mm(Offset local) => transform.toMountingMm(
                Vec2(local.dx / scale + bounds.x, local.dy / scale + bounds.y),
              );
              MountingPlacement? hitTest(Vec2 point) {
                final resolver = _resolver!;
                return (layout?.placements ?? <MountingPlacement>[]).reversed
                    .where((p) {
                      final bounds = resolver.mountingBounds(p);
                      return bounds != null &&
                          point.x >= bounds.x &&
                          point.y >= bounds.y &&
                          point.x <= bounds.x + bounds.width &&
                          point.y <= bounds.y + bounds.height;
                    })
                    .firstOrNull;
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
                    backgroundColor: palette.paper,
                    resetKey: (app.documentSessionId, app.sheet.id),
                    child: Builder(
                      builder: (context) {
                        _overrideDrawingCursor =
                            DrawingCursorRegion.systemCursorOverrideOf(context);
                        return MouseRegion(
                          cursor:
                              _linkCursor
                                  ? SystemMouseCursors.click
                                  : DrawingCursorRegion.cursorOf(
                                    context,
                                    fallback: SystemMouseCursors.basic,
                                  ),
                          child: Listener(
                            onPointerDown: _pointerStarted,
                            onPointerMove: (event) {
                              _middleDoubleClick.move(event);
                              if (_pressedNavigation != null &&
                                  (event.position -
                                              _pressedNavigation!.position)
                                          .distance >=
                                      3) {
                                _navigationMoved = true;
                              }
                            },
                            onPointerUp: _pointerEnded,
                            onPointerCancel: _pointerEnded,
                            onPointerPanZoomStart: _pointerStarted,
                            onPointerPanZoomEnd: _pointerEnded,
                            onPointerSignal: (_) => _dismissHover(),
                            onPointerHover: (event) {
                              if (layout != null) {
                                _hover(event, scale, transform, layout);
                              }
                            },
                            child: InteractiveViewer(
                              transformationController: transformation,
                              minScale: .5,
                              maxScale: 8,
                              boundaryMargin: const EdgeInsets.all(
                                double.infinity,
                              ),
                              panEnabled: moving == null,
                              child: Center(
                                child: OverflowBox(
                                  minWidth: bounds.width * scale,
                                  maxWidth: bounds.width * scale,
                                  minHeight: bounds.height * scale,
                                  maxHeight: bounds.height * scale,
                                  child: GestureDetector(
                                    key: _surfaceKey,
                                    dragStartBehavior: DragStartBehavior.down,
                                    onDoubleTapDown:
                                        (e) =>
                                            doubleTapPosition = e.localPosition,
                                    onDoubleTap: () {
                                      if (!mounted ||
                                          _navigationConsumed ||
                                          app.showingProposal ||
                                          doubleTapPosition == null) {
                                        return;
                                      }
                                      final hit = hitTest(
                                        mm(doubleTapPosition!),
                                      );
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
                                      if (!mounted || _navigationConsumed) {
                                        return;
                                      }
                                      final hit = hitTest(mm(e.localPosition));
                                      app.select(hit == null ? {} : {hit.id});
                                      if (hit != null) {
                                        app.setPanel(SidePanel.properties);
                                      }
                                    },
                                    onPanStart: (e) {
                                      if (!mounted || _navigationConsumed) {
                                        return;
                                      }
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
                                      if (!mounted || _navigationConsumed) {
                                        return;
                                      }
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
                                      if (!mounted) return;
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
                                    onPanCancel: () {
                                      if (!mounted) return;
                                      setState(() {
                                        moving = null;
                                        preview = null;
                                      });
                                    },
                                    child: CustomPaint(
                                      key: const ValueKey('mounting-surface'),
                                      size: Size(
                                        bounds.width * scale,
                                        bounds.height * scale,
                                      ),
                                      painter: _MountingPainter(
                                        app,
                                        scale,
                                        moving?.id,
                                        preview,
                                        images,
                                        _hoveredLink,
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
    this.activeLink,
  );
  final DrawingImageCache images;
  final String? activeLink;
  final EditorController app;
  final double scale;
  final String? movingId;
  final Vec2? preview;
  void text(Canvas canvas, String text, Offset at, {double size = 11}) {
    final p = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: EcadColors.forAppearance(app.appearance).canvasPalette.ink,
          fontSize: size,
          fontFamily: 'NotoSans',
          height: 1.25,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(canvas, at);
    p.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final sheet = app.sheet;
    final view = sheet.mountingView, layout = app.activeLayout;
    final paper = SheetTransform(sheet),
        palette = EcadColors.forAppearance(app.appearance).canvasPalette;
    final bounds = paper.paperBoundsUnits;
    canvas.scale(scale);
    canvas.translate(-bounds.x, -bounds.y);
    canvas.drawRect(
      Rect.fromLTWH(bounds.x, bounds.y, bounds.width, bounds.height),
      Paint()..color = palette.paper,
    );
    canvas.save();
    canvas.translate(bounds.x, bounds.y);
    canvas.scale(1 / paper.mmPerUnit);
    paintFrameLayout(
      canvas,
      layoutDocument(app.project).firstPageFor(sheet.id).frame,
      color: palette.ink,
    );
    canvas.restore();
    for (final graphic in sheet.graphics) {
      final visual = DrawingVisual(graphic);
      visual.paint(
        canvas,
        ink: palette.ink,
        paper: palette.paper,
        highContrast: palette.highContrast,
        displayScale: scale,
        image: images.imageFor(graphic),
      );
      visual.dispose();
    }
    if (view == null || layout == null) return;
    final t = MountingTransform(sheet, view), u = t.unitsPerMm;
    Offset point(Vec2 mm) {
      final p = t.toSheet(mm);
      return Offset(p.x, p.y);
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
        ..color = palette.muted
        ..style = PaintingStyle.stroke,
    );
    if (app.showGrid) {
      for (var x = 0.0; x <= layout.widthMm; x += 50) {
        canvas.drawLine(
          point(Vec2(x, 0)),
          point(Vec2(x, layout.heightMm)),
          Paint()..color = palette.grid,
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
      canvas.drawRect(rect, Paint()..color = palette.paper);
      canvas.drawRect(
        rect,
        Paint()
          ..color =
              (app.selectedIds.contains(p.id) ? palette.selection : palette.ink)
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
      activePlacementId: activeLink,
      ink: palette.ink,
      paper: palette.paper,
      muted: palette.muted,
    );
    canvas.restore();
    if (view.showSurfaceDimensions) {
      text(
        canvas,
        mountingSurfaceCaption(layout),
        Offset(vp.x, vp.y + vp.height + mountingCaptionGap),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MountingPainter oldDelegate) => true;
}
