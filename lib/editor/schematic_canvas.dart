import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'drawing_graphics.dart';
import 'layout_diagnostics.dart';
import '../services/document_layout.dart';
import '../services/frame_layout.dart';
import 'drawing_cursor.dart';
import 'middle_button_double_click.dart';
import 'sheet_viewport.dart';
import 'terminal_symbol_painter.dart';
import 'wire_hover_overlay.dart';
import 'canvas_hover_overlay.dart';
import '../services/device_hover_info.dart';
import '../services/wire_route_description.dart';
import '../services/keyboard_shortcuts.dart';
import '../services/schematic_annotations.dart';
import '../services/pointer_warp.dart';
import '../services/schematic_clipboard.dart';
import 'spatial_index.dart';

enum CanvasMode {
  select,
  wire,
  continuation,
  corner,
  pan,
  place,
  drawLine,
  drawRectangle,
  drawText,
}

typedef SelectionMoveCallback =
    void Function({
      required Map<String, Vec2> devices,
      required Map<String, Vec2> graphics,
      required Map<String, Vec2> markers,
      required Map<String, Vec2> corners,
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

  double get zoom => _externalZoom == null ? _canvas?._zoom ?? _zoom : _zoom;
  int get visiblePrimitiveCount => _visiblePrimitiveCount;
  int get totalPrimitiveCount => _totalPrimitiveCount;
  bool get hasActiveGesture =>
      (_externalHasActiveGesture?.call() ?? false) ||
      (_canvas?._hasActiveGesture ?? false);
  bool get canInteract => _canvas?._canInteract ?? false;
  String? get hoveredContinuationId {
    return _canvas?._hoveredContinuationId;
  }

  Vec2? get continuationFocus => _canvas?._continuationFocus;
  Vec2? get deviceFocus => _canvas?._deviceFocus;
  Vec2? get pastePosition => _canvas?._pastePosition;
  void focus() => _canvas?._focus.requestFocus();
  Rect? get worldViewport => _canvas?._worldViewport;
  Offset? worldToLocal(Vec2 point) =>
      _canvas == null ? null : _offset(point) * _canvas!._zoom + _canvas!._pan;

  bool revealDevice({
    required Object documentIdentity,
    required String sheetId,
    required String deviceId,
    required double zoom,
  }) {
    final canvas = _canvas;
    if (canvas == null ||
        canvas.widget.documentIdentity != documentIdentity ||
        canvas.widget.sheet.id != sheetId ||
        !canvas._canInteract ||
        ModalRoute.of(canvas.context)?.isCurrent != true ||
        FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<EditableText>() !=
            null) {
      return false;
    }
    final device = canvas._scene.devices[deviceId];
    if (device == null) return false;
    canvas._revealDevice(device, zoom);
    return true;
  }

  bool revealContinuation({
    required Object documentIdentity,
    required String sheetId,
    required String markerId,
    double? zoom,
  }) {
    final canvas = _canvas;
    if (canvas == null ||
        canvas.widget.documentIdentity != documentIdentity ||
        canvas.widget.sheet.id != sheetId ||
        !canvas._canInteract) {
      return false;
    }
    final marker = canvas._scene.markers[markerId];
    if (marker == null) return false;
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (ModalRoute.of(canvas.context)?.isCurrent != true ||
        focusContext?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    canvas._revealContinuation(marker, zoom: zoom);
    return true;
  }

  PointerWarpTarget? continuationPointerTarget({
    required Object documentIdentity,
    required String sheetId,
    required String markerId,
    required int revision,
  }) {
    final canvas = _canvas;
    if (canvas == null ||
        !canvas.mounted ||
        canvas.widget.documentIdentity != documentIdentity ||
        canvas.widget.sheet.id != sheetId ||
        canvas.widget.project?.revision != revision ||
        !canvas._canInteract ||
        !canvas._focus.hasPrimaryFocus ||
        ModalRoute.of(canvas.context)?.isCurrent != true) {
      return null;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return null;
    }
    final marker = canvas._scene.markers[markerId];
    final box = canvas.context.findRenderObject();
    if (marker == null || box is! RenderBox || !box.attached || !box.hasSize) {
      return null;
    }
    final local = worldToLocal(marker.position)!;
    if (!(Offset.zero & box.size).contains(local)) return null;
    RenderObject root = box;
    while (root.parent != null) {
      root = root.parent!;
    }
    final view = View.of(canvas.context);
    if (root is! RenderView || root.flutterView != view || root.child == null) {
      return null;
    }
    // RenderView's paint transform adds DPR; its child still uses view logical pixels.
    final target = PointerWarpTarget(
      position: box.localToGlobal(local, ancestor: root.child),
      viewId: view.viewId,
      devicePixelRatio: view.devicePixelRatio,
      physicalSize: view.physicalSize,
    );
    return target.valid ? target : null;
  }

  Object? _navigationOwner;
  VoidCallback? _externalFit;
  ValueChanged<double>? _externalZoom;
  bool Function()? _externalHasActiveGesture;
  void bindNavigation(
    Object owner, {
    required VoidCallback fit,
    required ValueChanged<double> zoom,
    bool Function()? hasActiveGesture,
  }) {
    _navigationOwner = owner;
    _externalFit = fit;
    _externalZoom = zoom;
    _externalHasActiveGesture = hasActiveGesture;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_navigationOwner == owner) _update(1, 0, 0);
    });
  }

  void unbindNavigation(Object owner) {
    if (_navigationOwner != owner) return;
    _navigationOwner = null;
    _externalFit = null;
    _externalZoom = null;
    _externalHasActiveGesture = null;
  }

  void reportZoom(double zoom) => _update(zoom, 0, 0);
  void zoomIn() {
    if (_externalZoom != null) {
      _externalZoom!(1.2);
    } else {
      _canvas?._zoomAt(_canvas!._viewport.center(Offset.zero), 1.2);
    }
  }

  void zoomOut() {
    if (_externalZoom != null) {
      _externalZoom!(1 / 1.2);
    } else {
      _canvas?._zoomAt(_canvas!._viewport.center(Offset.zero), 1 / 1.2);
    }
  }

  void fit() {
    if (_externalFit != null) {
      _externalFit!();
    } else {
      _canvas?._fit();
    }
  }

  void reset() {
    if (_externalFit != null) {
      _externalFit!();
    } else {
      _canvas?._reset();
    }
  }

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
    this.project,
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
    this.onEditDevice,
    this.onEditDrawingObject,
    this.onEditContinuation,
    this.onFollowContinuation,
    this.onFollowDevice,
    this.onPlaceContinuation,
    this.pastePreview,
    this.onPlacePaste,
    this.terminalSides = const {PortSide.top, PortSide.bottom},
    this.placingKind,
    this.cornerOrientation = CornerOrientation.topLeft,
    this.onPlaceCorner,
    this.documentIdentity,
    this.readOnly = false,
    this.shortcuts = const KeyboardShortcuts.defaults(),
  });

  final ClipboardPlacement? pastePreview;
  final ValueChanged<Vec2>? onPlacePaste;
  final Sheet sheet;
  final EcadProject? project;
  final Set<String> selectedIds;
  final CanvasMode mode;
  final DeviceKind? placingKind;
  final Set<PortSide> terminalSides;
  final CornerOrientation cornerOrientation;
  final ValueChanged<Vec2>? onPlaceCorner;
  final Object? documentIdentity;
  final bool readOnly;
  final KeyboardShortcuts shortcuts;
  final bool showGrid;
  final CanvasPalette palette;
  final SchematicViewportController controller;
  final ValueChanged<Set<String>> onSelectionChanged;
  final ValueChanged<Map<String, Vec2>> onMoveDevices;
  final SelectionMoveCallback? onMoveSelection;
  final ValueChanged<Map<String, Vec2>>? onMoveGraphics;
  final ValueChanged<DrawingElement>? onCreateGraphic;
  final ValueChanged<String>? onEditDevice;
  final ValueChanged<String>? onEditDrawingObject;
  final ValueChanged<String>? onEditContinuation;
  final ValueChanged<String>? onFollowContinuation;
  final void Function(String sourceId, DeviceOccurrence target)? onFollowDevice;
  final ValueChanged<Vec2>? onPlaceContinuation;
  final void Function(DeviceKind kind, Vec2 position) onPlaceDevice;
  final void Function(WireEndpoint from, WireEndpoint to) onConnect;
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
  _Scene? _pasteScene;
  Size _viewport = Size.zero;
  Offset _pan = Offset.zero;
  double _zoom = 1;
  bool _fitted = true;
  bool _temporaryPanPressed = false;
  LogicalKeyboardKey? _temporaryPanKey;
  bool _statsScheduled = false;
  int? _activePointer;
  _DragKind _drag = _DragKind.none;
  Offset? _pointerWorld;
  Offset? _lastPointerGlobal;
  Offset? _downLocal;
  Offset? _downWorld;
  Offset? _panOrigin;
  Rect? _marquee;
  Set<String> _marqueeSelection = {};
  Set<String> _baseSelection = {};
  Map<String, Vec2> _moveOrigin = {};
  Map<String, Vec2> _previewPositions = {};
  WireEndpoint? _wireStart;
  WireEndpoint? _hoverPort;
  String? _hoverDevice;
  String? _selectedWire;
  String? _hoverWire;
  String? _hoverInfoDevice;
  Offset? _hoverLocal;
  double _panZoomStartScale = 1;
  DrawingElement? _drawingPreview;
  int _creationSerial = 0;
  (String, Offset, Duration)? _lastDeviceTap;
  String? _tapDevice;
  Vec2? _continuationFocus;
  Vec2? _deviceFocus;
  DeviceCrossReference? _hoverReference;
  DeviceCrossReference? _pressedReference;
  String? _hoverContinuationLink, _pressedContinuationLink;
  ValueChanged<bool>? _overrideDrawingCursor;
  final _middleDoubleClick = MiddleButtonDoubleClick();
  bool _panZoomActive = false;
  bool get _hasActiveGesture =>
      _activePointer != null ||
      _drag != _DragKind.none ||
      _wireStart != null ||
      _temporaryPanPressed ||
      _panZoomActive;
  bool get _canInteract =>
      !widget.readOnly &&
      widget.mode == CanvasMode.select &&
      widget.pastePreview == null &&
      !_hasActiveGesture;

  Rect get _paperBounds {
    final bounds = SheetTransform(widget.sheet).paperBoundsUnits;
    return Rect.fromLTWH(bounds.x, bounds.y, bounds.width, bounds.height);
  }

  Size get _pageSize => _paperBounds.size;

  bool get _linkCursor =>
      _canInteract &&
      (_hoverReference != null || _hoverContinuationLink != null) &&
      HardwareKeyboard.instance.isControlPressed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _overrideDrawingCursor = DrawingCursorRegion.systemCursorOverrideOf(
      context,
    );
  }

  CanvasPalette get _canvasPalette {
    final palette = widget.palette;
    if (widget.sheet.sourcePage == null || palette.highContrast) return palette;
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
    _scene = _Scene(widget.sheet, widget.project);
    _images.addListener(_imagesChanged);
    final preview = widget.pastePreview?.preview;
    if (preview != null) _pasteScene = _Scene(preview.pages.single, preview);
    _images.update([
      ...widget.sheet.graphics,
      ...?preview?.pages.single.graphics,
    ]);
    widget.controller._canvas = this;
    FocusManager.instance.addListener(_dismissHover);
    HardwareKeyboard.instance.addHandler(_modifiersChanged);
  }

  @override
  void didUpdateWidget(covariant SchematicCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sheet.id != widget.sheet.id ||
        !identical(oldWidget.documentIdentity, widget.documentIdentity) ||
        oldWidget.controller != widget.controller ||
        oldWidget.project?.id != widget.project?.id) {
      _cancelGesture();
      _selectedWire = null;
      _hoverDevice = null;
      _hoverPort = null;
    }

    if (!identical(oldWidget.pastePreview, widget.pastePreview)) {
      _pasteScene?.dispose();
      final preview = widget.pastePreview?.preview;
      _pasteScene =
          preview == null ? null : _Scene(preview.pages.single, preview);
      _images.update([
        ...widget.sheet.graphics,
        ...?preview?.pages.single.graphics,
      ]);
      _lastDeviceTap = null;
      _clearHover();
    }

    if (!identical(oldWidget.sheet, widget.sheet) ||
        !identical(oldWidget.project, widget.project)) {
      _cancelGesture();
      _scene.dispose();
      _scene = _Scene(widget.sheet, widget.project);
      _images.update(widget.sheet.graphics);
      if (oldWidget.sheet.width != widget.sheet.width ||
          oldWidget.sheet.height != widget.sheet.height ||
          oldWidget.sheet.paperSizeMm != widget.sheet.paperSizeMm) {
        _fit(rebuild: false);
      }
      if (_selectedWire != null && !_scene.wires.containsKey(_selectedWire)) {
        _selectedWire = null;
      }
      if (_wireStart != null &&
          !_scene.devices.containsKey(_wireStart!.ownerId) &&
          !_scene.markers.containsKey(_wireStart!.ownerId) &&
          !_scene.corners.containsKey(_wireStart!.ownerId)) {
        _wireStart = null;
      }
    }
    if (oldWidget.mode != widget.mode ||
        oldWidget.readOnly != widget.readOnly ||
        oldWidget.placingKind != widget.placingKind ||
        oldWidget.cornerOrientation != widget.cornerOrientation ||
        oldWidget.shortcuts != widget.shortcuts) {
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
    HardwareKeyboard.instance.removeHandler(_modifiersChanged);
    FocusManager.instance.removeListener(_dismissHover);
    _cancelGesture();
    if (widget.controller._canvas == this) widget.controller._canvas = null;
    _focus.dispose();
    _scene.dispose();
    _pasteScene?.dispose();
    _images.dispose();
    super.dispose();
  }

  Vec2? get _pastePosition {
    if (widget.pastePreview == null) return null;
    final box = context.findRenderObject();
    final global = _lastPointerGlobal;
    if (box is RenderBox && global != null) {
      final local = box.globalToLocal(global);
      if (box.size.contains(local)) return _pastePoint(_toWorld(local));
    }
    return _pastePoint(_toWorld(_viewport.center(Offset.zero)));
  }

  Vec2 _pastePoint(Offset world) {
    final anchor = widget.pastePreview?.anchor ?? Vec2.zero;
    return anchor + _drawingPoint(world - _offset(anchor));
  }

  _SchematicPainter? get _pastePainter {
    final preview = widget.pastePreview,
        scene = _pasteScene,
        position = _pastePosition;
    if (preview == null || scene == null || position == null) return null;
    return _SchematicPainter(
      scene: scene,
      palette: _canvasPalette,
      pan: _pan + _offset(position - preview.anchor) * _zoom,
      zoom: _zoom,
      showGrid: false,
      selectedIds: preview.selectedIds,
      previewPositions: const {},
      marquee: null,
      wireStart: null,
      hoverPort: null,
      pointerWorld: null,
      placingKind: null,
      terminalSides: widget.terminalSides,
      wireMode: false,
      selectedWire: null,
      onSelectDevice: (_) {},
      images: _images,
      drawingPreview: null,
      placingCorner: null,
      overlay: true,
    );
  }

  Offset _toWorld(Offset local) => (local - _pan) / _zoom;

  String? get _hoveredContinuationId {
    final pointer = _lastPointerGlobal;
    final box = context.findRenderObject();
    if (pointer == null || box is! RenderBox || !box.hasSize) return null;
    final local = box.globalToLocal(pointer);
    if (!box.size.contains(local)) return null;
    final id = _deviceAt(_toWorld(local));
    return _scene.markers.containsKey(id) ? id : null;
  }

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
    _clearHover();
    if (_viewport.isEmpty) return;
    void update() {
      _fitted = true;
      _zoom = sheetFitScale(_viewport, _pageSize);
      _pan = Offset(
        (_viewport.width - _pageSize.width * _zoom) / 2 -
            _paperBounds.left * _zoom,
        (_viewport.height - _pageSize.height * _zoom) / 2 -
            _paperBounds.top * _zoom,
      );
    }

    if (rebuild) {
      setState(update);
    } else {
      update();
    }
    _scheduleStats();
  }

  void _revealContinuation(ContinuationMarker marker, {double? zoom}) {
    setState(() {
      _cancelGesture();
      _selectedWire = null;
      if (zoom != null) _zoom = _clampZoom(zoom);
      final point = _offset(marker.position);
      if (zoom != null || !_worldViewport.contains(point)) {
        _fitted = false;
        _pan = _viewport.center(Offset.zero) - point * _zoom;
      }
      _continuationFocus = marker.position;
    });
    _focus.requestFocus();
    _scheduleStats();
  }

  void _revealDevice(Device device, double zoom) {
    setState(() {
      _cancelGesture();
      _selectedWire = null;
      _fitted = false;
      _zoom = _clampZoom(zoom);
      _pan = _viewport.center(Offset.zero) - _offset(device.position) * _zoom;
      _deviceFocus = device.position;
    });
    _focus.requestFocus();
    _scheduleStats();
  }

  void _reset() {
    _clearHover();
    if (_viewport.isEmpty) return;
    setState(() {
      _fitted = false;
      _zoom = 1;
      _pan = Offset(
        (_viewport.width - _pageSize.width) / 2 - _paperBounds.left,
        (_viewport.height - _pageSize.height) / 2 - _paperBounds.top,
      );
    });
    _scheduleStats();
  }

  double _clampZoom(double zoom) {
    final fit = sheetFitScale(_viewport, _pageSize);
    return zoom.clamp(
      math.min(_zoom, math.min(.15, fit / 2)),
      math.max(_zoom, math.max(3.5, fit * 8)),
    );
  }

  void _zoomAt(Offset anchor, double factor) {
    _clearHover();
    final world = _toWorld(anchor);
    final next = _clampZoom(_zoom * factor);
    if (next == _zoom) {
      setState(_clearHover);
      return;
    }
    setState(() {
      _fitted = false;
      _zoom = next;
      _pan = anchor - world * next;
    });
    _scheduleStats();
  }

  void _dismissHover() {
    if (mounted &&
        (_hoverLocal != null ||
            _hoverReference != null ||
            _hoverContinuationLink != null)) {
      setState(_clearHover);
    }
  }

  void _clearHover() {
    _overrideDrawingCursor?.call(false);
    _hoverReference = null;
    _hoverContinuationLink = null;
    _hoverWire = null;
    _hoverInfoDevice = null;
    _hoverLocal = null;
  }

  void _cancelGesture() {
    _middleDoubleClick.reset();
    _pressedReference = null;
    _pressedContinuationLink = null;
    _deviceFocus = null;
    _continuationFocus = null;
    _panZoomActive = false;
    _lastDeviceTap = null;
    _tapDevice = null;
    _clearHover();
    _activePointer = null;
    _drag = _DragKind.none;
    _marquee = null;
    _marqueeSelection = {};
    _previewPositions = {};
    _moveOrigin = {};
    _drawingPreview = null;
    _wireStart = null;
    _hoverPort = null;
    _baseSelection = {};
    _downLocal = null;
    _downWorld = null;
    _panOrigin = null;
    _pointerWorld = null;
    _hoverDevice = null;
    _temporaryPanPressed = false;
    _temporaryPanKey = null;
  }

  WireEndpoint? _portAt(Offset point) {
    final radius = 12 / _zoom;
    final candidates = _scene.index.query(
      Rect.fromCircle(center: point, radius: radius + 10),
    );
    WireEndpoint? closest;
    var distance = radius;
    for (final key in candidates) {
      if (!key.startsWith('d:')) continue;
      final device = _scene.devices[key.substring(2)]!;
      if (device.mode == OccurrenceMode.reference) continue;
      for (final port in geometryFor(device).ports) {
        final position = _portPosition(device, port.id, _previewPositions);
        final d = (position - point).distance;
        if (d <= distance) {
          distance = d;
          closest = TerminalRef(deviceId: device.id, portId: port.id);
        }
      }
    }
    for (final marker in _scene.markers.values) {
      final d = (_offset(marker.position) - point).distance;
      if (d <= distance) {
        distance = d;
        closest = ContinuationRef(markerId: marker.id);
      }
    }
    for (final corner in _scene.corners.values) {
      for (final portId in ConnectionCorner.portIds) {
        final d = (_offset(corner.portPosition(portId)!) - point).distance;
        if (d <= distance) {
          distance = d;
          closest = CornerRef(cornerId: corner.id, portId: portId);
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
    for (final marker in _scene.markers.values) {
      if (Rect.fromCenter(
        center: _offset(marker.position),
        width: 32,
        height: 32,
      ).contains(point)) {
        return marker.id;
      }
    }
    for (final corner in _scene.corners.values) {
      final path = corner.path.map(_offset).toList();
      if (distanceToSegment(point, path[0], path[1]) <= tolerance ||
          distanceToSegment(point, path[1], path[2]) <= tolerance) {
        return corner.id;
      }
    }
    String? result;
    var topmost = -1;
    for (final key in candidates) {
      if (!key.startsWith('d:')) continue;
      final id = key.substring(2);
      final order = _scene.deviceOrder[id]!;
      final device = _scene.devices[id]!;
      final hit =
          device.symbol is TerminalSymbolSpec
              ? TerminalSymbolGeometry(
                sides: (device.symbol as TerminalSymbolSpec).sides,
                center: device.position,
                quarterTurns: device.rotation ~/ 90,
              ).hitTest(Vec2(point.dx, point.dy), tolerance: tolerance)
              : _scene.deviceBounds[id]!.inflate(tolerance).contains(point);
      if (order > topmost && hit) {
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
    if (event.kind == PointerDeviceKind.mouse) {
      _lastPointerGlobal = event.position;
    }
    if (_activePointer != null) return;
    _middleDoubleClick.down(event);
    final reference =
        _canInteract &&
                HardwareKeyboard.instance.isControlPressed &&
                event.buttons == kPrimaryMouseButton &&
                widget.onFollowDevice != null
            ? _referenceAt(_toWorld(event.localPosition))
            : null;
    final continuationLink =
        _canInteract &&
                HardwareKeyboard.instance.isControlPressed &&
                event.buttons == kPrimaryMouseButton
            ? _continuationLinkAt(_toWorld(event.localPosition))
            : null;
    _deviceFocus = null;
    _continuationFocus = null;
    _tapDevice = null;
    setState(_clearHover);
    _focus.requestFocus();
    final world = _toWorld(event.localPosition);
    _pointerWorld = world;
    _downLocal = event.localPosition;
    _downWorld = world;
    _activePointer = event.pointer;

    if (reference != null || continuationLink != null) {
      _pressedReference = reference;
      _pressedContinuationLink = continuationLink;
      return;
    }

    if (event.buttons & (kMiddleMouseButton | kSecondaryMouseButton) != 0 ||
        widget.mode == CanvasMode.pan ||
        _temporaryPanPressed) {
      setState(() {
        _drag = _DragKind.pan;
        _panOrigin = _pan;
      });
      return;
    }

    if (widget.pastePreview != null) return;

    if (!widget.readOnly &&
        widget.mode == CanvasMode.place &&
        widget.placingKind != null) {
      widget.onPlaceDevice(widget.placingKind!, _snap(world));
      return;
    }

    if (!widget.readOnly && widget.mode == CanvasMode.corner) {
      widget.onPlaceCorner?.call(_snap(world));
      return;
    }

    if (!widget.readOnly && widget.mode == CanvasMode.continuation) return;

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
      if (!widget.readOnly &&
          widget.mode == CanvasMode.select &&
          !HardwareKeyboard.instance.isShiftPressed &&
          (_scene.devices.containsKey(deviceId) ||
              _scene.markers.containsKey(deviceId) ||
              _scene.graphics.containsKey(deviceId) ||
              _scene.corners.containsKey(deviceId))) {
        _tapDevice = deviceId;
      } else {
        _lastDeviceTap = null;
      }
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
            else if (_scene.corners.containsKey(id))
              id: _scene.corners[id]!.position
            else if (_scene.markers.containsKey(id))
              id: _scene.markers[id]!.position
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
    _middleDoubleClick.move(event);
    if (event.kind == PointerDeviceKind.mouse) {
      _lastPointerGlobal = event.position;
    }
    if (event.pointer != _activePointer) return;
    if ((_pressedReference != null || _pressedContinuationLink != null) &&
        (event.localPosition - _downLocal!).distance > 3) {
      _pressedReference = null;
      _pressedContinuationLink = null;
    }
    final world = _toWorld(event.localPosition);
    setState(() {
      _pointerWorld = world;
      switch (_drag) {
        case _DragKind.pan:
          _fitted = false;
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
              else if (key.startsWith('m:') || key.startsWith('c:'))
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
    if (event.kind == PointerDeviceKind.mouse) {
      _lastPointerGlobal = event.position;
    }
    if (event.pointer != _activePointer) return;
    final fit = event is PointerUpEvent && _middleDoubleClick.up(event);
    final reference = _pressedReference;
    final continuationLink = _pressedContinuationLink;
    _pressedReference = null;
    _pressedContinuationLink = null;
    if (reference != null || continuationLink != null) {
      setState(() {
        _activePointer = null;
        _lastDeviceTap = null;
      });
      if (HardwareKeyboard.instance.isControlPressed &&
          event is PointerUpEvent &&
          (event.localPosition - _downLocal!).distance < 3) {
        if (reference != null &&
            identical(_referenceAt(_toWorld(event.localPosition)), reference)) {
          widget.onFollowDevice?.call(reference.sourceId, reference.target);
        } else if (continuationLink != null &&
            _continuationLinkAt(_toWorld(event.localPosition)) ==
                continuationLink) {
          widget.onFollowContinuation?.call(continuationLink);
        }
      }
      return;
    }
    final placePaste =
        !widget.readOnly &&
        widget.pastePreview != null &&
        _drag == _DragKind.none &&
        (event.localPosition - _downLocal!).distance < 3;
    final placeContinuation =
        !widget.readOnly &&
        widget.mode == CanvasMode.continuation &&
        _drag == _DragKind.none &&
        (event.localPosition - _downLocal!).distance < 3;
    String? editDevice;
    if (_tapDevice != null &&
        _drag == _DragKind.move &&
        _previewPositions.isEmpty &&
        (event.localPosition - _downLocal!).distance < 3) {
      final previous = _lastDeviceTap;
      if (previous != null &&
          previous.$1 == _tapDevice &&
          (event.localPosition - previous.$2).distance <= kDoubleTapSlop &&
          event.timeStamp - previous.$3 <= kDoubleTapTimeout) {
        editDevice = _tapDevice;
        _lastDeviceTap = null;
      } else {
        _lastDeviceTap = (_tapDevice!, event.localPosition, event.timeStamp);
      }
    } else {
      _lastDeviceTap = null;
    }
    _tapDevice = null;
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
        final markers = {
          for (final e in changed.entries)
            if (_scene.markers.containsKey(e.key)) e.key: e.value,
        };
        if (widget.onMoveSelection != null) {
          widget.onMoveSelection!(
            devices: devices,
            graphics: graphics,
            markers: markers,
            corners: {
              for (final e in changed.entries)
                if (_scene.corners.containsKey(e.key)) e.key: e.value,
            },
          );
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
    if (fit) _fit();
    if (placePaste) {
      widget.onPlacePaste?.call(_pastePoint(_toWorld(event.localPosition)));
    }
    if (placeContinuation) {
      widget.onPlaceContinuation?.call(
        _drawingPoint(_toWorld(event.localPosition)),
      );
    }
    if (editDevice != null) _editObject(editDevice);
  }

  void _editObject(String id) {
    if (!_canInteract) return;
    if (_scene.markers.containsKey(id)) {
      widget.onEditContinuation?.call(id);
    } else if (_scene.devices.containsKey(id)) {
      widget.onEditDevice?.call(id);
    } else if (_scene.graphics.containsKey(id) ||
        _scene.corners.containsKey(id)) {
      widget.onEditDrawingObject?.call(id);
    }
  }

  void _pointerHover(PointerHoverEvent event) {
    _lastPointerGlobal = event.position;
    if (_continuationFocus != null || _deviceFocus != null) {
      setState(() {
        _continuationFocus = null;
        _deviceFocus = null;
      });
    }
    final hoverAllowed =
        widget.mode == CanvasMode.select &&
        widget.pastePreview == null &&
        !_hasActiveGesture;
    final world = _toWorld(event.localPosition);
    final reference =
        _canInteract && widget.onFollowDevice != null
            ? _referenceAt(world)
            : null;
    final continuationLink = _canInteract ? _continuationLinkAt(world) : null;
    final device = _deviceAt(world) ?? _graphicAt(world);
    final infoDevice =
        reference == null && hoverAllowed && _scene.devices.containsKey(device)
            ? device
            : null;
    final wire =
        reference == null && hoverAllowed && infoDevice == null
            ? _wireAt(world)
            : null;
    final hoverLocal =
        wire != null || infoDevice != null ? event.localPosition : null;
    final port =
        !widget.readOnly && widget.mode == CanvasMode.wire
            ? _portAt(world)
            : null;
    final tracksPointer =
        !widget.readOnly &&
        (widget.pastePreview != null ||
            widget.mode == CanvasMode.wire ||
            widget.mode == CanvasMode.corner ||
            widget.mode == CanvasMode.place);
    if ((!tracksPointer || world == _pointerWorld) &&
        wire == _hoverWire &&
        infoDevice == _hoverInfoDevice &&
        hoverLocal == _hoverLocal &&
        reference == _hoverReference &&
        continuationLink == _hoverContinuationLink &&
        device == _hoverDevice &&
        _samePort(port, _hoverPort)) {
      return;
    }
    setState(() {
      _hoverWire = wire;
      _hoverReference = reference;
      _hoverContinuationLink = continuationLink;
      _hoverInfoDevice = infoDevice;
      _hoverLocal = hoverLocal;
      _pointerWorld = world;
      _hoverDevice = device;
      _hoverPort = port;
      _overrideDrawingCursor?.call(_linkCursor);
    });
  }

  DeviceCrossReference? _referenceAt(Offset world) {
    final ids =
        _scene.index
            .query(Rect.fromCircle(center: world, radius: 1))
            .where((key) => key.startsWith('r:'))
            .map((key) => key.substring(2))
            .toList()
          ..sort(
            (a, b) => _scene.deviceOrder[b]!.compareTo(_scene.deviceOrder[a]!),
          );
    for (final id in ids) {
      if (_zoom < .45 && !widget.selectedIds.contains(id)) continue;
      for (final reference
          in _scene.references[id] ?? const <DeviceCrossReference>[]) {
        if (reference.bounds.contains(world)) return reference;
      }
    }
    return null;
  }

  String? _continuationLinkAt(Offset world) {
    if (widget.onFollowContinuation == null) return null;
    for (final link in _scene.continuationReferences.values) {
      final marker = _scene.markers[link.markerId]!;
      if (link.bounds.contains(world) ||
          Rect.fromCenter(
            center: _offset(marker.position),
            width: 32,
            height: 32,
          ).contains(world)) {
        return link.markerId;
      }
    }
    return null;
  }

  bool _modifiersChanged(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight) {
      if (mounted) setState(() {});
      _overrideDrawingCursor?.call(_linkCursor);
    }
    return false;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent && event.logicalKey == _temporaryPanKey) {
      setState(() {
        _temporaryPanPressed = false;
        _temporaryPanKey = null;
      });
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent || ModalRoute.isCurrentOf(context) == false) {
      return KeyEventResult.ignored;
    }
    final command = widget.shortcuts.commandFor(event);
    if (command == EditorCommand.temporaryPan) {
      setState(() {
        _clearHover();
        _temporaryPanPressed = true;
        _temporaryPanKey = event.logicalKey;
      });
      return KeyEventResult.handled;
    }
    if (command == EditorCommand.editProperties) {
      if (_canInteract && widget.selectedIds.length == 1) {
        _editObject(widget.selectedIds.single);
      }
      return KeyEventResult.handled;
    }
    if (command == EditorCommand.followContinuation) {
      if (_canInteract) {
        final selected =
            widget.selectedIds.where(_scene.markers.containsKey).toList();
        final hovered = _hoveredContinuationId;
        final id = hovered ?? (selected.length == 1 ? selected.single : null);
        if (id != null) widget.onFollowContinuation?.call(id);
      }
      return KeyEventResult.handled;
    }
    if (command == EditorCommand.cancelTool) {
      setState(() {
        _cancelGesture();
        _selectedWire = null;
      });
      // The workspace also returns the active tool to selection.
      return KeyEventResult.ignored;
    }
    if (!widget.readOnly &&
        command == EditorCommand.deleteSelection &&
        _selectedWire != null) {
      widget.onDeleteWire(_selectedWire!);
      setState(() => _selectedWire = null);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  MouseCursor get _cursor {
    if (widget.pastePreview != null) return SystemMouseCursors.precise;
    if (_drag == _DragKind.pan) return SystemMouseCursors.grabbing;
    if (_linkCursor) {
      return SystemMouseCursors.click;
    }
    if (widget.mode == CanvasMode.pan || _temporaryPanPressed) {
      return SystemMouseCursors.grab;
    }
    if (!widget.readOnly &&
        (widget.mode == CanvasMode.corner ||
            widget.mode == CanvasMode.continuation ||
            widget.mode == CanvasMode.place ||
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
          _clearHover();
          final previous = _viewport;
          _viewport = nextSize;
          if (_fitted) {
            _fit(rebuild: false);
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
        return CanvasHoverOverlay(
          contextIdentity: widget.documentIdentity ?? widget.controller,
          info:
              _hoverInfoDevice == null || _scene.resolver == null
                  ? null
                  : resolveDeviceHoverInfo(
                    resolver: _scene.resolver!,
                    sheetId: widget.sheet.id,
                    deviceId: _hoverInfoDevice!,
                  ),
          localPosition: _hoverLocal,
          maxWidth: 360,
          maxLines: 12,
          suppressed:
              widget.pastePreview != null ||
              widget.mode != CanvasMode.select ||
              _hasActiveGesture,
          child: WireHoverOverlay(
            contextIdentity: widget.documentIdentity ?? widget.controller,
            info:
                _hoverWire == null || _scene.resolver == null
                    ? null
                    : resolveWireRouteHoverInfo(
                      resolver: _scene.resolver!,
                      sheet: widget.sheet,
                      wireId: _hoverWire!,
                    ),
            localPosition: _hoverLocal,
            active: _hoverLocal != null,
            suppressed:
                widget.pastePreview != null ||
                widget.mode != CanvasMode.select ||
                _hasActiveGesture,
            child: Semantics(
              label: '${widget.sheet.type.label}, ${widget.sheet.name}',
              hint:
                  widget.readOnly
                      ? 'Náhled pouze ke čtení. Kliknutím vyberte přístroj. '
                          'Kolečkem přibližujte, tažením s ${widget.shortcuts.labelFor(EditorCommand.temporaryPan)} posouvejte výkres.'
                      : 'Dvojklikem nebo ${widget.shortcuts.labelFor(EditorCommand.editProperties)} upravíte vybraný objekt. '
                          '${widget.shortcuts.labelFor(EditorCommand.followContinuation)} přejde na protějšek, '
                          '${widget.shortcuts.labelFor(EditorCommand.fitSheet)} zobrazí celý list. Kolečkem přibližujte. '
                          'Tažením s ${widget.shortcuts.labelFor(EditorCommand.temporaryPan)} posouvejte výkres. '
                          'Nástroj Vodič propojí připojovací body. '
                          '${widget.shortcuts.labelFor(EditorCommand.cancelTool)} zruší rozpracovanou akci.',
              child: Focus(
                focusNode: _focus,
                onKeyEvent: _onKey,
                onFocusChange: (focused) {
                  if (!focused) {
                    setState(() {
                      _clearHover();
                      _temporaryPanPressed = false;
                      _temporaryPanKey = null;
                    });
                  }
                },
                child: MouseRegion(
                  cursor:
                      _linkCursor
                          ? SystemMouseCursors.click
                          : DrawingCursorRegion.cursorOf(
                            context,
                            fallback: _cursor,
                          ),
                  onExit:
                      (_) => setState(() {
                        _clearHover();
                        _pointerWorld = null;
                        _lastPointerGlobal = null;
                        _hoverDevice = null;
                        _hoverPort = null;
                      }),
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _pointerDown,
                    onPointerMove: _pointerMove,
                    onPointerUp: _pointerUp,
                    onPointerCancel: (_) {
                      if (mounted) setState(_cancelGesture);
                    },
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
                    onPointerPanZoomStart: (_) {
                      setState(() {
                        _clearHover();
                        _panZoomActive = true;
                      });
                      _panZoomStartScale = _zoom;
                    },
                    onPointerPanZoomEnd:
                        (_) => setState(() => _panZoomActive = false),
                    onPointerPanZoomUpdate: (event) {
                      if (!mounted) return;
                      final factor =
                          _clampZoom(_panZoomStartScale * event.scale) / _zoom;
                      final anchor = event.localPosition;
                      final world = _toWorld(anchor);
                      setState(() {
                        _clearHover();
                        _fitted = false;
                        _zoom *= factor;
                        _pan = anchor - world * _zoom + event.panDelta;
                      });
                      _scheduleStats();
                    },
                    child: RepaintBoundary(
                      child: CustomPaint(
                        foregroundPainter: _pastePainter,
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
                          placingCorner:
                              !widget.readOnly &&
                                      widget.mode == CanvasMode.corner
                                  ? widget.cornerOrientation
                                  : null,
                          wireStart: _wireStart,
                          hoverPort: _hoverPort,
                          pointerWorld: _pointerWorld,
                          placingKind:
                              !widget.readOnly &&
                                      widget.mode == CanvasMode.place
                                  ? widget.placingKind
                                  : null,
                          terminalSides: widget.terminalSides,
                          wireMode:
                              !widget.readOnly &&
                              widget.mode == CanvasMode.wire,
                          selectedWire: _selectedWire,
                          onSelectDevice:
                              (id) => widget.onSelectionChanged({id}),
                          activeReference: _hoverReference,
                          activeContinuationLink: _hoverContinuationLink,
                        ),
                        child: Stack(
                          clipBehavior: Clip.hardEdge,
                          children: [
                            const SizedBox.expand(),
                            if (_scene.documentPage?.diagnostics.isNotEmpty ??
                                false)
                              Positioned(
                                right: 8,
                                bottom: 8,
                                child: LayoutDiagnostics(
                                  _scene.documentPage!.diagnostics,
                                ),
                              ),
                            if (widget.pastePreview != null)
                              Positioned(
                                left: 12,
                                top: 12,
                                child: IgnorePointer(
                                  child: Card(
                                    child: Padding(
                                      padding: EdgeInsets.all(8),
                                      child: Text(
                                        'Kliknutím vložit · ${widget.shortcuts.labelFor(EditorCommand.cancelTool)} zrušit',
                                        key: ValueKey('clipboard-preview'),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (_continuationFocus != null)
                              Positioned(
                                left:
                                    _continuationFocus!.x * _zoom +
                                    _pan.dx -
                                    22,
                                top:
                                    _continuationFocus!.y * _zoom +
                                    _pan.dy -
                                    22,
                                child: IgnorePointer(
                                  child: Semantics(
                                    label: 'Cíl pokračování · kreslicí fokus',
                                    child: Icon(
                                      Icons.center_focus_strong,
                                      key: const ValueKey('continuation-focus'),
                                      size: 44,
                                      color: widget.palette.selection,
                                    ),
                                  ),
                                ),
                              ),
                            if (_deviceFocus != null)
                              Positioned(
                                left: _deviceFocus!.x * _zoom + _pan.dx - 22,
                                top: _deviceFocus!.y * _zoom + _pan.dy - 22,
                                child: IgnorePointer(
                                  child: Icon(
                                    Icons.center_focus_strong,
                                    key: const ValueKey('device-focus'),
                                    size: 44,
                                    color: widget.palette.selection,
                                  ),
                                ),
                              ),
                          ],
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
    );
  }
}

bool _samePort(WireEndpoint? a, WireEndpoint? b) => a == b;

Offset _offset(Vec2 value) => Offset(value.x, value.y);
Offset _portPosition(
  Device device,
  String portId,
  Map<String, Vec2> positions,
) {
  final actual = worldPortPosition(device, portId);
  final preview = positions[device.id];
  return _offset(preview == null ? actual : actual + preview - device.position);
}

Rect _deviceRect(Device device) {
  final definition = geometryFor(device);
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
  _Scene(this.sheet, this.project) {
    corners.addAll({for (final c in sheet.corners) c.id: c});
    for (final c in corners.values) {
      index.insert(
        'c:${c.id}',
        Rect.fromCenter(center: _offset(c.position), width: 24, height: 24),
      );
    }
    markers.addAll({for (final m in sheet.continuations) m.id: m});
    for (final m in markers.values) {
      index.insert(
        'm:${m.id}',
        Rect.fromCenter(center: _offset(m.position), width: 32, height: 32),
      );
    }
    if (project != null) {
      for (final marker in sheet.continuations) {
        final link = layoutContinuationCrossReference(
          project!,
          sheet,
          marker,
          index: continuations,
        );
        if (link != null) continuationReferences[marker.id] = link;
      }
    }
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
      if (resolver case final r?) {
        final links = layoutDeviceCrossReferences(r, device);
        references[device.id] = links;
        if (links.isNotEmpty) {
          index.insert(
            'r:${device.id}',
            links.map((l) => l.bounds).reduce((a, b) => a.expandToInclude(b)),
          );
        }
      }
    }
    for (final wire in AutoConnect.wires(sheet)) {
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
  final EcadProject? project;
  final Map<String, ContinuationMarker> markers = {};
  final Map<String, ConnectionCorner> corners = {};
  late final ProjectResolver? resolver =
      project == null ? null : ProjectResolver(project!);
  late final ContinuationIndex? continuations =
      project == null ? null : ContinuationIndex(project!);
  late final DocumentPage? documentPage =
      project == null ? null : layoutDocument(project!).firstPageFor(sheet.id);
  late final PreparedFrameLayout frame =
      documentPage?.frame ??
      prepareFrameLayout(
        bindFrame(
          layoutFrameGeometry(
            sheet.paperSizeMm,
            resolveSheetFrame(_standaloneProject, sheet),
          ),
          _standaloneProject,
          sheet,
          FramePageContext(
            number: fullPageDesignation(sheet),
            documentIndex: 1,
            documentCount: 1,
          ),
        ),
      );
  late final EcadProject _standaloneProject = EcadProject(
    id: 'canvas',
    name: '',
    pages: [sheet],
  );
  Component? component(Device d) => resolver?.components[d.componentId];
  String label(Device d) =>
      component(d) == null ? '' : resolver!.fullDesignation(component(d)!);
  String subtitle(Device d) => component(d)?.description ?? '';
  String portLabel(Device d, String id) =>
      project == null ? id : (resolver!.port(d, id)?.label ?? id);
  final Map<String, Device> devices = {};
  final Map<String, List<DeviceCrossReference>> references = {};
  final Map<String, ContinuationCrossReference> continuationReferences = {};
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
    if (positions.isEmpty) {
      return WireRouter.path(
        wire,
        devices,
        markers,
        corners,
      ).map(_offset).toList();
    }
    final after = {
      for (final d in devices.values)
        d.id:
            positions.containsKey(d.id)
                ? d.copyWith(position: positions[d.id])
                : d,
    };
    final afterMarkers = {
      for (final m in markers.values)
        m.id:
            positions.containsKey(m.id)
                ? m.copyWith(position: positions[m.id])
                : m,
    };
    final afterCorners = {
      for (final c in corners.values)
        c.id: c.copyWith(position: positions[c.id]),
    };
    return WireRouter.path(
      WireRouter.follow(
        wire,
        devices,
        after,
        beforeCorners: corners,
        afterCorners: afterCorners,
        beforeMarkers: markers,
        afterMarkers: afterMarkers,
      ),
      after,
      afterMarkers,
      afterCorners,
    ).map(_offset).toList();
  }

  WireTerminal? terminal(WireEndpoint reference, Map<String, Vec2> positions) {
    if (positions.isEmpty) {
      return WireRouter.endpoint(reference, devices, markers, corners);
    }
    return WireRouter.endpoint(
      reference,
      {
        for (final d in devices.values)
          d.id:
              positions.containsKey(d.id)
                  ? d.copyWith(position: positions[d.id])
                  : d,
      },
      {
        for (final m in markers.values)
          m.id:
              positions.containsKey(m.id)
                  ? m.copyWith(position: positions[m.id])
                  : m,
      },
      {
        for (final c in corners.values)
          c.id: c.copyWith(position: positions[c.id]),
      },
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
    required this.terminalSides,
    required this.wireMode,
    required this.selectedWire,
    required this.onSelectDevice,
    required this.images,
    required this.drawingPreview,
    required this.placingCorner,
    this.overlay = false,
    this.activeReference,
    this.activeContinuationLink,
  });

  final _Scene scene;
  final CanvasPalette palette;
  final Offset pan;
  final double zoom;
  final bool showGrid;
  final Set<String> selectedIds;
  final Map<String, Vec2> previewPositions;
  final Rect? marquee;
  final WireEndpoint? wireStart;
  final WireEndpoint? hoverPort;
  final Offset? pointerWorld;
  final DeviceKind? placingKind;
  final Set<PortSide> terminalSides;
  final bool wireMode;
  final String? selectedWire;
  final ValueChanged<String> onSelectDevice;
  final DrawingImageCache images;
  final DrawingElement? drawingPreview;
  final CornerOrientation? placingCorner;
  final bool overlay;
  final DeviceCrossReference? activeReference;
  final String? activeContinuationLink;

  @override
  void paint(Canvas canvas, Size size) {
    if (overlay) {
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..color = const Color(0xbbffffff),
      );
    } else {
      canvas.drawRect(Offset.zero & size, Paint()..color = palette.background);
    }
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
    if (!overlay) _drawPage(canvas, visibleRect);

    final visible = scene.index.query(visibleRect.inflate(50));
    if (previewPositions.isNotEmpty) {
      visible.addAll(
        previewPositions.keys
            .where(
              (id) =>
                  !scene.markers.containsKey(id) &&
                  !scene.corners.containsKey(id),
            )
            .map((id) => '${scene.graphics.containsKey(id) ? 'g' : 'd'}:$id'),
      );
      for (final wire in scene.wires.values) {
        if (previewPositions.containsKey(wire.from.ownerId) ||
            previewPositions.containsKey(wire.to.ownerId)) {
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
    final visibleDevices =
        visible
            .where((key) => key.startsWith('d:') || key.startsWith('r:'))
            .map((key) => key.substring(2))
            .toSet()
            .toList()
          ..sort(
            (a, b) => scene.deviceOrder[a]!.compareTo(scene.deviceOrder[b]!),
          );
    for (final id in visibleDevices) {
      final device = scene.devices[id]!;
      _drawDevice(canvas, device);
    }

    for (final marker in scene.markers.values) {
      final pos = _offset(previewPositions[marker.id] ?? marker.position);
      final selected = selectedIds.contains(marker.id);
      final color = selected ? palette.selection : palette.ink;
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      final angle = switch (marker.direction) {
        PortSide.right => 0.0,
        PortSide.left => math.pi,
        PortSide.bottom => math.pi / 2,
        PortSide.top => -math.pi / 2,
      };
      canvas.rotate(angle);
      final glyph =
          Path()
            ..moveTo(0, 0)
            ..lineTo(marker.glyph == ContinuationGlyph.earth ? 14 : 20, 0);
      if (marker.glyph == ContinuationGlyph.earth) {
        glyph
          ..moveTo(14, -10)
          ..lineTo(14, 10)
          ..moveTo(19, -7)
          ..lineTo(19, 7)
          ..moveTo(24, -4)
          ..lineTo(24, 4);
      } else {
        glyph
          ..moveTo(13, -6)
          ..lineTo(20, 0)
          ..lineTo(13, 6);
      }
      canvas.drawPath(
        glyph,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      canvas.restore();
      canvas.drawCircle(pos, 3, Paint()..color = color);
      if (selected) {
        canvas.drawRect(
          Rect.fromCenter(center: pos, width: 32, height: 32),
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke,
        );
      }
      final link = scene.project?.continuationLinkById(marker.linkId);
      final targets =
          scene.project == null
              ? ''
              : scene.continuations!
                  .targets(sheetId: scene.sheet.id, markerId: marker.id)
                  .map((t) => fullPageDesignation(t.sheet))
                  .toSet()
                  .join(', ');
      _label(
        canvas,
        '${link?.label ?? ''} → ${targets.isEmpty ? 'bez cíle' : targets}',
        pos + const Offset(14, -10),
        color: color,
        size: 10,
        background: palette.paper,
      );
      if (marker.id == activeContinuationLink) {
        final bounds = scene.continuationReferences[marker.id]!.bounds;
        canvas.drawLine(
          bounds.bottomLeft,
          bounds.bottomRight,
          Paint()
            ..color = palette.selection
            ..strokeWidth = 1 / zoom,
        );
      }
    }
    for (final c in scene.corners.values) {
      final corner = c.copyWith(position: previewPositions[c.id]);
      _drawCorner(canvas, corner, selectedIds.contains(c.id));
    }
    for (final key in visible) {
      if (!key.startsWith('w:')) continue;
      final id = key.substring(2);
      final wire = scene.wires[id]!;
      if (wire.isAutomatic && previewPositions.isNotEmpty) continue;
      final moved =
          previewPositions.containsKey(wire.from.ownerId) ||
          previewPositions.containsKey(wire.to.ownerId);
      final points =
          moved ? scene.route(wire, previewPositions) : scene.wirePoints[id]!;
      _drawWire(canvas, points, id == selectedWire);
    }
    if (previewPositions.isNotEmpty) {
      final previewSheet = scene.sheet.copyWith(
        devices: [
          for (final d in scene.devices.values)
            d.copyWith(position: previewPositions[d.id]),
        ],
        continuations: [
          for (final m in scene.markers.values)
            m.copyWith(position: previewPositions[m.id]),
        ],
        corners: [
          for (final c in scene.corners.values)
            c.copyWith(position: previewPositions[c.id]),
        ],
      );
      for (final wire in AutoConnect.automaticWires(previewSheet)) {
        _drawWire(canvas, scene.route(wire, previewPositions), false);
      }
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

    if (placingCorner != null && pointerWorld != null) {
      _drawCorner(
        canvas,
        ConnectionCorner(
          id: 'preview',
          position: Vec2(
            pointerWorld!.dx,
            pointerWorld!.dy,
          ).snapped(SchematicCanvas.gridSpacing),
          orientation: placingCorner!,
        ),
        true,
      );
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
      if (placingKind == DeviceKind.terminal) {
        paintTerminalSymbol(
          canvas,
          TerminalSymbolGeometry(sides: terminalSides),
          ink: palette.selection,
          paper: palette.paper,
        );
      } else {
        _paintSymbol(canvas, placingKind!, palette.selection, palette.paper);
      }
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
    if (overlay) canvas.restore();
  }

  void _drawCorner(Canvas canvas, ConnectionCorner corner, bool selected) {
    final color = selected ? palette.selection : palette.wire;
    canvas.drawPath(
      _pathFromPoints(corner.path.map(_offset).toList()),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );
    if (selected) {
      canvas.drawRect(
        Rect.fromCenter(
          center: _offset(corner.position),
          width: 26,
          height: 26,
        ),
        Paint()
          ..color = palette.selection
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 / zoom,
      );
    }
    if (wireMode) {
      for (final port in ConnectionCorner.portIds) {
        canvas.drawCircle(
          _offset(corner.portPosition(port)!),
          3.5,
          Paint()
            ..color = palette.selection
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1 / zoom,
        );
      }
    }
  }

  void _drawPage(Canvas canvas, Rect visible) {
    final transform = SheetTransform(scene.sheet);
    final bounds = transform.paperBoundsUnits;
    final page = Rect.fromLTWH(bounds.x, bounds.y, bounds.width, bounds.height);
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
    if (showGrid) _drawGrid(canvas, visible.intersect(page));
    canvas.save();
    canvas.translate(bounds.x, bounds.y);
    canvas.scale(1 / transform.mmPerUnit);
    paintFrameLayout(canvas, scene.frame, color: palette.ink);
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
    final definition = geometryFor(device);
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
    if (device.symbol case TerminalSymbolSpec(:final sides)) {
      paintTerminalSymbol(
        canvas,
        TerminalSymbolGeometry(sides: sides),
        ink: selected ? palette.selection : palette.ink,
        paper: palette.paper,
      );
    } else if (device.kind case final kind?) {
      _paintSymbol(
        canvas,
        kind,
        selected ? palette.selection : palette.ink,
        palette.paper,
        dcSupply: RegExp(
          r'\bDC\b',
          caseSensitive: false,
        ).hasMatch(scene.subtitle(device)),
        showText: zoom >= 0.45 || selected,
      );
    } else {
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset.zero,
          width: definition.width,
          height: definition.height,
        ),
        Paint()..color = palette.paper,
      );
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset.zero,
          width: definition.width,
          height: definition.height,
        ),
        Paint()
          ..color = palette.ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3,
      );
    }
    canvas.restore();

    // At overview scale these labels would be below five logical pixels.
    // Geometry remains visible and accessible; selecting a device restores its
    // full detail regardless of zoom.
    if (zoom >= 0.45 || selected) {
      final terminal = device.symbol is TerminalSymbolSpec;
      final labels =
          terminal
              ? TerminalSymbolGeometry(
                sides: (device.symbol as TerminalSymbolSpec).sides,
                center: Vec2(position.dx, position.dy),
                quarterTurns: device.rotation ~/ 90,
              ).labelLayout()
              : null;
      final textX = labels?.designationOrigin.x ?? bounds.right + 14;
      _label(
        canvas,
        terminal && scene.component(device) != null
            ? scene.resolver!.terminalStripLabel(scene.component(device)!)
            : scene.label(device),
        Offset(textX, labels?.designationOrigin.y ?? position.dy - 17),
        color: selected ? palette.selection : palette.ink,
        size: 11,
        weight: FontWeight.w600,
        background: palette.paper,
      );
      final subtitle =
          terminal
              ? scene.component(device)?.terminal?.number ?? ''
              : scene.subtitle(device).isNotEmpty
              ? scene.subtitle(device)
              : (device.kind == null
                  ? 'Obecný blok'
                  : _deviceLabel(device.kind!));
      _label(
        canvas,
        subtitle,
        Offset(textX, labels?.numberOrigin.y ?? position.dy + 1),
        color: palette.muted,
        size: 8.5,
        background: palette.paper,
      );
      for (final reference
          in scene.references[device.id] ?? const <DeviceCrossReference>[]) {
        final rect = reference.bounds.shift(
          position - _offset(device.position),
        );
        final active = identical(reference, activeReference);
        _label(
          canvas,
          reference.text,
          rect.topLeft,
          color: active ? palette.selection : palette.muted,
          size: 8.5,
          background: palette.paper,
        );
        if (active) {
          canvas.drawLine(
            rect.bottomLeft,
            rect.bottomRight,
            Paint()
              ..color = palette.selection
              ..strokeWidth = 1 / zoom,
          );
        }
      }
    }

    if (scene.resolver case final resolver?) {
      for (final annotation in layoutPortAnnotations(resolver, device)) {
        final delta = position - _offset(device.position);
        _label(
          canvas,
          annotation.text,
          annotation.bounds.topLeft + delta,
          color: palette.ink,
          size: 9,
          background: palette.paper,
        );
      }
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
            '${scene.label(device)}:${scene.portLabel(device, port.id)}',
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
            '${scene.label(device)}, '
            '${(device.kind == null ? 'Obecný blok' : _deviceLabel(device.kind!))}'
            '${scene.subtitle(device).isEmpty ? '' : ', ${scene.subtitle(device)}'}',
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
  double? maxWidth,
}) {
  final painter = _TextLayouts.get(text, color, size, weight, letterSpacing);
  if (maxWidth != null && painter.width > maxWidth) {
    canvas.save();
    canvas.translate(position.dx, position.dy);
    canvas.scale(maxWidth / painter.width);
    painter.paint(canvas, Offset.zero);
    canvas.restore();
    return;
  }
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
          height: 1.25,
        ),
      ),
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
    if (kind == DeviceKind.terminal) {
      paintTerminalSymbol(
        canvas,
        TerminalSymbolGeometry(sides: const {PortSide.top, PortSide.bottom}),
        ink: palette.ink,
        paper: palette.paper,
        strokeWidth: 1.4 / scale,
      );
      return;
    }
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
