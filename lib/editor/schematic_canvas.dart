import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'drawing_graphics.dart';
import 'spatial_index.dart';

enum CanvasMode { select, wire, pan, place, drawLine, drawRectangle, drawText }

typedef SelectionMoveCallback =
    void Function({
      required Map<String, Vec2> devices,
      required Map<String, Vec2> graphics,
    });

/// The canvas uses document colors explicitly, independent of the application UI.
class CanvasPalette {
  const CanvasPalette({
    required this.background,
    required this.paper,
    required this.ink,
    required this.muted,
    required this.grid,
    required this.selection,
    required this.wire,
    required this.sheetBorder,
    this.highContrast = false,
  });

  final Color background;
  final Color paper;
  final Color ink;
  final Color muted;
  final Color grid;
  final Color selection;
  final Color wire;
  final Color sheetBorder;
  final bool highContrast;
}

/// View state remains local to the canvas and is excluded from document history.
class SchematicViewportController extends ChangeNotifier {
  _SchematicCanvasState? _canvas;
  double _zoom = 1;
  int _visiblePrimitiveCount = 0;
  int _totalPrimitiveCount = 0;

  double get zoom => _zoom;
  int get visiblePrimitiveCount => _visiblePrimitiveCount;
  int get totalPrimitiveCount => _totalPrimitiveCount;

  void zoomIn() =>
      _canvas?._zoomAt(_canvas!._viewport.center(Offset.zero), 1.2);
  void zoomOut() =>
      _canvas?._zoomAt(_canvas!._viewport.center(Offset.zero), 1 / 1.2);
  void fit() => _canvas?._fit();
  void reset() => _canvas?._reset();

  void _update(double zoom, int visible, int total) {
    if (_zoom == zoom &&
        _visiblePrimitiveCount == visible &&
        _totalPrimitiveCount == total) {
      return;
    }
    _zoom = zoom;
    _visiblePrimitiveCount = visible;
    _totalPrimitiveCount = total;
    notifyListeners();
  }
}

/// A retained, culled schematic scene. Pointer movement never writes the model;
/// moving a selection produces one document edit when the drag finishes.
class SchematicCanvas extends StatefulWidget {
  const SchematicCanvas({
    super.key,
    required this.sheet,
    required this.selectedIds,
    required this.mode,
    required this.showGrid,
    required this.palette,
    required this.controller,
    required this.onSelectionChanged,
    required this.onMoveDevices,
    required this.onPlaceDevice,
    required this.onConnect,
    required this.onDeleteWire,
    this.onMoveSelection,
    this.onMoveGraphics,
    this.onCreateGraphic,
    this.placingKind,
    this.readOnly = false,
  });

  final Sheet sheet;
  final Set<String> selectedIds;
  final CanvasMode mode;
  final DeviceKind? placingKind;
  final bool readOnly;
  final bool showGrid;
  final CanvasPalette palette;
  final SchematicViewportController controller;
  final ValueChanged<Set<String>> onSelectionChanged;
  final ValueChanged<Map<String, Vec2>> onMoveDevices;
  final SelectionMoveCallback? onMoveSelection;
  final ValueChanged<Map<String, Vec2>>? onMoveGraphics;
  final ValueChanged<DrawingElement>? onCreateGraphic;
  final void Function(DeviceKind kind, Vec2 position) onPlaceDevice;
  final void Function(TerminalRef from, TerminalRef to) onConnect;
  final ValueChanged<String> onDeleteWire;

  static const Size pageSize = Size(1100, 780);
  static const double gridSpacing = 10;

  @override
  State<SchematicCanvas> createState() => _SchematicCanvasState();
}

enum _DragKind { none, pan, move, marquee, draw }

class _SchematicCanvasState extends State<SchematicCanvas> {
  final FocusNode _focus = FocusNode(debugLabel: 'Schematic canvas');
  final DrawingImageCache _images = DrawingImageCache();
  late _Scene _scene;
  Size _viewport = Size.zero;
  Offset _pan = Offset.zero;
  double _zoom = 1;
  bool _initialFit = false;
  bool _spacePressed = false;
  bool _statsScheduled = false;
  int? _activePointer;
  _DragKind _drag = _DragKind.none;
  Offset? _pointerWorld;
  Offset? _downLocal;
  Offset? _downWorld;
  Offset? _panOrigin;
  Rect? _marquee;
  Set<String> _marqueeSelection = {};
  Set<String> _baseSelection = {};
  Map<String, Vec2> _moveOrigin = {};
  Map<String, Vec2> _previewPositions = {};
  TerminalRef? _wireStart;
  TerminalRef? _hoverPort;
  String? _hoverDevice;
  String? _selectedWire;
  double _panZoomStartScale = 1;
  DrawingElement? _drawingPreview;
  int _creationSerial = 0;

  Size get _pageSize => Size(widget.sheet.width, widget.sheet.height);

  CanvasPalette get _canvasPalette {
    final palette = widget.palette;
    if (widget.sheet.showFrame || palette.highContrast) return palette;
    return CanvasPalette(
      background: palette.background,
      paper: Colors.white,
      ink: const Color(0xff17212b),
      muted: const Color(0xff526276),
      grid: const Color(0xffbcc6cd),
      selection: palette.selection,
      wire: const Color(0xff26374d),
      sheetBorder: palette.sheetBorder,
    );
  }

  bool get _drawingTool => const {
    CanvasMode.drawLine,
    CanvasMode.drawRectangle,
    CanvasMode.drawText,
  }.contains(widget.mode);

  @override
  void initState() {
    super.initState();
    _scene = _Scene(widget.sheet);
    _images.addListener(_imagesChanged);
    _images.update(widget.sheet.graphics);
    widget.controller._canvas = this;
  }

