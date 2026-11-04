import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

class DesktopWindow {
  static bool get enabled => _enabled;
  static bool _enabled = false;

  static Future<void> initialize() async {
    if (kIsWeb ||
        !{
          TargetPlatform.linux,
          TargetPlatform.windows,
          TargetPlatform.macOS,
        }.contains(defaultTargetPlatform)) {
      return;
    }
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'Open ECAD',
        minimumSize: Size(960, 640),
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
    );
    _enabled = true;
    await windowManager.show();
    await windowManager.focus();
  }

  static Widget dragArea(Widget child) =>
      enabled ? DragToMoveArea(child: child) : child;
}

class DesktopWindowFrame extends StatefulWidget {
  const DesktopWindowFrame({super.key, required this.child});
  final Widget child;

  @override
  State<DesktopWindowFrame> createState() => _DesktopWindowFrameState();
}

class _DesktopWindowFrameState extends State<DesktopWindowFrame>
    with WindowListener {
  bool maximized = false, fullScreen = false;

  @override
  void initState() {
    super.initState();
    if (DesktopWindow.enabled) {
      windowManager.addListener(this);
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final nextMaximized = await windowManager.isMaximized();
    final nextFullScreen = await windowManager.isFullScreen();
    if (!mounted) return;
    setState(() {
      maximized = nextMaximized;
      fullScreen = nextFullScreen;
    });
  }

  @override
  void onWindowMaximize() => _refresh();
  @override
  void onWindowUnmaximize() => _refresh();
  @override
  void onWindowEnterFullScreen() => _refresh();
  @override
  void onWindowLeaveFullScreen() => _refresh();

  @override
  void dispose() {
    if (DesktopWindow.enabled) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      DesktopWindow.enabled
          ? DragToResizeArea(
            resizeEdgeSize: 4,
            enableResizeEdges: maximized || fullScreen ? const [] : null,
            child: widget.child,
          )
          : widget.child;
}

class DesktopWindowControls extends StatefulWidget {
  const DesktopWindowControls({super.key});

  @override
  State<DesktopWindowControls> createState() => _DesktopWindowControlsState();
}

class _DesktopWindowControlsState extends State<DesktopWindowControls>
    with WindowListener {
  bool maximized = false;

  @override
  void initState() {
    super.initState();
    if (DesktopWindow.enabled) {
      windowManager.addListener(this);
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final value = await windowManager.isMaximized();
    if (mounted) setState(() => maximized = value);
  }

  @override
  void onWindowMaximize() => _refresh();
  @override
  void onWindowUnmaximize() => _refresh();

  @override
  void dispose() {
    if (DesktopWindow.enabled) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!DesktopWindow.enabled) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _button(Icons.remove, 'Minimalizovat', windowManager.minimize),
        _button(
          maximized ? Icons.filter_none : Icons.crop_square,
          maximized ? 'Obnovit velikost okna' : 'Maximalizovat',
          maximized ? windowManager.unmaximize : windowManager.maximize,
        ),
        _button(Icons.close, 'Zavřít okno', windowManager.close, close: true),
      ],
    );
  }

  Widget _button(
    IconData icon,
    String label,
    VoidCallback action, {
    bool close = false,
  }) => Tooltip(
    message: label,
    child: SizedBox(
      width: 36,
      height: 40,
      child: IconButton(
        style: IconButton.styleFrom(
          shape: const RoundedRectangleBorder(),
          hoverColor:
              close ? Theme.of(context).colorScheme.errorContainer : null,
        ),
        onPressed: action,
        icon: Icon(icon, size: 14, semanticLabel: label),
      ),
    ),
  );
}
