// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';

Device syntheticDevice({
  required String id,
  required DeviceKind kind,
  required Vec2 position,
  double rotation = 0,
}) => Device(
  id: id,
  componentId: 'component_$id',
  functionId: 'function_$id',
  position: position,
  rotation: rotation,
  symbol: BuiltinSymbolSpec(
    kind: kind,
    bindings: {
      for (final p in definitionFor(kind).ports) p.id: 'terminal_${id}_${p.id}',
    },
  ),
);

Component syntheticComponent(Device d) => Component(
  id: d.componentId,
  designation: '-${d.id}',
  electrical: ElectricalModel(
    terminals: [
      for (final p in geometryFor(d).ports)
        ComponentTerminal(id: terminalIdFor(d, p.id)!, designation: p.id),
    ],
    functions: [
      ComponentFunction(
        id: d.functionId,
        name: 'Synthetic function',
        terminalIds: [
          for (final p in geometryFor(d).ports) terminalIdFor(d, p.id)!,
        ],
      ),
    ],
  ),
);

EcadProject syntheticProject({
  required String id,
  required String name,
  required List<Sheet> pages,
}) => EcadProject(
  id: id,
  name: name,
  components: [
    for (final s in pages)
      for (final d in s.devices) syntheticComponent(d),
  ],
  pages: pages,
);
