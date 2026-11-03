// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/services/project_export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connection_corner_ui_test.dart' as ui;
import 'wiring_fixtures.dart';

void main() {
  for (final drag in [false, true]) {
    testWidgets(
      '${drag ? 'dragging' : 'placing'} a corner cuts a manual through-wire in the canvas, model and export',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        ui.screen(tester);
        final base = wiringScene();
        final sheet = base.pages.single;
        final project = base.copyWith(
          pages: [
            sheet.copyWith(
              corners: [
                if (drag)
                  const ConnectionCorner(
                    id: 'corner',
                    position: Vec2(400, 340),
                  ),
              ],
              devices: [
                for (final (index, device) in sheet.devices.indexed)
                  device.copyWith(
                    position: Vec2(index == 0 ? 200 : 600, 300),
                    symbol: PortBlockSpec(
                      width: 20,
                      height: 20,
                      ports: [
                        BlockPort(
                          id: 'p',
                          terminalId: 'terminal_${device.id}',
                          side: index == 0 ? PortSide.right : PortSide.left,
                          fraction: .5,
                        ),
                      ],
                    ),
                  ),
              ],
              wires: [
                Wire(
                  id: 'manual',
                  from: const TerminalRef(deviceId: 'a', portId: 'p'),
                  to: const TerminalRef(deviceId: 'b', portId: 'p'),
                ),
              ],
            ),
          ],
        );
        final app = EditorController(
          initialProject: project,
          persistence: ui.MemoryPersistence(),
        );
        addTearDown(app.dispose);
        await tester.pumpWidget(OpenEcadApp(controller: app));
        app.viewport.reset();
        await tester.pumpAndSettle();
        if (drag) {
          await tester.dragFrom(
            ui.at(tester, const Vec2(400, 340)),
            const Offset(0, -40),
          );
        } else {
          app.setCornerTool(CornerOrientation.topLeft);
          await tester.pump();
          await tester.tapAt(ui.at(tester, const Vec2(400, 300)));
        }
        await tester.pump();
        final corner = app.sheet.corners.single;
        final wire = app.sheet.wires.single;
        expect(wire.from, const TerminalRef(deviceId: 'b', portId: 'p'));
        expect(wire.to, CornerRef(cornerId: corner.id, portId: 'a'));
        expect(
          ProjectExportService().svg(app.project),
          isNot(contains('points="210,300 590,300"')),
        );
        await ui.shortcut(tester, LogicalKeyboardKey.keyZ);
        expect(app.sheet.toJson(), project.pages.single.toJson());
        await ui.shortcut(tester, LogicalKeyboardKey.keyY);
        expect(app.sheet.corners, hasLength(1));
        expect(app.sheet.wires.single.to, isA<CornerRef>());
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
