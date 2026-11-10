import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/app/workspace_controller.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/project_persistence.dart';

EcadProject continuationProject({
  int sameSheet = 1,
  int otherSheet = 0,
  bool distant = false,
}) {
  final seed = createBuiltinComponent(
    componentId: 'component',
    deviceId: 'symbol',
    kind: DeviceKind.supply,
    designation: '-G1',
    position: const Vec2(950, 700),
  );
  return EcadProject(
    id: 'project',
    name: 'Synthetic continuation editor',
    components: [seed.component],
    continuationLinks: const [
      ContinuationLink(id: 'network', label: 'SIGNAL'),
      ContinuationLink(id: 'second-network', label: 'RETURN'),
    ],
    pages: [
      Sheet(
        id: 'source-sheet',
        number: '01',
        name: 'Source sheet',
        width: 2400,
        height: 1600,
        structure: StructureContext(
          functionPath: ['CONTROL'],
          locationPath: ['LEFT'],
        ),
        documentCode: 'SCH',
        devices: [seed.device],
        continuations: [
          const ContinuationMarker(
            id: 'source',
            linkId: 'network',
            position: Vec2(1200, 800),
          ),
          for (var i = 0; i < sameSheet; i++)
            ContinuationMarker(
              id: 'same-$i',
              linkId: 'network',
              position:
                  distant
                      ? Vec2(2200, 1400 - i * 100)
                      : Vec2(1350, 800 + i * 100),
            ),
        ],
        wires: [
          Wire(
            id: 'wire',
            from: const TerminalRef(deviceId: 'symbol', portId: 'out'),
            to: const ContinuationRef(markerId: 'source'),
            waypoints: const [Vec2(1000, 800)],
          ),
        ],
      ),
      Sheet(
        id: 'target-sheet',
        number: '01',
        name: 'Destination sheet',
        structure: StructureContext(
          functionPath: ['CONTROL'],
          locationPath: ['RIGHT'],
        ),
        documentCode: 'SCH',
        continuations: [
          for (var i = 0; i < otherSheet; i++)
            ContinuationMarker(
              id: 'other-$i',
              linkId: 'network',
              position: Vec2(950, 650 - i * 100),
            ),
          const ContinuationMarker(
            id: 'return',
            linkId: 'second-network',
            position: Vec2(200, 200),
          ),
        ],
      ),
    ],
  );
}

class ContinuationMemoryPersistence extends ProjectPersistence {
  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async => 'memory';
}

EditorController continuationController([EcadProject? project]) =>
    EditorController(
      initialProject: project ?? continuationProject(),
      persistence: ContinuationMemoryPersistence(),
    );

Future<WorkspaceController> mountContinuations(
  WidgetTester tester,
  EditorController app, {
  bool panel = false,
}) async {
  tester.view.physicalSize = const Size(1700, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(app.dispose);
  await tester.pumpWidget(OpenEcadApp(controller: app));
  await tester.pumpAndSettle();
  if (!panel) {
    await tester.tap(find.byTooltip('Zobrazit asistenta'));
    await tester.pumpAndSettle();
  }
  app.viewport.reset();
  await tester.pump();
  return tester
      .widget<EditorWorkspace>(find.byType(EditorWorkspace))
      .workspace!;
}

Offset continuationPoint(
  WidgetTester tester,
  EditorController app,
  Vec2 point,
) =>
    tester.getTopLeft(find.byType(SchematicCanvas)) +
    app.viewport.worldToLocal(point)!;

Future<void> selectContinuation(
  WidgetTester tester,
  EditorController app,
) async {
  await tester.tapAt(
    continuationPoint(
      tester,
      app,
      app.sheet.continuationById('source')!.position,
    ),
  );
  await tester.pump();
}

Finder continuationField(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);

Future<void> continuationClick(WidgetTester tester, String text) async {
  final found = find.text(text).last;
  await tester.ensureVisible(found);
  await tester.tap(found);
  await tester.pumpAndSettle();
}

Future<void> unmountContinuations(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 500));
}
