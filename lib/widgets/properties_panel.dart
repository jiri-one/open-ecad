import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import '../app/controller.dart';
import '../services/keyboard_shortcuts.dart';
import '../app/theme.dart';
import '../editor/schematic_canvas.dart';
import 'graphic_inspector.dart';
import 'sheet_types.dart';
import 'inventory.dart';
import 'occurrence_dialog.dart';
import 'sheet_settings.dart';
import 'terminal_editor.dart';
import 'continuation_editor.dart';

Future<void> showDeviceProperties(
  BuildContext context,
  EditorController owner,
  String deviceId,
) {
  final generation = owner.documentGeneration;
  final sheetId = owner.sheet.id;
  return showDialog<void>(
    context: context,
    builder:
        (context) => AlertDialog(
          title: const Text('Vlastnosti přístroje'),
          content: SizedBox(
            width: 540,
            height: 620,
            child: ListenableBuilder(
              listenable: owner,
              builder: (context, _) {
                final device =
                    owner.isDocumentCurrent(generation)
                        ? owner.project.sheetById(sheetId)?.deviceById(deviceId)
                        : null;
                if (device == null) {
                  return const Text('Původní přístroj již není otevřen.');
                }
                return _DeviceInspector(
                  key: ValueKey((deviceId, owner.project.revision)),
                  device: device,
                  controller: owner,
                  sheetId: sheetId,
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Zavřít'),
            ),
          ],
        ),
  );
}

class PropertiesPanel extends StatelessWidget {
  const PropertiesPanel({
    super.key,
    required this.controller,
    this.onEditContinuation,
    this.onAddContinuation,
    this.onAddContinuationPeer,
    this.onFollowContinuation,
    this.shortcuts = const KeyboardShortcuts.defaults(),
  });
  final EditorController controller;
  final KeyboardShortcuts shortcuts;
  final ValueChanged<String>? onEditContinuation, onAddContinuationPeer;
  final VoidCallback? onAddContinuation;
  final void Function(String, ContinuationTarget?)? onFollowContinuation;
  @override
  Widget build(BuildContext context) {
    final selected = controller.selectedDevices;
    final graphics = controller.selectedGraphics;
    final selectionCount = selected.length + graphics.length;
    final c = EcadColors.of(context);
    if (controller.selectedMarkers.length == 1) {
      final marker = controller.selectedMarkers.single;
      final targets = ContinuationIndex(
        controller.project,
      ).targets(sheetId: controller.sheet.id, markerId: marker.id);
      return ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(
            controller.project.continuationLinkById(marker.linkId)?.label ??
                'Chybějící síť',
          ),
          Text('Síť: ${marker.linkId}'),
          OutlinedButton(
            onPressed:
                () =>
                    onEditContinuation != null
                        ? onEditContinuation!(marker.id)
                        : editContinuation(context, controller, marker: marker),
            child: const Text('Upravit pokračování'),
          ),
          OutlinedButton(
            onPressed:
                onFollowContinuation == null
                    ? null
                    : () => onFollowContinuation!(marker.id, null),
            child: Text(
              'Přejít na protějšek${shortcuts.labelFor(EditorCommand.followContinuation).isEmpty ? '' : ' · ${shortcuts.labelFor(EditorCommand.followContinuation)}'}',
            ),
          ),
          OutlinedButton(
            onPressed:
                onAddContinuationPeer == null
                    ? null
                    : () => onAddContinuationPeer!(marker.id),
            child: const Text('Další marker této sítě…'),
          ),
          if (targets.isEmpty)
            const Text(
              'Odkaz nemá protějšek. Přidejte další marker do této sítě.',
            ),
          for (final target in targets)
            ContinuationTargetTile(
              target: target,
              onTap:
                  onFollowContinuation == null
                      ? null
                      : () => onFollowContinuation!(marker.id, target),
            ),
          OutlinedButton(
            onPressed: controller.deleteSelection,
            child: const Text('Odstranit marker'),
          ),
        ],
      );
    }
    if (controller.selectedPlacements.length == 1) {
      return _MountingInspector(
        key: ValueKey(
          '${controller.documentSessionId}-${controller.project.revision}-${controller.selectedPlacements.single.id}',
        ),
        controller: controller,
        placement: controller.selectedPlacements.single,
      );
    }
    if (selectionCount == 0) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 20),
          const Icon(Icons.touch_app_outlined, size: 32),
          const SizedBox(height: 16),
          const Text(
            'Vyberte objekt',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Kliknutím na přístroj nebo grafiku otevřete jeho vlastnosti.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: c.muted, height: 1.7),
          ),
          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 20),
          const Text(
            'AKTUÁLNÍ LIST',
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          _info('Název', controller.sheet.name),
          _info('Přístroje', '${controller.sheet.devices.length}'),
          _info('Vodiče', '${AutoConnect.wires(controller.sheet).length}'),
          _info('Grafika', '${controller.sheet.graphics.length}'),
          _info('Mřížka', '10 jednotek'),
          OutlinedButton(
            onPressed: () => editSheetSettings(context, controller),
            child: const Text('Číslo, papír a vlastnosti listu'),
          ),
          if (controller.sheet.type == SheetType.cabinetLayout) ...[
            OutlinedButton(
              onPressed: () => editMountingView(context, controller),
              child: const Text('Nastavit montážní pohled'),
            ),
            OutlinedButton(
              onPressed: () => showMountPlacementDialog(context, controller),
              child: const Text('Umístit komponentu'),
            ),
          ],
          if (electricalSheet(controller.sheet)) ...[
            OutlinedButton(
              onPressed: () => showOccurrenceDialog(context, controller),
              child: const Text('Další zobrazení komponenty'),
            ),
            OutlinedButton(
              onPressed: onAddContinuation ?? controller.setContinuationTool,
              child: const Text('Vložit pokračovací odkaz'),
            ),
          ],
          const SizedBox(height: 10),
          const Text('Typ listu', style: TextStyle(fontSize: 11)),
          const SizedBox(height: 8),
          SheetTypeSelector(
            value: controller.sheet.type,
            onChanged:
                controller.showingProposal ? null : controller.setSheetType,
          ),
          const SizedBox(height: 20),
          Text(
            'Shift + kliknutí rozšíří výběr. Tažením prázdnou plochou vyberete více přístrojů.',
            style: TextStyle(fontSize: 11, height: 1.65, color: c.muted),
          ),
        ],
      );
    }
    if (selectionCount > 1) {
      return ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(
            '$selectionCount objektů ve výběru',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: controller.rotateSelection,
                icon: const Icon(Icons.rotate_right, size: 16),
                label: const Text('Otočit'),
              ),
              OutlinedButton.icon(
                onPressed: controller.duplicateSelection,
                icon: const Icon(Icons.copy_outlined, size: 16),
                label: const Text('Duplikovat'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          for (final device in selected.take(100))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: SymbolPreview(
                kind: device.kind ?? DeviceKind.terminal,
                palette: c.canvasPalette,
                size: 28,
              ),
              title: Text(
                controller.resolver.fullDesignation(
                  controller.componentFor(device),
                ),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                device.kind == null
                    ? 'Obecný blok'
                    : SymbolCatalog.definitionFor(device.kind!).label,
                style: const TextStyle(fontSize: 10),
              ),
              onTap: () => controller.select({device.id}),
            ),
          for (final graphic in graphics.take(100))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                graphic.kind == DrawingKind.text
                    ? Icons.text_fields
                    : Icons.draw_outlined,
                size: 22,
              ),
              title: Text(
                graphic.kind == DrawingKind.text
                    ? graphic.text
                    : graphicKindLabel(graphic.kind),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => controller.select({graphic.id}),
            ),
          if (selected.length > 100 || graphics.length > 100)
            const Text('Zobrazeno prvních 100 objektů každého typu.'),
        ],
      );
    }
    if (graphics.isNotEmpty) {
      return GraphicInspector(
        key: ValueKey(
          '${controller.documentSessionId}-${graphics.single.id}-${controller.project.revision}',
        ),
        graphic: graphics.single,
        controller: controller,
      );
    }
    return _DeviceInspector(
      key: ValueKey(
        '${controller.documentSessionId}-${selected.single.id}-${controller.project.revision}',
      ),
      device: selected.single,
      controller: controller,
      sheetId: controller.sheet.id,
    );
  }

  Widget _info(String title, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(title, style: const TextStyle(fontSize: 11)),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class _DeviceInspector extends StatefulWidget {
  const _DeviceInspector({
    super.key,
    required this.device,
    required this.controller,
    required this.sheetId,
  });
  final Device device;
  final EditorController controller;
  final String sheetId;
  @override
  State<_DeviceInspector> createState() => _DeviceInspectorState();
}

class _DeviceInspectorState extends State<_DeviceInspector> {
  late final component = widget.controller.componentFor(widget.device);
  late final designation = TextEditingController(
    text:
        component.reference?.localDesignation ??
        component.terminal?.number ??
        component.designation,
  );
  late final description = TextEditingController(text: component.description);
  late final x = TextEditingController(text: decimal(widget.device.position.x));
  late final y = TextEditingController(text: decimal(widget.device.position.y));
  String? error;
  @override
  void dispose() {
    for (final c in [designation, description, x, y]) {
      c.dispose();
    }
    super.dispose();
  }

  void save() {
    try {
      final next = widget.device.copyWith(
        position: Vec2(
          double.parse(x.text.replaceAll(',', '.')),
          double.parse(y.text.replaceAll(',', '.')),
        ),
      );
      final ok = widget.controller.execute([
        UpdateComponent(
          component.copyWith(
            designation:
                component.reference == null && component.terminal == null
                    ? designation.text.trim()
                    : component.legacyDesignation,
            reference:
                component.reference == null
                    ? null
                    : ComponentReference(
                      context: component.reference!.context,
                      localDesignation: designation.text,
                    ),
            terminal: component.terminal?.copyWith(
              number: designation.text.trim(),
            ),
            description: description.text.trim(),
          ),
        ),
        UpdateDevice(widget.sheetId, next),
      ], 'Vlastnosti upraveny');
      if (!ok) setState(() => error = widget.controller.status);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.controller, device = widget.device;
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Text(
          app.resolver.fullDesignation(component),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        Text(component.electrical!.functionById(device.functionId)!.name),
        Text(
          app.resolver.isMainFunction(device)
              ? 'Hlavní funkce'
              : 'Vedlejší funkce',
          key: const ValueKey('device-function-role'),
        ),
        if (!device.isMainFunction)
          OutlinedButton(
            key: const ValueKey('set-main-function'),
            onPressed: () => app.setMainFunction(widget.sheetId, device.id),
            child: const Text('Nastavit jako hlavní funkci'),
          ),
        Text(
          'Na tomto listu: ${app.resolver.relativeDesignation(component, app.project.sheetById(widget.sheetId)!.structure)}',
        ),
        const SizedBox(height: 16),
        formField(
          component.terminal == null ? 'Označení' : 'Číslo svorky',
          designation,
        ),
        const SizedBox(height: 12),
        formField('Popis', description),
        const SizedBox(height: 12),
        formField('Poloha X', x),
        const SizedBox(height: 12),
        formField('Poloha Y', y),
        if (error != null) Text(error!),
        const SizedBox(height: 16),
        FilledButton(onPressed: save, child: const Text('Použít vlastnosti')),
        OutlinedButton(
          onPressed: () => editComponent(context, app, component: component),
          child: const Text('Komponenta, artikl a dostupnost…'),
        ),
        if (component.articleId case final id?)
          TextButton(
            onPressed:
                () => editArticle(
                  context,
                  app,
                  article: app.project.articleById(id),
                ),
            child: const Text('Upravit přiřazený artikl…'),
          ),
        OutlinedButton(
          onPressed: () => editPorts(context, app, device),
          child: const Text('Funkce, blok a vývody…'),
        ),
        if (device.symbol is TerminalSymbolSpec)
          OutlinedButton(
            onPressed: () async {
              final ok = await editTerminalDirections(
                context,
                app,
                device,
                widget.sheetId,
              );
              if (mounted && ok == false) setState(() => error = app.status);
            },
            child: const Text('Směry svorky (1–4)…'),
          ),
        OutlinedButton(
          onPressed: () => showOccurrenceDialog(context, app, replace: device),
          child: const Text('Přiřadit jinému kusu / funkci…'),
        ),
        OutlinedButton(
          onPressed:
              () => showOccurrenceDialog(
                context,
                app,
                component: component,
                sheetId: widget.sheetId,
              ),
          child: const Text('Další zobrazení tohoto kusu…'),
        ),
        for (final port in app.resolver.ports(device))
          ListTile(
            dense: true,
            title: Text('${port.label} · ${port.signal}'),
            subtitle: Text(
              port.connectable ? 'Zapojovací vývod' : 'Referenční vývod',
            ),
          ),
        for (final occurrence in app.resolver.otherOccurrences(device))
          TextButton(
            onPressed: () {
              if (ModalRoute.of(context) is DialogRoute) Navigator.pop(context);
              app.navigateToDevice(occurrence.sheet.id, occurrence.device.id);
            },
            child: Text(
              '${app.resolver.isMainFunction(occurrence.device) ? 'Hlavní' : 'Vedlejší'} funkce: ${fullPageDesignation(occurrence.sheet)} · ${occurrence.sheet.name} · X ${decimal(occurrence.device.position.x)} / Y ${decimal(occurrence.device.position.y)}',
            ),
          ),
        OutlinedButton.icon(
          onPressed:
              () => app.execute([
                UpdateDevice(
                  widget.sheetId,
                  device.copyWith(rotation: (device.rotation + 90) % 360),
                ),
              ], 'Zobrazení otočeno'),
          icon: const Icon(Icons.rotate_right),
          label: const Text('Otočit o 90°'),
        ),
        OutlinedButton.icon(
          onPressed:
              () => app.execute([
                DeleteDevices(widget.sheetId, {device.id}),
              ], 'Zobrazení odstraněno'),
          icon: const Icon(Icons.delete_outline),
          label: const Text('Odstranit pouze zobrazení'),
        ),
      ],
    );
  }
}

class _MountingInspector extends StatefulWidget {
  const _MountingInspector({
    super.key,
    required this.controller,
    required this.placement,
  });
  final EditorController controller;
  final MountingPlacement placement;
  @override
  State<_MountingInspector> createState() => _MountingInspectorState();
}

class _MountingInspectorState extends State<_MountingInspector> {
  late final x = TextEditingController(
    text: decimal(widget.placement.centerMm.x),
  );
  late final y = TextEditingController(
    text: decimal(widget.placement.centerMm.y),
  );
  String? error;
  @override
  void dispose() {
    x.dispose();
    y.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.controller, p = widget.placement;
    final c = app.project.componentById(p.componentId)!;
    final size = app.resolver.dimensionsFor(c);
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Text(
          app.resolver.fullDesignation(c),
          style: const TextStyle(fontSize: 20),
        ),
        Text(
          'Montážní poloha · ${decimal(size.width)} × ${decimal(size.height)} mm · ${p.rotation.toInt()}°',
        ),
        const SizedBox(height: 14),
        formField('Střed X mm', x),
        const SizedBox(height: 14),
        formField('Střed Y mm', y),
        if (error != null) Text(error!),
        FilledButton(
          onPressed: () {
            try {
              if (!app.updatePlacement(
                p.copyWith(
                  centerMm: Vec2(
                    double.parse(x.text.replaceAll(',', '.')),
                    double.parse(y.text.replaceAll(',', '.')),
                  ),
                ),
              )) {
                setState(() => error = app.status);
              }
            } catch (e) {
              setState(() => error = '$e');
            }
          },
          child: const Text('Použít polohu'),
        ),
        OutlinedButton(
          onPressed: app.rotateSelection,
          child: const Text('Otočit o 90°'),
        ),
        OutlinedButton(
          onPressed: () => editComponent(context, app, component: c),
          child: const Text('Komponenta a rozměry…'),
        ),
        OutlinedButton(
          onPressed: app.deleteSelection,
          child: const Text('Odstranit fyzické umístění'),
        ),
        const Text(
          'Polohu sdílí všechny pohledy této montážní plochy. Kus v projektu zůstává.',
        ),
      ],
    );
  }
}
