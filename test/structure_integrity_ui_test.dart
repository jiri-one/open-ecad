import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/services/assistant_service.dart';
import 'package:open_ecad/services/project_persistence.dart';

class _MemoryPersistence extends ProjectPersistence {
  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async => 'memory';
}

EditorController controller(EcadProject project) {
  final app = EditorController(
    initialProject: project,
    persistence: _MemoryPersistence(),
  );
  addTearDown(app.dispose);
  return app;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('canvas insertion skips colliding legacy full references', () {
    final context = StructureContext(functionPath: ['TEST']);
    final app = controller(
      EcadProject(
        id: 'project',
        name: 'Synthetic',
        terminalStrips: [
          TerminalStrip(
            id: 'strip',
            reference: ComponentReference(
              context: context,
              localDesignation: 'X1',
            ),
          ),
        ],
        pages: [
          Sheet(id: 'sheet', name: 'Sheet', number: '01', structure: context),
        ],
        components: const [
          Component(id: 'old-coil', designation: '=TEST-K1'),
          Component(id: 'old-terminal', designation: '=TEST-X1:1'),
        ],
      ),
    );
    app.placeDevice(DeviceKind.coil, const Vec2(300, 300));
    expect(app.project.components.last.reference!.localDesignation, 'K2');
    app.placeTerminal(const Vec2(500, 300));
    expect(app.project.components.last.terminal!.number, '2');
    final duplicate = app.duplicateInventoryComponent(
      app.project.components.last,
    );
    expect(duplicate!.terminal!.number, '3');
    expect(app.project.components, hasLength(5));
  });

  test('page insertion skips a collision across different path tuples', () {
    final app = controller(
      EcadProject(
        id: 'project',
        name: 'Synthetic',
        pages: [
          Sheet(
            id: 'sheet',
            name: 'Sheet',
            number: '03',
            structure: StructureContext(locationPath: ['TEST/01']),
          ),
          Sheet(
            id: 'other',
            name: 'Other',
            number: '01/01',
            structure: StructureContext(locationPath: ['TEST']),
          ),
        ],
      ),
    );
    app.addSheet();
    expect(app.project.pages, hasLength(3));
    expect(app.project.pages.last.number, '02');
  });

  test('controller renames 1000 components and their sheet in one undo', () {
    final context = StructureContext(locationPath: ['TEST']);
    final app = controller(
      EcadProject(
        id: 'project',
        name: 'Synthetic',
        pages: [
          Sheet(id: 'sheet', name: 'Sheet', number: '01', structure: context),
        ],
        components: [
          for (var i = 0; i < 1000; i++)
            Component(
              id: 'c$i',
              reference: ComponentReference(
                context: context,
                localDesignation: 'K$i',
              ),
            ),
        ],
      ),
    );
    expect(
      app.renameStructureBranch(StructureAspect.location, ['TEST'], ['OTHER']),
      isTrue,
    );
    expect(
      app.project.components.every(
        (c) => c.reference!.context.locationPath.single == 'OTHER',
      ),
      isTrue,
    );
    app.undo();
    expect(app.project.pages.single.structure, context);
    expect(
      app.project.components.every((c) => c.reference!.context == context),
      isTrue,
    );
    expect(app.canUndo, isFalse);
  });

  test(
    'assistant honors an explicit terminal strip and number in the active context',
    () {
      final context = StructureContext(locationPath: ['CAB']);
      final project = EcadProject(
        id: 'project',
        name: 'Synthetic',
        pages: [
          Sheet(id: 'sheet', name: 'Sheet', number: '01', structure: context),
        ],
      );
      final proposal = AssistantService().propose(
        'Přidej svorku X9:7',
        project: project,
        sheetId: 'sheet',
        insertionPoint: const Vec2(300, 300),
      );
      expect(proposal.canApply, isTrue);
      final result = proposal.preview(project);
      expect(
        ProjectResolver(result).fullDesignation(result.components.single),
        '+CAB-X9:7',
      );
      final next = AssistantService().fromActions(
        [
          {'op': 'insert_device', 'kind': 'terminal', 'designation': '-X9:8'},
        ],
        project: result,
        sheetId: 'sheet',
      );
      expect(next.canApply, isTrue);
      final second = next.preview(result);
      expect(second.terminalStrips, hasLength(1));
      expect(
        ProjectResolver(second).fullDesignation(second.components.last),
        '+CAB-X9:8',
      );
      final duplicate = AssistantService().propose(
        'Přidej svorku X9:7',
        project: second,
        sheetId: 'sheet',
      );
      expect(duplicate.canApply, isFalse);
    },
  );

  test(
    'assistant rejects unsupported terminal references instead of substituting one',
    () {
      final project = EcadProject(
        id: 'project',
        name: 'Synthetic',
        pages: [Sheet(id: 'sheet', name: 'Sheet', number: '01')],
      );
      for (final designation in ['X9', '=F+L-X9:7', 'X9:7:1']) {
        final proposal = AssistantService().fromActions(
          [
            {
              'op': 'insert_device',
              'kind': 'terminal',
              'designation': designation,
            },
          ],
          project: project,
          sheetId: 'sheet',
        );
        expect(proposal.canApply, isFalse, reason: designation);
        expect(proposal.message, contains('X9:7'));
      }
    },
  );

  test(
    'assistant automatic terminal insertion skips a legacy printed collision',
    () {
      final context = StructureContext(functionPath: ['TEST']);
      final project = EcadProject(
        id: 'project',
        name: 'Synthetic',
        terminalStrips: [
          TerminalStrip(
            id: 'strip',
            reference: ComponentReference(
              context: context,
              localDesignation: 'X1',
            ),
          ),
        ],
        components: const [Component(id: 'old', designation: '=TEST-X1:1')],
        pages: [
          Sheet(id: 'sheet', name: 'Sheet', number: '01', structure: context),
        ],
      );
      final proposal = AssistantService().propose(
        'Přidej svorku',
        project: project,
        sheetId: 'sheet',
      );
      expect(proposal.canApply, isTrue);
      expect(proposal.preview(project).components.last.terminal!.number, '2');
    },
  );
}
