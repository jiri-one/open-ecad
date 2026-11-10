// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/workspace_controller.dart';
import 'sheet_settings.dart';
import 'frame_settings.dart';
import 'frame_settings_draft.dart';

class SheetContextMenu extends StatelessWidget {
  const SheetContextMenu({
    super.key,
    required this.controller,
    required this.sheet,
    required this.onRenameSheet,
    this.workspace,
    this.child,
    this.tooltip,
  });

  final EditorController controller;
  final Sheet sheet;
  final WorkspaceController? workspace;
  final VoidCallback onRenameSheet;
  final Widget? child;
  final String? tooltip;

  List<PopupMenuEntry<String>> _items() {
    return [
      const PopupMenuItem(value: 'open', child: Text('Otevřít list')),
      if (workspace != null)
        const PopupMenuItem(
          value: 'newTab',
          child: Text('Otevřít v novém tabu'),
        ),
      if (workspace?.tabs.contains(
            SheetTab(controller.documentSessionId, sheet.id),
          ) ==
          true)
        const PopupMenuItem(value: 'closeTab', child: Text('Zavřít tab')),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'rename', child: Text('Přejmenovat list…')),
      const PopupMenuItem(
        value: 'settings',
        child: Text('Číslo, papír a vlastnosti…'),
      ),
      const PopupMenuItem(
        value: 'frame',
        child: Text('Rámeček a údaje listu…'),
      ),
      PopupMenuItem(
        value: 'delete',
        enabled: controller.project.pages.length > 1,
        child: const Text('Odstranit list…'),
      ),
      const PopupMenuDivider(),
      for (final type in SheetType.values)
        CheckedPopupMenuItem(
          value: type.name,
          checked: sheet.type == type,
          child: Text(type.label),
        ),
    ];
  }

  void _select(BuildContext context, String action) {
    if (!context.mounted ||
        controller.project.sheetById(sheet.id) == null ||
        (workspace != null &&
            workspace!.document(controller.documentSessionId) != controller)) {
      return;
    }
    if (action == 'closeTab') {
      workspace?.closeTab(SheetTab(controller.documentSessionId, sheet.id));
      return;
    }
    if (workspace == null) {
      controller.setSheet(sheet.id);
    } else {
      workspace!.openSheet(controller, sheet.id, newTab: action == 'newTab');
    }
    switch (action) {
      case 'open':
      case 'newTab':
        return;
      case 'rename':
        onRenameSheet();
      case 'settings':
        editSheetSettings(context, controller);
      case 'frame':
        editFrameSettings(context, controller, sheetId: sheet.id);
      case 'delete':
        confirmDeleteSheet(context, controller);
      default:
        controller.setSheetType(SheetType.values.byName(action));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (child == null) {
      FrameEditGuard? menuGuard;
      return PopupMenuButton<String>(
        onOpened:
            () => menuGuard = FrameEditGuard(controller, sheetId: sheet.id),
        tooltip: tooltip ?? 'Možnosti listu ${fullPageDesignation(sheet)}',
        onSelected: (action) {
          if (menuGuard?.current ?? false) _select(context, action);
        },
        itemBuilder: (_) => _items(),
        icon: const Icon(Icons.more_vert, size: 16),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) async {
        final guard = FrameEditGuard(controller, sheetId: sheet.id);
        final overlay =
            Overlay.of(context).context.findRenderObject() as RenderBox;
        final action = await showMenu<String>(
          context: context,
          position: RelativeRect.fromSize(
            overlay.globalToLocal(details.globalPosition) & Size.zero,
            overlay.size,
          ),
          items: _items(),
        );
        if (action != null && context.mounted && guard.current) {
          _select(context, action);
        }
      },
      child: child,
    );
  }
}