  @override
  void didUpdateWidget(covariant SchematicCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.sheet, widget.sheet)) {
      _scene.dispose();
      _scene = _Scene(widget.sheet);
      _images.update(widget.sheet.graphics);
      if (_drag == _DragKind.move &&
          _moveOrigin.keys.any(
            (id) =>
                !_scene.devices.containsKey(id) &&
                !_scene.graphics.containsKey(id),
          )) {
        _cancelGesture();
      }
      if (oldWidget.sheet.id != widget.sheet.id) {
        _cancelGesture();
        _selectedWire = null;
        _hoverDevice = null;
        _hoverPort = null;
      }
      if (oldWidget.sheet.width != widget.sheet.width ||
          oldWidget.sheet.height != widget.sheet.height) {
        _fit(rebuild: false);
      }
      if (_selectedWire != null && !_scene.wires.containsKey(_selectedWire)) {
        _selectedWire = null;
      }
      if (_wireStart != null &&
          !_scene.devices.containsKey(_wireStart!.deviceId)) {
        _wireStart = null;
      }
    }
    if (oldWidget.mode != widget.mode ||
        oldWidget.readOnly != widget.readOnly ||
        oldWidget.placingKind != widget.placingKind) {
      _cancelGesture();
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._canvas = null;
      widget.controller._canvas = this;
    }
    _scheduleStats();
  }

  @override
  void dispose() {
    if (widget.controller._canvas == this) widget.controller._canvas = null;
    _focus.dispose();
    _scene.dispose();
    _images.dispose();
    super.dispose();
  }

  Offset _toWorld(Offset local) => (local - _pan) / _zoom;

  void _imagesChanged() {
    if (mounted) setState(() {});
  }

  Vec2 _drawingPoint(Offset point) =>
      widget.showGrid ? _snap(point) : Vec2(point.dx, point.dy);

  Vec2 _snap(Offset world) => Vec2(
    (world.dx / SchematicCanvas.gridSpacing).round() *
        SchematicCanvas.gridSpacing,
    (world.dy / SchematicCanvas.gridSpacing).round() *
        SchematicCanvas.gridSpacing,
  );

  Rect get _worldViewport => Rect.fromPoints(
    _toWorld(Offset.zero),
    _toWorld(_viewport.bottomRight(Offset.zero)),
  );

  void _scheduleStats() {
    if (_statsScheduled) return;
    _statsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _statsScheduled = false;
      if (!mounted) return;
      final visible = _scene.index.query(_worldViewport.inflate(60)).length;
      widget.controller._update(_zoom, visible, _scene.index.length);
    });
  }

  void _fit({bool rebuild = true}) {
    if (_viewport.isEmpty) return;
    void update() {
      const gutter = 60.0;
      _zoom = math
          .min(
            (_viewport.width - gutter) / _pageSize.width,
            (_viewport.height - gutter) / _pageSize.height,
          )
          .clamp(0.15, 3.5);
      _pan = Offset(
        (_viewport.width - _pageSize.width * _zoom) / 2,
        (_viewport.height - _pageSize.height * _zoom) / 2,
      );
    }

    if (rebuild) {
      setState(update);
    } else {
      update();
    }
    _scheduleStats();
  }

  void _reset() {
    if (_viewport.isEmpty) return;
    setState(() {
      _zoom = 1;
      _pan = Offset(
        (_viewport.width - _pageSize.width) / 2,
        (_viewport.height - _pageSize.height) / 2,
      );
    });
    _scheduleStats();
  }

  void _zoomAt(Offset anchor, double factor) {
    final world = _toWorld(anchor);
    final next = (_zoom * factor).clamp(0.15, 3.5);
    if (next == _zoom) return;
    setState(() {
      _zoom = next;
      _pan = anchor - world * next;
    });
    _scheduleStats();
  }

  void _cancelGesture() {
    _activePointer = null;
    _drag = _DragKind.none;
    _marquee = null;
    _marqueeSelection = {};
    _previewPositions = {};
    _moveOrigin = {};
    _drawingPreview = null;
    _wireStart = null;
    _hoverPort = null;
  }

  TerminalRef? _portAt(Offset point) {
    final radius = 12 / _zoom;
    final candidates = _scene.index.query(
      Rect.fromCircle(center: point, radius: radius + 10),
    );
    TerminalRef? closest;
    var distance = radius;
    for (final key in candidates) {
      if (!key.startsWith('d:')) continue;
      final device = _scene.devices[key.substring(2)]!;
      for (final port in SymbolCatalog.definitionFor(device.kind).ports) {
        final position = _portPosition(device, port.id, _previewPositions);
        final d = (position - point).distance;
        if (d <= distance) {
          distance = d;
          closest = TerminalRef(deviceId: device.id, portId: port.id);
        }
      }
    }
    return closest;
  }

  String? _deviceAt(Offset point) {
    final tolerance = 5 / _zoom;
    final candidates = _scene.index.query(
      Rect.fromCircle(center: point, radius: tolerance),
    );
    String? result;
    var topmost = -1;
    for (final key in candidates) {
      if (!key.startsWith('d:')) continue;
      final id = key.substring(2);
      final order = _scene.deviceOrder[id]!;
      if (order > topmost &&
          _scene.deviceBounds[id]!.inflate(tolerance).contains(point)) {
        result = id;
        topmost = order;
      }
    }
    return result;
  }

  String? _wireAt(Offset point) {
    final tolerance = 7 / _zoom;
    final candidates = _scene.index.query(
      Rect.fromCircle(center: point, radius: tolerance),
    );
    for (final key in candidates) {
      if (!key.startsWith('w:')) continue;
      final id = key.substring(2);
      final points = _scene.wirePoints[id]!;
      for (var i = 1; i < points.length; i++) {
        if (distanceToSegment(point, points[i - 1], points[i]) <= tolerance) {
          return id;
        }
      }
    }
    return null;
  }

  String? _graphicAt(Offset point) {
    final tolerance = 5 / _zoom;
    final candidates = _scene.index.query(
      Rect.fromCircle(center: point, radius: tolerance),
    );
    String? result;
    var topmost = -1;
    for (final key in candidates) {
      if (!key.startsWith('g:')) continue;
      final id = key.substring(2);
      final order = _scene.graphicOrder[id]!;
      if (order > topmost && _scene.graphics[id]!.hitTest(point, tolerance)) {
        topmost = order;
        result = id;
      }
    }
    return result;
  }

  DrawingElement _newDrawing(Offset start, Offset end) {
    final a = _drawingPoint(start);
    final b = _drawingPoint(end);
    final left = math.min(a.x, b.x);
    final top = math.min(a.y, b.y);
    final width = (a.x - b.x).abs();
    final height = (a.y - b.y).abs();
    return DrawingElement(
      id: 'graphic_${DateTime.now().microsecondsSinceEpoch}_${_creationSerial++}',
      kind:
          widget.mode == CanvasMode.drawText
              ? DrawingKind.text
              : DrawingKind.path,
      position: widget.mode == CanvasMode.drawText ? a : Vec2(left, top),
      width: widget.mode == CanvasMode.drawText ? 100 : width,
      height: widget.mode == CanvasMode.drawText ? 18 : height,
      text: widget.mode == CanvasMode.drawText ? 'Text' : '',
      fontSize: 14,
      fill: widget.mode == CanvasMode.drawText ? '#17212B' : null,
      stroke: widget.mode == CanvasMode.drawText ? null : '#17212B',
      strokeWidth: 1,
      path: switch (widget.mode) {
        CanvasMode.drawLine => [
          PathSegment(
            verb: PathVerb.moveTo,
            points: [Vec2(a.x - left, a.y - top)],
          ),
          PathSegment(
            verb: PathVerb.lineTo,
            points: [Vec2(b.x - left, b.y - top)],
          ),
        ],
        CanvasMode.drawRectangle => [
          PathSegment(verb: PathVerb.moveTo, points: [const Vec2(0, 0)]),
          PathSegment(verb: PathVerb.lineTo, points: [Vec2(width, 0)]),
          PathSegment(verb: PathVerb.lineTo, points: [Vec2(width, height)]),
          PathSegment(verb: PathVerb.lineTo, points: [Vec2(0, height)]),
          PathSegment(verb: PathVerb.close),
        ],
        _ => const [],
      },
    );
  }

  void _pointerDown(PointerDownEvent event) {
    if (_activePointer != null) return;
    _focus.requestFocus();
    final world = _toWorld(event.localPosition);
    _pointerWorld = world;
    _downLocal = event.localPosition;
    _downWorld = world;
    _activePointer = event.pointer;

    if (event.buttons & (kMiddleMouseButton | kSecondaryMouseButton) != 0 ||
        widget.mode == CanvasMode.pan ||
        _spacePressed) {
      setState(() {
        _drag = _DragKind.pan;
        _panOrigin = _pan;
      });
      return;
    }

    if (!widget.readOnly &&
        widget.mode == CanvasMode.place &&
        widget.placingKind != null) {
      widget.onPlaceDevice(widget.placingKind!, _snap(world));
      return;
    }

    if (!widget.readOnly && widget.mode == CanvasMode.wire) {
      final port = _portAt(world);
      if (port == null) return;
      setState(() {
        if (_wireStart == null) {
          _wireStart = port;
        } else if (!_samePort(_wireStart, port)) {
          widget.onConnect(_wireStart!, port);
          _wireStart = null;
        }
      });
      return;
    }

    if (!widget.readOnly && _drawingTool) {
      if (widget.mode == CanvasMode.drawText) {
        widget.onCreateGraphic?.call(_newDrawing(world, world));
      } else {
        setState(() {
          _drag = _DragKind.draw;
          _drawingPreview = _newDrawing(world, world);
        });
      }
      return;
    }

    final deviceId =
        _deviceAt(world) ?? (_wireAt(world) == null ? _graphicAt(world) : null);
    if (deviceId != null) {
      _selectedWire = null;
      final additive = HardwareKeyboard.instance.isShiftPressed;
      final selection = {...widget.selectedIds};
      if (additive && selection.contains(deviceId)) {
        selection.remove(deviceId);
        widget.onSelectionChanged(selection);
        return;
      }
      if (!selection.contains(deviceId)) {
        if (!additive) selection.clear();
        selection.add(deviceId);
        widget.onSelectionChanged(selection);
      }
      if (widget.readOnly) return;
      setState(() {
        _drag = _DragKind.move;
        _moveOrigin = {
          for (final id in selection)
            if (_scene.devices.containsKey(id))
              id: _scene.devices[id]!.position
            else if (_scene.graphics.containsKey(id))
              id: _scene.graphics[id]!.element.position,
        };
      });
      return;
    }

    final wire = _wireAt(world);
    if (wire != null) {
      setState(() => _selectedWire = wire);
      widget.onSelectionChanged({});
      return;
    }

    setState(() {
      _selectedWire = null;
      _drag = _DragKind.marquee;
      _baseSelection =
          HardwareKeyboard.instance.isShiftPressed
              ? {...widget.selectedIds}
              : <String>{};
      _marqueeSelection = {..._baseSelection};
    });
    if (_baseSelection.isEmpty) widget.onSelectionChanged({});
  }

  void _pointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer) return;
    final world = _toWorld(event.localPosition);
    setState(() {
      _pointerWorld = world;
      switch (_drag) {
        case _DragKind.pan:
          _pan = _panOrigin! + event.localPosition - _downLocal!;
        case _DragKind.move:
          if ((event.localPosition - _downLocal!).distance < 3 &&
              _previewPositions.isEmpty) {
            return;
          }
          final delta =
              _moveOrigin.keys.any(_scene.graphics.containsKey)
                  ? _drawingPoint(world - _downWorld!)
                  : _snap(world - _downWorld!);
          _previewPositions = {
            for (final entry in _moveOrigin.entries)
              entry.key: Vec2(entry.value.x + delta.x, entry.value.y + delta.y),
          };
        case _DragKind.marquee:
          if ((event.localPosition - _downLocal!).distance < 3) return;
          _marquee = Rect.fromPoints(_downWorld!, world);
          final candidates = _scene.index.query(_marquee!);
          _marqueeSelection = {
            ..._baseSelection,
            for (final key in candidates)
              if (key.startsWith('d:') &&
                  _scene.deviceBounds[key.substring(2)]!.overlaps(_marquee!))
                key.substring(2)
              else if (key.startsWith('g:') &&
                  _scene.graphics[key.substring(2)]!.intersects(_marquee!))
                key.substring(2),
          };
        case _DragKind.draw:
          _drawingPreview = _newDrawing(_downWorld!, world);
        case _DragKind.none:
          break;
      }
    });
    if (_drag == _DragKind.pan) _scheduleStats();
  }

  void _pointerUp(PointerEvent event) {
    if (event.pointer != _activePointer) return;
    if (_drag == _DragKind.move && _previewPositions.isNotEmpty) {
      final changed = <String, Vec2>{};
      for (final entry in _previewPositions.entries) {
        final original = _moveOrigin[entry.key]!;
        if (entry.value.x != original.x || entry.value.y != original.y) {
          changed[entry.key] = entry.value;
        }
      }
      if (changed.isNotEmpty) {
        final devices = <String, Vec2>{
          for (final entry in changed.entries)
            if (_scene.devices.containsKey(entry.key)) entry.key: entry.value,
        };
        final graphics = <String, Vec2>{
          for (final entry in changed.entries)
            if (_scene.graphics.containsKey(entry.key)) entry.key: entry.value,
        };
        if (widget.onMoveSelection != null) {
          widget.onMoveSelection!(devices: devices, graphics: graphics);
        } else {
          if (devices.isNotEmpty) widget.onMoveDevices(devices);
          if (graphics.isNotEmpty) widget.onMoveGraphics?.call(graphics);
        }
      }
    } else if (_drag == _DragKind.marquee) {
      widget.onSelectionChanged({..._marqueeSelection});
    } else if (_drag == _DragKind.draw &&
        _drawingPreview != null &&
        (_drawingPreview!.width + _drawingPreview!.height) * _zoom >= 3) {
      widget.onCreateGraphic?.call(_drawingPreview!);
    }
    setState(() {
      _activePointer = null;
      _drag = _DragKind.none;
      _marquee = null;
      _previewPositions = {};
      _moveOrigin = {};
      _drawingPreview = null;
    });
    _scheduleStats();
  }

  void _pointerHover(PointerHoverEvent event) {
    final world = _toWorld(event.localPosition);
    final device = _deviceAt(world) ?? _graphicAt(world);
    final port =
        !widget.readOnly && widget.mode == CanvasMode.wire
            ? _portAt(world)
            : null;
    final tracksPointer =
        !widget.readOnly &&
        (widget.mode == CanvasMode.wire || widget.mode == CanvasMode.place);
    if ((!tracksPointer || world == _pointerWorld) &&
        device == _hoverDevice &&
        _samePort(port, _hoverPort)) {
      return;
    }
    setState(() {
      _pointerWorld = world;
      _hoverDevice = device;
      _hoverPort = port;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.space) {
      setState(() => _spacePressed = event is! KeyUpEvent);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        _cancelGesture();
        _selectedWire = null;
      });
      // Let the application also return the active tool to selection.
      return KeyEventResult.ignored;
    }
    if (!widget.readOnly &&
        (event.logicalKey == LogicalKeyboardKey.delete ||
            event.logicalKey == LogicalKeyboardKey.backspace) &&
        _selectedWire != null) {
      widget.onDeleteWire(_selectedWire!);
      setState(() => _selectedWire = null);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  MouseCursor get _cursor {
    if (_drag == _DragKind.pan) return SystemMouseCursors.grabbing;
    if (widget.mode == CanvasMode.pan || _spacePressed) {
      return SystemMouseCursors.grab;
    }
    if (!widget.readOnly &&
        (widget.mode == CanvasMode.place ||
            widget.mode == CanvasMode.wire ||
            _drawingTool)) {
      return SystemMouseCursors.precise;
    }
    if (widget.readOnly && _hoverDevice != null) {
      return SystemMouseCursors.click;
    }
    if (_hoverDevice != null || _drag == _DragKind.move) {
      return SystemMouseCursors.move;
    }
    return SystemMouseCursors.basic;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final nextSize = constraints.biggest;
        if (_viewport != nextSize) {
          final previous = _viewport;
          _viewport = nextSize;
          if (!_initialFit) {
            _fit(rebuild: false);
            _initialFit = true;
          } else {
            _pan += Offset(
              (nextSize.width - previous.width) / 2,
              (nextSize.height - previous.height) / 2,
            );
            _scheduleStats();
          }
        }
        final selected =
            _drag == _DragKind.marquee ? _marqueeSelection : widget.selectedIds;
        return Semantics(
          label: '${widget.sheet.type.label}, ${widget.sheet.name}',
          hint:
              widget.readOnly
                  ? 'Náhled pouze ke čtení. Kliknutím vyberte přístroj. '
                      'Kolečkem přibližujte, s mezerníkem posouvejte výkres.'
                  : 'Vyberte a přetáhněte přístroj. Kolečkem přibližujte. '
                      'S mezerníkem posouvejte výkres. Nástroj Vodič propojí '
                      'připojovací body. Escape zruší rozpracovanou akci.',
          child: Focus(
            focusNode: _focus,
            onKeyEvent: _onKey,
            onFocusChange: (focused) {
              if (!focused && _spacePressed) {
                setState(() => _spacePressed = false);
              }
            },
            child: MouseRegion(
              cursor: _cursor,
              onExit:
                  (_) => setState(() {
                    _pointerWorld = null;
                    _hoverDevice = null;
                    _hoverPort = null;
                  }),
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _pointerDown,
                onPointerMove: _pointerMove,
                onPointerUp: _pointerUp,
                onPointerCancel: (_) => setState(_cancelGesture),
                onPointerHover: _pointerHover,
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    GestureBinding.instance.pointerSignalResolver.register(
                      event,
                      (resolved) {
                        final scroll = resolved as PointerScrollEvent;
                        _zoomAt(
                          scroll.localPosition,
                          math.exp(-scroll.scrollDelta.dy * 0.0015),
                        );
                      },
                    );
                  }
                },
                onPointerPanZoomStart: (_) => _panZoomStartScale = _zoom,
                onPointerPanZoomUpdate: (event) {
                  final factor =
                      (_panZoomStartScale * event.scale).clamp(0.15, 3.5) /
                      _zoom;
                  final anchor = event.localPosition;
                  final world = _toWorld(anchor);
                  setState(() {
                    _zoom *= factor;
                    _pan = anchor - world * _zoom + event.panDelta;
                  });
                  _scheduleStats();
                },
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _SchematicPainter(
                      scene: _scene,
                      palette: _canvasPalette,
                      images: _images,
                      drawingPreview: _drawingPreview,
                      pan: _pan,
                      zoom: _zoom,
                      showGrid: widget.showGrid,
                      selectedIds: selected,
                      previewPositions: _previewPositions,
                      marquee: _marquee,
                      wireStart: _wireStart,
                      hoverPort: _hoverPort,
                      pointerWorld: _pointerWorld,
                      placingKind:
                          !widget.readOnly && widget.mode == CanvasMode.place
                              ? widget.placingKind
                              : null,
                      wireMode:
                          !widget.readOnly && widget.mode == CanvasMode.wire,
                      selectedWire: _selectedWire,
                      onSelectDevice: (id) => widget.onSelectionChanged({id}),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

bool _samePort(TerminalRef? a, TerminalRef? b) =>
    a?.deviceId == b?.deviceId && a?.portId == b?.portId;

Offset _offset(Vec2 value) => Offset(value.x, value.y);

Offset _portPosition(
  Device device,
  String portId,
  Map<String, Vec2> positions,
) {
  final actual = SymbolCatalog.worldPortPosition(device, portId);
  final preview = positions[device.id];
  if (preview == null) return _offset(actual);
  return Offset(
    actual.x + preview.x - device.position.x,
    actual.y + preview.y - device.position.y,
  );
}

Rect _deviceRect(Device device) {
  final definition = SymbolCatalog.definitionFor(device.kind);
  final radians = device.rotation * math.pi / 180;
  final width =
      definition.width * radians.cos().abs() +
      definition.height * radians.sin().abs();
  final height =
      definition.width * radians.sin().abs() +
      definition.height * radians.cos().abs();
  return Rect.fromCenter(
    center: _offset(device.position),
    width: width,
    height: height,
  ).inflate(4);
}

class _Scene {
  _Scene(this.sheet) {
    for (final (order, graphic) in sheet.graphics.indexed) {
      final visual = DrawingVisual(graphic);
      graphics[graphic.id] = visual;
      graphicOrder[graphic.id] = order;
      index.insert('g:${graphic.id}', visual.bounds);
    }
    for (final (order, device) in sheet.devices.indexed) {
      devices[device.id] = device;
      deviceOrder[device.id] = order;
      final bounds = _deviceRect(device);
      deviceBounds[device.id] = bounds;
      index.insert('d:${device.id}', bounds.inflate(45));
    }
    for (final wire in sheet.wires) {
      wires[wire.id] = wire;
      final points = route(wire, const {});
      wirePoints[wire.id] = points;
      if (points.isEmpty) continue;
      final bounds = points.fold<Rect>(
        Rect.fromCircle(center: points.first, radius: 1),
        (rect, point) =>
            rect.expandToInclude(Rect.fromCircle(center: point, radius: 1)),
      );
      index.insert('w:${wire.id}', bounds.inflate(8));
    }
  }

  final Sheet sheet;
  final Map<String, Device> devices = {};
  final Map<String, DrawingVisual> graphics = {};
  final Map<String, int> graphicOrder = {};
  final Map<String, int> deviceOrder = {};
  final Map<String, Wire> wires = {};
  final Map<String, Rect> deviceBounds = {};
  final Map<String, List<Offset>> wirePoints = {};
  final SpatialIndex<String> index = SpatialIndex();

  void dispose() {
    for (final visual in graphics.values) {
      visual.dispose();
    }
  }

  /// Applies the same waypoint adjustment as the committed move, so the
  /// preview cannot differ from the document after the drag ends.
  List<Offset> route(Wire wire, Map<String, Vec2> positions) {
    final from = devices[wire.from.deviceId];
    final to = devices[wire.to.deviceId];
    if (from == null || to == null) return [];
    final before = {from.id: from, to.id: to};
    final after = {
      for (final device in [from, to])
        device.id:
            positions.containsKey(device.id)
                ? device.copyWith(position: positions[device.id])
                : device,
    };
    return WireRouter.path(
      WireRouter.follow(wire, before, after),
      after,
    ).map(_offset).toList();
  }

  WireTerminal? terminal(TerminalRef reference, Map<String, Vec2> positions) {
    final device = devices[reference.deviceId];
    if (device == null) return null;
    final preview = positions[device.id];
    return WireRouter.terminal(
      preview == null ? device : device.copyWith(position: preview),
      reference.portId,
    );
  }
}

extension on double {
  double sin() => math.sin(this);
  double cos() => math.cos(this);
}

class _SchematicPainter extends CustomPainter {
  _SchematicPainter({
    required this.scene,
    required this.palette,
    required this.pan,
    required this.zoom,
    required this.showGrid,
    required this.selectedIds,
    required this.previewPositions,
    required this.marquee,
    required this.wireStart,
    required this.hoverPort,
    required this.pointerWorld,
    required this.placingKind,
    required this.wireMode,
    required this.selectedWire,
    required this.onSelectDevice,
    required this.images,
    required this.drawingPreview,
  });

  final _Scene scene;
  final CanvasPalette palette;
  final Offset pan;
  final double zoom;
  final bool showGrid;
  final Set<String> selectedIds;
  final Map<String, Vec2> previewPositions;
  final Rect? marquee;
  final TerminalRef? wireStart;
  final TerminalRef? hoverPort;
  final Offset? pointerWorld;
  final DeviceKind? placingKind;
  final bool wireMode;
  final String? selectedWire;
  final ValueChanged<String> onSelectDevice;
  final DrawingImageCache images;
  final DrawingElement? drawingPreview;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.background);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(pan.dx, pan.dy);
    canvas.scale(zoom);
    final visibleRect = Rect.fromLTWH(
      -pan.dx / zoom,
      -pan.dy / zoom,
      size.width / zoom,
      size.height / zoom,
    );
    _drawPage(canvas, visibleRect);

    final visible = scene.index.query(visibleRect.inflate(50));
    if (previewPositions.isNotEmpty) {
      visible.addAll(
        previewPositions.keys.map(
          (id) => '${scene.graphics.containsKey(id) ? 'g' : 'd'}:$id',
        ),
      );
      for (final wire in scene.wires.values) {
        if (previewPositions.containsKey(wire.from.deviceId) ||
            previewPositions.containsKey(wire.to.deviceId)) {
          visible.add('w:${wire.id}');
        }
      }
    }
    final visibleGraphics =
        visible
            .where((key) => key.startsWith('g:'))
            .map((key) => key.substring(2))
            .toList()
          ..sort(
            (a, b) => scene.graphicOrder[a]!.compareTo(scene.graphicOrder[b]!),
          );
    for (final id in visibleGraphics) {
      final visual = scene.graphics[id]!;
      visual.paint(
        canvas,
        ink: palette.ink,
        paper: palette.paper,
        highContrast: palette.highContrast,
        displayScale: zoom,
        position: previewPositions[id],
        image: images.imageFor(visual.element),
      );
    }
    for (final key in visible) {
      if (!key.startsWith('w:')) continue;
      final id = key.substring(2);
      final wire = scene.wires[id]!;
      final moved =
          previewPositions.containsKey(wire.from.deviceId) ||
          previewPositions.containsKey(wire.to.deviceId);
      final points =
          moved ? scene.route(wire, previewPositions) : scene.wirePoints[id]!;
      _drawWire(canvas, points, id == selectedWire);
    }
    final visibleDevices =
        visible
            .where((key) => key.startsWith('d:'))
            .map((key) => key.substring(2))
            .toList()
          ..sort(
            (a, b) => scene.deviceOrder[a]!.compareTo(scene.deviceOrder[b]!),
          );
    for (final id in visibleDevices) {
      final device = scene.devices[id]!;
      _drawDevice(canvas, device);
    }

    // Selection affordances stay above the document without recoloring the
    // imported content, which would obscure the source line and fill styles.
    for (final id in visibleGraphics.where(selectedIds.contains)) {
      final visual = scene.graphics[id]!;
      final preview = previewPositions[id] ?? visual.element.position;
      final delta = _offset(preview) - _offset(visual.element.position);
      final box = visual.bounds.shift(delta).inflate(3 / zoom);
      canvas.drawRect(
        box,
        Paint()
          ..color = palette.selection
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 / zoom,
      );
      for (final point in [
        box.topLeft,
        box.topRight,
        box.bottomLeft,
        box.bottomRight,
      ]) {
        canvas.drawRect(
          Rect.fromCenter(center: point, width: 4 / zoom, height: 4 / zoom),
          Paint()..color = palette.selection,
        );
      }
    }

    if (drawingPreview != null) {
      final visual = DrawingVisual(drawingPreview!);
      visual.paint(
        canvas,
        ink: palette.selection,
        paper: palette.paper,
        highContrast: true,
        displayScale: zoom,
      );
      visual.dispose();
    }

    if (wireStart != null && pointerWorld != null) {
      final from = scene.terminal(wireStart!, previewPositions);
      if (from != null) {
        final to =
            (hoverPort == null
                ? null
                : scene.terminal(hoverPort!, previewPositions)) ??
            WireTerminal(Vec2(pointerWorld!.dx, pointerWorld!.dy));
        final path = _pathFromPoints(
          WireRouter.route(from, to).map(_offset).toList(),
        );
        _drawDashedPath(
          canvas,
          path,
          Paint()
            ..color = palette.selection
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
          dashLength: 6,
          gapLength: 4,
        );
      }
    }

    if (placingKind != null && pointerWorld != null) {
      final snapped = Offset(
        (pointerWorld!.dx / SchematicCanvas.gridSpacing).round() *
            SchematicCanvas.gridSpacing,
        (pointerWorld!.dy / SchematicCanvas.gridSpacing).round() *
            SchematicCanvas.gridSpacing,
      );
      final definition = SymbolCatalog.definitionFor(placingKind!);
      final box = Rect.fromCenter(
        center: snapped,
        width: definition.width + 18,
        height: definition.height + 18,
      );
      canvas.drawRect(box, Paint()..color = palette.paper);
      _drawDashedPath(
        canvas,
        Path()..addRect(box),
        Paint()
          ..color = palette.selection
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 / zoom,
      );
      canvas.save();
      canvas.translate(snapped.dx, snapped.dy);
      _paintSymbol(canvas, placingKind!, palette.selection, palette.paper);
      canvas.restore();
      _label(
        canvas,
        'KLIKNUTÍM VLOŽIT',
        Offset(box.right + 10, box.top + 2),
        color: palette.selection,
        size: 9,
        weight: FontWeight.w600,
      );
    }

    if (marquee != null) {
      if (!palette.highContrast) {
        canvas.drawRect(
          marquee!,
          Paint()..color = palette.selection.withValues(alpha: 0.055),
        );
      }
      _drawDashedPath(
        canvas,
        Path()..addRect(marquee!),
        Paint()
          ..color = palette.selection
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 / zoom,
        dashLength: 5 / zoom,
        gapLength: 3 / zoom,
      );
    }
    canvas.restore();
  }

  void _drawPage(Canvas canvas, Rect visible) {
    final page = Rect.fromLTWH(0, 0, scene.sheet.width, scene.sheet.height);
    if (!palette.highContrast) {
      canvas.drawRect(
        page.shift(const Offset(3, 4)),
        Paint()..color = palette.ink.withValues(alpha: 0.05),
      );
    }
    canvas.drawRect(page, Paint()..color = palette.paper);
    canvas.drawRect(
      page,
      Paint()
        ..color = palette.sheetBorder
        ..strokeWidth = 0.8
        ..style = PaintingStyle.stroke,
    );
    if (showGrid) {
      _drawGrid(
        canvas,
        visible.intersect(scene.sheet.showFrame ? page.deflate(32) : page),
      );
    }
    if (!scene.sheet.showFrame) return;
    canvas.save();
    canvas.scale(
      scene.sheet.width / SchematicCanvas.pageSize.width,
      scene.sheet.height / SchematicCanvas.pageSize.height,
    );
    const frame = Rect.fromLTRB(32, 32, 1068, 748);
    canvas.drawRect(
      frame,
      Paint()
        ..color = palette.sheetBorder
        ..strokeWidth = palette.highContrast ? 1 : 0.65
        ..style = PaintingStyle.stroke,
    );

    final line =
        Paint()
          ..color = palette.sheetBorder
          ..strokeWidth = 0.65;
    const letters = ['A', 'B', 'C', 'D', 'E'];
    for (var i = 0; i < 5; i++) {
      final x = 32 + frame.width * (i + 0.5) / 5;
      _label(
        canvas,
        letters[i],
        Offset(x - 3, 15),
        color: palette.muted,
        size: 8,
      );
      _label(
        canvas,
        letters[i],
        Offset(x - 3, 757),
        color: palette.muted,
        size: 8,
      );
      if (i > 0) {
        final tick = 32 + frame.width * i / 5;
        canvas.drawLine(Offset(tick, 26), Offset(tick, 32), line);
        canvas.drawLine(Offset(tick, 748), Offset(tick, 754), line);
      }
    }
    for (var i = 0; i < 4; i++) {
      final y = 32 + frame.height * (i + 0.5) / 4;
      _label(
        canvas,
        '${i + 1}',
        Offset(16, y - 4),
        color: palette.muted,
        size: 8,
      );
      _label(
        canvas,
        '${i + 1}',
        Offset(1077, y - 4),
        color: palette.muted,
        size: 8,
      );
    }

    canvas.drawRect(
      const Rect.fromLTWH(54, 48, 435, 59),
      Paint()..color = palette.paper,
    );
    _label(
      canvas,
      scene.sheet.type.label.toUpperCase(),
      const Offset(62, 52),
      size: 8,
      letterSpacing: 1.6,
      color: palette.muted,
      weight: FontWeight.w500,
    );
    _label(
      canvas,
      scene.sheet.name,
      const Offset(61, 69),
      size: 21,
      color: palette.ink,
      weight: FontWeight.w500,
    );
    _label(
      canvas,
      'LIST  ${scene.sheet.number}',
      const Offset(837, 57),
      size: 8,
      letterSpacing: 0.9,
      color: palette.muted,
    );

    const block = Rect.fromLTRB(676, 674, 1068, 748);
    canvas.drawRect(block, Paint()..color = palette.paper);
    canvas.drawRect(
      block,
      Paint()
        ..color = palette.sheetBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
    canvas.drawLine(const Offset(676, 719), const Offset(1068, 719), line);
    canvas.drawLine(const Offset(938, 674), const Offset(938, 748), line);
    canvas.drawLine(const Offset(818, 719), const Offset(818, 748), line);
    canvas.drawLine(const Offset(1007, 719), const Offset(1007, 748), line);
    _label(
      canvas,
      'VÝKRES',
      const Offset(688, 682),
      color: palette.muted,
      size: 6.5,
      letterSpacing: 1,
    );
    _label(
      canvas,
      scene.sheet.name,
      const Offset(688, 695),
      color: palette.ink,
      size: 10,
      weight: FontWeight.w500,
    );
    _label(
      canvas,
      'OPEN ECAD',
      const Offset(950, 690),
      color: palette.ink,
      size: 10,
      weight: FontWeight.w600,
      letterSpacing: 0.6,
    );
    _label(
      canvas,
      'DOKUMENT  /  EC-001',
      const Offset(688, 729),
      color: palette.muted,
      size: 7,
    );
    _label(
      canvas,
      'MĚŘÍTKO  /  —',
      const Offset(830, 729),
      color: palette.muted,
      size: 7,
    );
    _label(
      canvas,
      'REV.  /  A',
      const Offset(950, 729),
      color: palette.muted,
      size: 7,
    );
    _label(
      canvas,
      'LIST ${scene.sheet.number}',
      const Offset(1017, 729),
      color: palette.muted,
      size: 7,
    );
    _label(
      canvas,
      'OPEN ECAD   ·   ELEKTROPROJEKTOVÁNÍ',
      const Offset(61, 723),
      color: palette.muted,
      size: 7,
      letterSpacing: 0.5,
    );
    canvas.restore();
  }

  void _drawGrid(Canvas canvas, Rect area) {
    if (area.isEmpty) return;
    var spacing = palette.highContrast ? 40.0 : 20.0;
    while (spacing * zoom < 11) {
      spacing *= 2;
    }
    final startX = (area.left / spacing).ceil() * spacing;
    final startY = (area.top / spacing).ceil() * spacing;
    final paint =
        Paint()
          ..color = palette.grid
          ..strokeWidth = (palette.highContrast ? 0.6 : 1.0) / zoom
          ..strokeCap = StrokeCap.round;
    final points = <Offset>[];
    for (var y = startY; y < area.bottom; y += spacing) {
      for (var x = startX; x < area.right; x += spacing) {
        if (palette.highContrast) {
          final arm = 1.5 / zoom;
          points.addAll([
            Offset(x - arm, y),
            Offset(x + arm, y),
            Offset(x, y - arm),
            Offset(x, y + arm),
          ]);
        } else {
          points.add(Offset(x, y));
        }
      }
    }
    canvas.drawPoints(
      palette.highContrast ? ui.PointMode.lines : ui.PointMode.points,
      points,
      paint,
    );
  }

  void _drawWire(Canvas canvas, List<Offset> points, bool selected) {
    if (points.length < 2) return;
    final path = _pathFromPoints(points);
    if (selected && !palette.highContrast) {
      canvas.drawPath(
        path,
        Paint()
          ..color = palette.selection.withValues(alpha: 0.14)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7 / zoom,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = selected ? palette.selection : palette.wire
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 2 : 1.35
        ..strokeCap = StrokeCap.square
        ..strokeJoin = StrokeJoin.miter,
    );
    if (selected) {
      for (final point in [points.first, points.last]) {
        canvas.drawCircle(point, 3 / zoom, Paint()..color = palette.selection);
      }
    }
  }

  void _drawDevice(Canvas canvas, Device device) {
    final position = _offset(previewPositions[device.id] ?? device.position);
    final selected = selectedIds.contains(device.id);
    final definition = SymbolCatalog.definitionFor(device.kind);
    final originalBounds = scene.deviceBounds[device.id]!;
    final bounds = originalBounds.shift(position - _offset(device.position));
    if (selected) {
      final selectionBounds = bounds.inflate(7);
      canvas.drawRect(
        selectionBounds,
        Paint()
          ..color = palette.selection
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 / zoom,
      );
      for (final corner in [
        selectionBounds.topLeft,
        selectionBounds.topRight,
        selectionBounds.bottomLeft,
        selectionBounds.bottomRight,
      ]) {
        final handle = Rect.fromCenter(
          center: corner,
          width: 4.5 / zoom,
          height: 4.5 / zoom,
        );
        canvas.drawRect(handle, Paint()..color = palette.paper);
        canvas.drawRect(
          handle,
          Paint()
            ..color = palette.selection
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1 / zoom,
        );
      }
    }

    canvas.save();
    canvas.translate(position.dx, position.dy);
    canvas.rotate(device.rotation * math.pi / 180);
    _paintSymbol(
      canvas,
      device.kind,
      selected ? palette.selection : palette.ink,
      palette.paper,
      dcSupply: RegExp(r'\bDC\b', caseSensitive: false).hasMatch(device.rating),
      showText: zoom >= 0.45 || selected,
    );
    canvas.restore();

    // At overview scale these labels would be below five logical pixels.
    // Geometry remains visible and accessible; selecting a device restores its
    // full detail regardless of zoom.
    if (zoom >= 0.45 || selected) {
      final textX = bounds.right + 14;
      _label(
        canvas,
        device.designation,
        Offset(textX, position.dy - 17),
        color: selected ? palette.selection : palette.ink,
        size: 11,
        weight: FontWeight.w600,
        background: palette.paper,
      );
      final subtitle =
          device.rating.isNotEmpty ? device.rating : _deviceLabel(device.kind);
      _label(
        canvas,
        subtitle,
        Offset(textX, position.dy + 1),
        color: palette.muted,
        size: 8.5,
        background: palette.paper,
      );
    }

    for (final port in definition.ports) {
      final reference = TerminalRef(deviceId: device.id, portId: port.id);
      final point = _portPosition(device, port.id, previewPositions);
      final highlighted =
          _samePort(reference, hoverPort) || _samePort(reference, wireStart);
      if (wireMode || selected || highlighted) {
        canvas.drawCircle(
          point,
          highlighted ? 5 / zoom : 2.8 / zoom,
          Paint()..color = palette.paper,
        );
        canvas.drawCircle(
          point,
          highlighted ? 5 / zoom : 2.8 / zoom,
          Paint()
            ..color = highlighted ? palette.selection : palette.muted
            ..style = PaintingStyle.stroke
            ..strokeWidth = (highlighted ? 1.5 : 1) / zoom,
        );
        if (highlighted) {
          _label(
            canvas,
            '${device.designation}:${port.label}',
            point + Offset(9 / zoom, -15 / zoom),
            color: palette.selection,
            background: palette.paper,
            size: 9 / zoom,
            weight: FontWeight.w500,
          );
        }
      } else if (zoom >= 0.45) {
        canvas.drawCircle(point, 1.8, Paint()..color = palette.wire);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SchematicPainter oldDelegate) => true;

  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final worldRect = Rect.fromLTWH(
      -pan.dx / zoom,
      -pan.dy / zoom,
      size.width / zoom,
      size.height / zoom,
    );
    final keys = scene.index.query(worldRect);
    return [
      for (final key in keys)
        if (key.startsWith('d:'))
          _deviceSemantics(scene.devices[key.substring(2)]!)
        else if (key.startsWith('g:'))
          _graphicSemantics(scene.graphics[key.substring(2)]!),
    ];
  };

  CustomPainterSemantics _graphicSemantics(DrawingVisual visual) {
    final graphic = visual.element;
    final bounds = visual.bounds;
    return CustomPainterSemantics(
      key: ValueKey(graphic.id),
      rect: Rect.fromLTRB(
        bounds.left * zoom + pan.dx,
        bounds.top * zoom + pan.dy,
        bounds.right * zoom + pan.dx,
        bounds.bottom * zoom + pan.dy,
      ),
      properties: SemanticsProperties(
        label: switch (graphic.kind) {
          DrawingKind.path => 'Vektorová kresba',
          DrawingKind.text => graphic.text,
          DrawingKind.image => 'Obrázek',
        },
        hint: 'Vybrat grafický prvek',
        button: true,
        selected: selectedIds.contains(graphic.id),
        textDirection: TextDirection.ltr,
        onTap: () => onSelectDevice(graphic.id),
      ),
    );
  }

  CustomPainterSemantics _deviceSemantics(Device device) {
    final bounds = scene.deviceBounds[device.id]!;
    final rect = Rect.fromLTRB(
      bounds.left * zoom + pan.dx,
      bounds.top * zoom + pan.dy,
      bounds.right * zoom + pan.dx,
      bounds.bottom * zoom + pan.dy,
    );
    return CustomPainterSemantics(
      key: ValueKey(device.id),
      rect: rect,
      properties: SemanticsProperties(
        label:
            '${device.designation}, '
            '${_deviceLabel(device.kind)}'
            '${device.rating.isEmpty ? '' : ', ${device.rating}'}',
        hint: 'Vybrat přístroj',
        button: true,
        selected: selectedIds.contains(device.id),
        textDirection: TextDirection.ltr,
        onTap: () => onSelectDevice(device.id),
      ),
    );
  }

  @override
  bool shouldRebuildSemantics(covariant _SchematicPainter oldDelegate) =>
      !identical(oldDelegate.scene, scene) ||
      oldDelegate.pan != pan ||
      oldDelegate.zoom != zoom ||
      oldDelegate.selectedIds.length != selectedIds.length ||
      !oldDelegate.selectedIds.containsAll(selectedIds);
}

Path _pathFromPoints(List<Offset> points) {
  final path = Path();
  if (points.isEmpty) return path;
  path.moveTo(points.first.dx, points.first.dy);
  for (final point in points.skip(1)) {
    path.lineTo(point.dx, point.dy);
  }
  return path;
}

void _drawDashedPath(
  Canvas canvas,
  Path path,
  Paint paint, {
  double dashLength = 5,
  double gapLength = 3,
}) {
  for (final metric in path.computeMetrics()) {
    for (
      var offset = 0.0;
      offset < metric.length;
      offset += dashLength + gapLength
    ) {
      canvas.drawPath(
        metric.extractPath(
          offset,
          math.min(offset + dashLength, metric.length),
        ),
        paint,
      );
    }
  }
}

void _label(
  Canvas canvas,
  String text,
  Offset position, {
  required Color color,
  double size = 10,
  FontWeight weight = FontWeight.w400,
  double letterSpacing = 0,
  Color? background,
}) {
  final painter = _TextLayouts.get(text, color, size, weight, letterSpacing);
  if (background != null) {
    canvas.drawRect(
      (position & painter.size).inflate(2),
      Paint()..color = background,
    );
  }
  painter.paint(canvas, position);
}

/// Panning and zooming change placement, not text layout. Reusing bounded text
/// paragraphs avoids reshaping thousands of unchanged labels on every frame.
abstract final class _TextLayouts {
  static final _cache =
      <(String, Color, double, FontWeight, double), TextPainter>{};
  static const _capacity = 4096;

  static TextPainter get(
    String text,
    Color color,
    double size,
    FontWeight weight,
    double spacing,
  ) {
    final key = (text, color, size, weight, spacing);
    final existing = _cache.remove(key);
    if (existing != null) {
      _cache[key] = existing;
      return existing;
    }
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontFamily: 'NotoSans',
          fontWeight: weight,
          letterSpacing: spacing,
          height: 1.15,
        ),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    _cache[key] = painter;
    if (_cache.length > _capacity) {
      _cache.remove(_cache.keys.first)!.dispose();
    }
    return painter;
  }
}

/// Compact symbol previews for the component library and the properties panel.
class SymbolPreview extends StatelessWidget {
  const SymbolPreview({
    super.key,
    required this.kind,
    required this.palette,
    this.size = 32,
  });

  final DeviceKind kind;
  final CanvasPalette palette;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: _deviceLabel(kind),
    image: true,
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _SymbolPreviewPainter(kind, palette)),
    ),
  );
}

String _deviceLabel(DeviceKind kind) => switch (kind) {
  DeviceKind.supply => 'Napájení',
  DeviceKind.breaker => 'Jistič',
  DeviceKind.threePoleBreaker => 'Třípólový jistič',
  DeviceKind.fuse => 'Pojistka',
  DeviceKind.disconnector => 'Odpojovač',
  DeviceKind.threePoleDisconnector => 'Třípólový odpojovač',
  DeviceKind.contactor => 'Stykač',
  DeviceKind.motor => 'Motor',
  DeviceKind.transformer => 'Transformátor',
  DeviceKind.currentTransformer => 'Transformátor proudu',
  DeviceKind.terminal => 'Svorka',
  DeviceKind.earth => 'Ochranné uzemnění',
  DeviceKind.contactNo => 'Spínací kontakt',
  DeviceKind.contactNc => 'Rozpínací kontakt',
  DeviceKind.pushbuttonNo => 'Spínací tlačítko',
  DeviceKind.coil => 'Cívka relé',
  DeviceKind.lamp => 'Kontrolka',
  DeviceKind.ammeter => 'Ampérmetr',
  DeviceKind.voltmeter => 'Voltmetr',
};

class _SymbolPreviewPainter extends CustomPainter {
  const _SymbolPreviewPainter(this.kind, this.palette);

  final DeviceKind kind;
  final CanvasPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final definition = SymbolCatalog.definitionFor(kind);
    final scale = math.min(
      size.width / (definition.width + 8),
      size.height / (definition.height + 8),
    );
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    _paintSymbol(
      canvas,
      kind,
      palette.ink,
      palette.paper,
      strokeWidth: 1.4 / scale,
    );
  }

  @override
  bool shouldRepaint(covariant _SymbolPreviewPainter oldDelegate) =>
      kind != oldDelegate.kind || palette != oldDelegate.palette;
}

