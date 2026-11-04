import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import '../app/controller.dart';
import '../app/navigation_press.dart';
import '../editor/sheet_viewport.dart';
import '../editor/schematic_canvas.dart' show CanvasMode;
import '../services/report_layout.dart';
import '../services/document_layout.dart';
import '../editor/layout_diagnostics.dart';
import '../app/theme.dart';
import 'inventory.dart';
import 'diagnostic_text.dart';
import 'sheet_settings.dart';

class ReportView extends StatefulWidget {
  const ReportView({
    super.key,
    required this.app,
    this.showControls = true,
    this.isNavigationCurrent,
  });
  final EditorController app;
  final bool showControls;
  final bool Function()? isNavigationCurrent;
  @override
  State<ReportView> createState() => _ReportViewState();
}

class _ReportViewState extends State<ReportView> {
  EcadProject? snapshot;
  String? sheetId;
  late ReportLayout layout;
  List<DocumentPage> documentPages = const [];
  String? layoutError;
  int index = 0;
  final transformation = SheetViewportController();
  final _surfaceKey = GlobalKey();
  final _activePointers = <int>{};
  List<ReportNavigationLink> _links = const [];
  ReportNavigationLink? _hoveredLink;
  ({
    ReportNavigationLink link,
    Offset position,
    int pointer,
    int pageIndex,
    NavigationPress guard,
  })?
  _pressedLink;
  double _surfaceScale = 1;
  Size? _hoverViewport;
  bool get _canNavigate =>
      widget.app.mode == CanvasMode.select &&
      !widget.app.showingProposal &&
      widget.app.pastePreview == null;

  void _clearHover() => _hoveredLink = null;
  void _dismissHover() {
    if (mounted && _hoveredLink != null) setState(_clearHover);
  }

