// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';

EcadProject wiringScene({
  CornerOrientation orientation = CornerOrientation.topLeft,
  bool withCorner = false,
}) {
  const position = Vec2(400, 300);
  final devices = <Device>[];
  final components = <Component>[];
  for (final (id, direction) in [('a', orientation.a), ('b', orientation.b)]) {
    final terminal = ComponentTerminal(id: 'terminal_$id', designation: '1');
    final function = ComponentFunction(
      id: 'function_$id',
      name: 'Přívod',
      terminalIds: [terminal.id],
    );
    final component = Component(
      id: 'component_$id',
      designation: '-${id.toUpperCase()}',
      electrical: ElectricalModel(terminals: [terminal], functions: [function]),
    );
    components.add(component);
    devices.add(
      Device(
        id: id,
        componentId: component.id,
        functionId: function.id,
        position: position + direction * 150,
        symbol: PortBlockSpec(
          width: 20,
          height: 20,
          ports: [
            BlockPort(
              id: 'p',
              terminalId: terminal.id,
              side:
                  direction.x > 0
                      ? PortSide.left
                      : direction.x < 0
                      ? PortSide.right
                      : direction.y > 0
                      ? PortSide.top
                      : PortSide.bottom,
              fraction: .5,
            ),
          ],
        ),
      ),
    );
  }
  return EcadProject(
    id: 'synthetic',
    name: 'Synthetic corner',
    components: components,
    pages: [
      Sheet(
        id: 's',
        name: 'Synthetic',
        number: '1',
        showFrame: false,
        devices: devices,
        corners: [
          if (withCorner)
            ConnectionCorner(
              id: 'c',
              position: position,
              orientation: orientation,
            ),
        ],
      ),
    ],
  );
}