/// Simple original vector depictions with catalog-defined connection geometry.
void _paintSymbol(
  Canvas canvas,
  DeviceKind kind,
  Color ink,
  Color paper, {
  double strokeWidth = 1.6,
  bool dcSupply = false,
  bool showText = true,
}) {
  final definition = SymbolCatalog.definitionFor(kind);
  final stroke =
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.square
        ..strokeJoin = StrokeJoin.miter;
  final fill = Paint()..color = paper;
  Offset port(String id) => _offset(
    definition.ports.firstWhere((candidate) => candidate.id == id).position,
  );
  void line(Offset from, Offset to) => canvas.drawLine(from, to, stroke);
  void circle(double radius, [Offset center = Offset.zero]) {
    canvas.drawCircle(center, radius, fill);
    canvas.drawCircle(center, radius, stroke);
  }

  void symbolText(String text, double size, Offset position) => _label(
    canvas,
    text,
    position,
    color: ink,
    size: size,
    weight: FontWeight.w500,
  );

  // Same anchoring as SVG text-anchor="middle" with y on the baseline, so
  // exports place the glyph where the canvas shows it.
  void centeredText(String text, double size, double baseline) {
    final painter = _TextLayouts.get(text, ink, size, FontWeight.w500, 0);
    painter.paint(
      canvas,
      Offset(
        -painter.width / 2,
        baseline -
            painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
      ),
    );
  }

  void dashed(Offset from, Offset to) => _drawDashedPath(
    canvas,
    Path()
      ..moveTo(from.dx, from.dy)
      ..lineTo(to.dx, to.dy),
    stroke,
    dashLength: 3,
    gapLength: 3,
  );

  void switchPole(Offset input, Offset output, {required bool breaker}) {
    final x = input.dx;
    line(input, Offset(x, -16));
    line(Offset(x, 16), output);
    line(Offset(x, -16), Offset(x + 12, 11));
    if (breaker) {
      line(Offset(x - 3, 13), Offset(x + 3, 19));
      line(Offset(x - 3, 19), Offset(x + 3, 13));
    } else {
      line(Offset(x - 6, 16), Offset(x + 6, 16));
    }
  }

  switch (kind) {
    case DeviceKind.supply:
      line(const Offset(0, 17), port('out'));
      circle(21, const Offset(0, -4));
      if (dcSupply) {
        line(const Offset(-8, -10), const Offset(8, -10));
        line(const Offset(0, -18), const Offset(0, -2));
        line(const Offset(-8, 6), const Offset(8, 6));
      } else {
        final wave =
            Path()
              ..moveTo(-12, -4)
              ..cubicTo(-8, -14, -4, -14, 0, -4)
              ..cubicTo(4, 6, 8, 6, 12, -4);
        canvas.drawPath(wave, stroke);
      }
    case DeviceKind.breaker:
      const top = Offset(0, -17);
      const bottom = Offset(0, 17);
      line(port('in'), top);
      line(bottom, port('out'));
      line(top, const Offset(16, 10));
      line(const Offset(-7, -16), const Offset(7, -16));
      line(const Offset(-7, 17), const Offset(7, 17));
      canvas.drawRect(const Rect.fromLTRB(-12, -10, -5, 3), stroke);
    case DeviceKind.threePoleBreaker || DeviceKind.threePoleDisconnector:
      for (final (input, output) in const [
        ('1', '2'),
        ('3', '4'),
        ('5', '6'),
      ]) {
        switchPole(
          port(input),
          port(output),
          breaker: kind == DeviceKind.threePoleBreaker,
        );
      }
      dashed(Offset(port('1').dx + 6, -2.5), Offset(port('5').dx + 6, -2.5));
    case DeviceKind.disconnector:
      switchPole(port('in'), port('out'), breaker: false);
    case DeviceKind.fuse:
      const body = Rect.fromLTRB(-6, -14, 6, 14);
      canvas.drawRect(body, fill);
      canvas.drawRect(body, stroke);
      line(port('in'), port('out'));
    case DeviceKind.contactor:
      const top = Offset(0, -16);
      const bottom = Offset(0, 16);
      line(port('in'), top);
      line(bottom, port('out'));
      line(top, const Offset(16, 11));
      line(const Offset(-6, -16), const Offset(6, -16));
      line(const Offset(-6, 16), const Offset(6, 16));
      _drawDashedPath(
        canvas,
        Path()
          ..moveTo(-15, -14)
          ..lineTo(-15, 15),
        stroke,
        dashLength: 3,
        gapLength: 3,
      );
    case DeviceKind.contactNo:
      const top = Offset(0, -14);
      const bottom = Offset(0, 14);
      line(port('in'), top);
      line(bottom, port('out'));
      line(top, const Offset(15, 10));
      circle(2, top);
      circle(2, bottom);
    case DeviceKind.contactNc:
      const top = Offset(0, -14);
      const bottom = Offset(0, 14);
      line(port('in'), top);
      line(bottom, port('out'));
      line(bottom, const Offset(14, 14));
      // A closed blade crosses the end of the fixed contact.
      line(top, const Offset(16, 18));
      circle(2, top);
      circle(2, bottom);
    case DeviceKind.pushbuttonNo:
      const top = Offset(0, -14);
      const bottom = Offset(0, 14);
      line(port('in'), top);
      line(bottom, port('out'));
      line(top, const Offset(15, 10));
      line(const Offset(-11, -8), const Offset(-14, -8));
      line(const Offset(-14, -8), const Offset(-14, 4));
      line(const Offset(-14, 4), const Offset(-11, 4));
      dashed(const Offset(-14, -2), const Offset(7.5, -2));
      circle(2, top);
      circle(2, bottom);
    case DeviceKind.motor:
      line(port('in'), const Offset(0, -27));
      line(const Offset(27, 0), port('pe'));
      circle(27);
      if (showText) {
        symbolText('M', 23, const Offset(-10, -22));
        symbolText('3~', 10, const Offset(-6, 6));
      }
    case DeviceKind.transformer:
      // Leads end on the circles: 10² + 10.5² = 14.5².
      line(port('1u1'), const Offset(-10, -19.5));
      line(port('1u2'), const Offset(10, -19.5));
      line(const Offset(-10, 19.5), port('2u1'));
      line(const Offset(10, 19.5), port('2u2'));
      // Fill both windings first so both outlines stay visible in the overlap.
      for (final center in const [Offset(0, -9), Offset(0, 9)]) {
        canvas.drawCircle(center, 14.5, fill);
      }
      for (final center in const [Offset(0, -9), Offset(0, 9)]) {
        canvas.drawCircle(center, 14.5, stroke);
      }
    case DeviceKind.currentTransformer:
      circle(14.5);
      // The primary conductor stays visible through the core.
      line(port('p1'), port('p2'));
      line(port('s1'), const Offset(-10.5, -10));
      line(port('s2'), const Offset(-10.5, 10));
    case DeviceKind.terminal:
      line(port('in'), const Offset(0, -7));
      line(const Offset(0, 7), port('out'));
      circle(7);
    case DeviceKind.earth:
      line(port('in'), Offset.zero);
      line(const Offset(-18, 0), const Offset(18, 0));
      line(const Offset(-12, 6), const Offset(12, 6));
      line(const Offset(-6, 12), const Offset(6, 12));
    case DeviceKind.coil:
      const rect = Rect.fromLTRB(-21, -15, 21, 15);
      line(port('a1'), rect.topCenter);
      line(rect.bottomCenter, port('a2'));
      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, stroke);
    case DeviceKind.lamp:
      line(port('in'), const Offset(0, -19));
      line(const Offset(0, 19), port('out'));
      circle(19);
      line(const Offset(-13, -13), const Offset(13, 13));
      line(const Offset(13, -13), const Offset(-13, 13));
    case DeviceKind.ammeter || DeviceKind.voltmeter:
      line(port('in'), const Offset(0, -15));
      line(const Offset(0, 15), port('out'));
      circle(15);
      if (showText) {
        centeredText(kind == DeviceKind.ammeter ? 'A' : 'V', 18, 6.5);
      }
  }
}