  bool _modifiersChanged(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight) {
      if (mounted) setState(() {});
    }
    return false;
  }

  ReportNavigationLink? _linkAt(Offset global) {
    if (!_canNavigate) return null;
    final surface = _surfaceKey.currentContext?.findRenderObject();
    if (surface is! RenderBox || !surface.hasSize) return null;
    final local = surface.globalToLocal(global);
    if (!surface.size.contains(local)) return null;
    final point = local / _surfaceScale;
    return _links.where((l) => l.bounds.contains(point)).firstOrNull;
  }

  void _pointerDown(PointerDownEvent event) {
    _pressedLink?.guard.dispose();
    _pressedLink = null;
    final link =
        _activePointers.isEmpty &&
                event.buttons == kPrimaryMouseButton &&
                HardwareKeyboard.instance.isControlPressed
            ? _linkAt(event.position)
            : null;
    if (link != null) {
      FocusScope.of(context).unfocus();
      FocusManager.instance.applyFocusChangesIfNeeded();
    }
    _pressedLink =
        link == null
            ? null
            : (
              link: link,
              position: event.position,
              pointer: event.pointer,
              pageIndex: index,
              guard: NavigationPress(
                widget.app,
                context,
                isActive: widget.isNavigationCurrent,
              ),
            );
    _activePointers.add(event.pointer);
    _dismissHover();
  }

  void _pointerUp(PointerEvent event) {
    if (!mounted) return;
    _activePointers.remove(event.pointer);
    final pressed = _pressedLink;
    final current = pressed?.guard.current ?? false;
    pressed?.guard.dispose();
    _pressedLink = null;
    if (pressed == null ||
        !current ||
        !identical(widget.app, pressed.guard.owner) ||
        event is! PointerUpEvent ||
        pressed.pointer != event.pointer ||
        !HardwareKeyboard.instance.isControlPressed ||
        (event.position - pressed.position).distance >= 3 ||
        index != pressed.pageIndex ||
        _linkAt(event.position)?.target != pressed.link.target) {
      return;
    }
    widget.app.navigateToDevice(
      pressed.link.target.sheet.id,
      pressed.link.target.device.id,
    );
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_modifiersChanged);
    FocusManager.instance.addListener(_dismissHover);
    _bindNavigation();
  }

  @override
  void dispose() {
    _pressedLink?.guard.dispose();
    HardwareKeyboard.instance.removeHandler(_modifiersChanged);
    FocusManager.instance.removeListener(_dismissHover);
    widget.app.viewport.unbindNavigation(this);
    transformation.removeListener(_zoomChanged);
    transformation.dispose();
    super.dispose();
  }

  void _bindNavigation() {
    transformation.addListener(_zoomChanged);
    widget.app.viewport.bindNavigation(
      this,
      hasActiveGesture: () => _activePointers.isNotEmpty,
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
    setState(_clearHover);
    widget.app.viewport.reportZoom(transformation.value.getMaxScaleOnAxis());
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    if (!identical(snapshot, app.project) || sheetId != app.sheet.id) {
      _clearHover();
      _pressedLink?.guard.dispose();
      _pressedLink = null;
      snapshot = app.project;
      sheetId = app.sheet.id;
      final document = layoutDocument(app.project);
      documentPages =
          document.pages.where((p) => p.sheet.id == app.sheet.id).toList();
      layoutError = documentPages.first.layoutError;
      if (layoutError == null) {
        layout = document.reports[app.sheet.id]!;
        index = index.clamp(0, layout.pages.length - 1);
      }
    }
    if (layoutError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(layoutError!, textAlign: TextAlign.center),
            TextButton(
              onPressed: () => editSheetSettings(context, app),
              child: const Text('Vlastnosti sestavy'),
            ),
          ],
        ),
      );
    }
    final page = layout.pages[index];
    final documentPage = documentPages[index];
    _links = layoutReportNavigationLinks(app.resolver, layout, page);
    if (!_canNavigate) _clearHover();
    return Column(
      children: [
        if (widget.showControls ||
            layout.pages.length > 1 ||
            documentPage.diagnostics.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Předchozí strana reportu',
                  onPressed:
                      index == 0
                          ? null
                          : () => setState(() {
                            index--;
                            _clearHover();
                            _pressedLink?.guard.dispose();
                            _pressedLink = null;
                          }),
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('${page.number} · ${index + 1}/${layout.pages.length}'),
                IconButton(
                  tooltip: 'Další strana reportu',
                  onPressed:
                      index + 1 == layout.pages.length
                          ? null
                          : () => setState(() {
                            index++;
                            _clearHover();
                            _pressedLink?.guard.dispose();
                            _pressedLink = null;
                          }),
                  icon: const Icon(Icons.chevron_right),
                ),
                LayoutDiagnostics(documentPage.diagnostics),
                if (widget.showControls)
                  TextButton(
                    onPressed: () => editSheetSettings(context, app),
                    child: const Text('Vlastnosti reportu'),
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
              final scale = transformation.layout(
                constraints.biggest,
                Size(page.sizeMm.width, page.sizeMm.height),
              );
              _surfaceScale = scale;
              return MouseRegion(
                cursor:
                    _hoveredLink != null &&
                            HardwareKeyboard.instance.isControlPressed
                        ? SystemMouseCursors.click
                        : SystemMouseCursors.basic,
                onExit: (_) => _dismissHover(),
                onHover: (event) {
                  final link =
                      _activePointers.isEmpty ? _linkAt(event.position) : null;
                  if (_hoveredLink?.bounds != link?.bounds ||
                      _hoveredLink?.target != link?.target) {
                    setState(() => _hoveredLink = link);
                  }
                },
                child: Listener(
                  onPointerSignal: (_) => _dismissHover(),
                  child: InteractiveViewer(
                    transformationController: transformation,
                    minScale: .5,
                    maxScale: 8,
                    boundaryMargin: const EdgeInsets.all(double.infinity),
                    child: Center(
                      child: OverflowBox(
                        minWidth: page.sizeMm.width * scale,
                        maxWidth: page.sizeMm.width * scale,
                        minHeight: page.sizeMm.height * scale,
                        maxHeight: page.sizeMm.height * scale,
                        child: Listener(
                          key: _surfaceKey,
                          onPointerDown: _pointerDown,
                          onPointerMove: (event) {
                            if (_pressedLink != null &&
                                (event.position - _pressedLink!.position)
                                        .distance >=
                                    3) {
                              _pressedLink?.guard.dispose();
                              _pressedLink = null;
                            }
                          },
                          onPointerUp: _pointerUp,
                          onPointerCancel: _pointerUp,
                          child: CustomPaint(
                            key: const ValueKey('report-surface'),
                            painter: _ReportPainter(
                              documentPage,
                              _hoveredLink?.bounds,
                              app.appearance,
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
        if (layout.data.diagnostics.isNotEmpty)
          SizedBox(
            height: 95,
            child: ListView(
              children: [
                for (final issue in layout.data.diagnostics)
                  ListTile(
                    dense: true,
                    title: Text(diagnosticText(app.project, issue)),
                    onTap: () {
                      if (issue.componentId case final id?) {
                        editComponent(
                          context,
                          app,
                          component: app.project.componentById(id),
                        );
                      } else if (issue.articleId case final id?) {
                        editArticle(
                          context,
                          app,
                          article: app.project.articleById(id),
                        );
                      }
                    },
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ReportPainter extends CustomPainter {
  const _ReportPainter(this.documentPage, this.activeLink, this.appearance);
  final DocumentPage documentPage;
  final EcadAppearance appearance;
  final Rect? activeLink;
  ReportPage get page => documentPage.report!;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / page.sizeMm.width);
    final palette = EcadColors.forAppearance(appearance).canvasPalette;
    paintReportPage(
      canvas,
      page,
      activeLink: activeLink,
      frame: documentPage.frame,
      paper: palette.paper,
      ink: palette.highContrast ? palette.ink : null,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ReportPainter oldDelegate) =>
      !identical(documentPage, oldDelegate.documentPage) ||
      appearance != oldDelegate.appearance ||
      activeLink != oldDelegate.activeLink;
}
