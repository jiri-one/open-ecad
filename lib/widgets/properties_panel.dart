import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import '../app/controller.dart';
import '../app/theme.dart';
import '../editor/schematic_canvas.dart';
import 'components.dart';
import 'graphic_inspector.dart';

class PropertiesPanel extends StatelessWidget {
  const PropertiesPanel({super.key, required this.controller});
  final EditorController controller;
  @override
  Widget build(BuildContext context) {
    final selected = controller.selectedDevices;
    final graphics = controller.selectedGraphics;
    final selectionCount = selected.length + graphics.length;
    final c = EcadColors.of(context);
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
          _info('Vodiče', '${controller.sheet.wires.length}'),
          _info('Grafika', '${controller.sheet.graphics.length}'),
          _info('Mřížka', '10 jednotek'),
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
                kind: device.kind,
                palette: c.canvasPalette,
                size: 28,
              ),
              title: Text(
                device.designation,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                SymbolCatalog.definitionFor(device.kind).label,
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
        key: ValueKey('${graphics.single.id}-${controller.project.revision}'),
        graphic: graphics.single,
        controller: controller,
      );
    }
    return _DeviceInspector(
      key: ValueKey('${selected.single.id}-${controller.project.revision}'),
      device: selected.single,
      controller: controller,
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
  });
  final Device device;
  final EditorController controller;
  @override
  State<_DeviceInspector> createState() => _DeviceInspectorState();
}

class _DeviceInspectorState extends State<_DeviceInspector> {
  late final designation = TextEditingController(
    text: widget.device.designation,
  );
  late final description = TextEditingController(
    text: widget.device.description,
  );
  late final rating = TextEditingController(text: widget.device.rating);
  late final x = TextEditingController(
    text: widget.device.position.x.toString(),
  );
  late final y = TextEditingController(
    text: widget.device.position.y.toString(),
  );
  String? error;
  @override
  void dispose() {
    for (final c in [designation, description, rating, x, y]) {
      c.dispose();
    }
    super.dispose();
  }

  void save() {
    final px = double.tryParse(x.text.replaceAll(',', '.'));
    final py = double.tryParse(y.text.replaceAll(',', '.'));
    if (designation.text.trim().isEmpty ||
        px == null ||
        py == null ||
        !px.isFinite ||
        !py.isFinite) {
      setState(() => error = 'Vyplňte označení a platné souřadnice.');
      return;
    }
    widget.controller.updateDevice(
      widget.device.copyWith(
        designation: designation.text.trim(),
        description: description.text.trim(),
        rating: rating.text.trim(),
        position: Vec2(px, py),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = EcadColors.of(context);
    final device = widget.device;
    final definition = SymbolCatalog.definitionFor(device.kind);
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Row(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                border: Border.all(color: c.border),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(
                child: SymbolPreview(
                  kind: device.kind,
                  palette: c.canvasPalette,
                  size: 42,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.designation,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    definition.label,
                    style: TextStyle(fontSize: 11, color: c.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 26),
        _field('Označení', designation),
        _field('Popis', description, lines: 2),
        _field('Parametry', rating),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _field('Poloha X', x)),
            const SizedBox(width: 12),
            Expanded(child: _field('Poloha Y', y)),
          ],
        ),
        Row(
          children: [
            Text(
              'Otočení: ${device.rotation.toInt()}°',
              style: const TextStyle(fontSize: 11),
            ),
            const Spacer(),
            EcadIconButton(
              icon: Icons.rotate_right,
              label: 'Otočit o 90° · R',
              onPressed: widget.controller.rotateSelection,
            ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              error!,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        const SizedBox(height: 14),
        FilledButton(onPressed: save, child: const Text('Použít vlastnosti')),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 18),
        const Text(
          'PŘIPOJOVACÍ BODY',
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 1.1,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        for (final port in definition.ports)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Icon(
                  widget.controller.sheet.wires.any(
                        (w) =>
                            (w.from.deviceId == device.id &&
                                w.from.portId == port.id) ||
                            (w.to.deviceId == device.id &&
                                w.to.portId == port.id),
                      )
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked,
                  size: 15,
                ),
                const SizedBox(width: 9),
                Text(port.label, style: const TextStyle(fontSize: 11)),
                const Spacer(),
                Text(port.id, style: TextStyle(fontSize: 10, color: c.muted)),
              ],
            ),
          ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: widget.controller.deleteSelection,
          icon: const Icon(Icons.delete_outline, size: 16),
          label: const Text('Odstranit přístroj'),
        ),
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: controller,
      minLines: lines,
      maxLines: lines,
      cursorOpacityAnimates: false,
      style: const TextStyle(fontSize: 12),
      onSubmitted: (_) => save(),
      decoration: InputDecoration(labelText: label),
    ),
  );
}
