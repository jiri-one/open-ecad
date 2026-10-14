import 'dart:async';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/ecad_services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ControlledPersistence extends ProjectPersistence {
  Completer<String?>? saveResult;
  Completer<EcadProject?>? openResult;
  Completer<void>? autosaveResult;
  final savedProjects = <EcadProject>[];
  final autosavedProjects = <EcadProject>[];
  final savedSettings = <AiProviderSettings>[];
  int openCalls = 0;

  @override
  Future<String?> save(EcadProject project) {
    savedProjects.add(project);
    return saveResult?.future ?? Future.value('current.oecad');
  }

  @override
  Future<EcadProject?> open() {
    openCalls++;
    return openResult?.future ?? Future.value();
  }

  @override
  Future<void> saveAutosave(
    EcadProject project, {
    int? savedRevision,
    String? fileName,
  }) {
    autosavedProjects.add(project);
    return autosaveResult?.future ?? Future.value();
  }

  @override
  Future<void> saveAiSettings(AiProviderSettings settings) async {
    savedSettings.add(settings);
  }
}

class _DelayedAssistant extends AssistantService {
  final _pending = <(EcadProject, Completer<AssistantProposal>)>[];

  @override
  Future<AssistantProposal> proposeWithOllama(
    String prompt, {
    required EcadProject project,
    required String sheetId,
    required AiProviderSettings settings,
    Set<String> selectedDeviceIds = const {},
    Vec2? insertionPoint,
  }) {
    final response = Completer<AssistantProposal>();
    _pending.add((project, response));
    return response.future;
  }

  /// Answers the oldest request that is still waiting.
  void complete({
    AssistantAction action = AssistantAction.none,
    String message = 'Delayed model response',
  }) {
    final (project, response) = _pending.removeAt(0);
    response.complete(
      AssistantProposal(
        label: 'Delayed proposal',
        message: message,
        commands:
            action == AssistantAction.none
                ? [const RenameProject('Model name')]
                : [],
        baseRevision: project.revision,
        action: action,
        source: AssistantSource.ollama,
      ),
    );
  }
}

class _FilePersistence extends ProjectPersistence {
  Completer<void>? saveGate;

  @override
  Future<String?> save(EcadProject project) async {
    await saveGate?.future;
    return 'Rozvaděč A.oecad';
  }
}

void main() {
  group('document-bound persistence', () {
    for (final sameDemoId in [false, true]) {
      test(
        'old save cannot mark a replacement clean (same demo ID: $sameDemoId)',
        () async {
          final persistence =
              _ControlledPersistence()..saveResult = Completer<String?>();
          final app = EditorController(persistence: persistence);
          addTearDown(app.dispose);
          final original = app.project;
          final saving = app.saveProject();
          expect(app.ioBusy, isTrue);
          app.newProject(demo: sameDemoId);
          final replacement = app.project;
          final replacementStatus = app.status;
          expect(replacement.revision, original.revision);
          if (sameDemoId) expect(replacement.id, original.id);
          expect(app.dirty, isTrue);

          persistence.saveResult!.complete('old-project.oecad');
          await saving;

          expect(identical(app.project, replacement), isTrue);
          expect(app.dirty, isTrue);
          expect(app.fileName, isNull);
          expect(app.status, replacementStatus);
          expect(app.ioBusy, isFalse);
          persistence.saveResult = null;
          await app.saveProject();
          expect(app.dirty, isFalse);
          expect(app.fileName, 'current.oecad');
        },
      );
    }

    test(
      'a save error from a replaced document cannot overwrite its status',
      () async {
        final persistence =
            _ControlledPersistence()..saveResult = Completer<String?>();
        final app = EditorController(persistence: persistence);
        addTearDown(app.dispose);
        final saving = app.saveProject();
        app.newProject();
        final status = app.status;
        persistence.saveResult!.completeError(StateError('old disk failure'));
        await saving;
        expect(app.status, status);
        expect(app.dirty, isTrue);
        expect(app.ioBusy, isFalse);
      },
    );

    test(
      'saving a snapshot preserves newer unsaved edits in the same document',
      () async {
        final persistence =
            _ControlledPersistence()..saveResult = Completer<String?>();
        final app = EditorController(persistence: persistence);
        addTearDown(app.dispose);
        final saving = app.saveProject();
        app.renameProject('Changed while saving');
        persistence.saveResult!.complete('snapshot.oecad');
        await saving;
        expect(app.project.name, 'Changed while saving');
        expect(app.dirty, isTrue);
        expect(app.fileName, 'snapshot.oecad');
        expect(app.status, contains('novější změny nejsou uložené'));
        expect(persistence.savedProjects.single.revision, 0);
      },
    );

    test('an open operation prevents overlapping opens and saves', () async {
      final persistence =
          _ControlledPersistence()..openResult = Completer<EcadProject?>();
      final app = EditorController(persistence: persistence);
      addTearDown(app.dispose);
      final opening = app.openProject();
      await app.openProject();
      await app.saveProject();
      expect(persistence.openCalls, 1);
      expect(persistence.savedProjects, isEmpty);
      persistence.openResult!.complete(
        DemoProject.create().copyWith(name: 'Imported'),
      );
      await opening;
      expect(app.project.name, 'Imported');
      expect(app.dirty, isFalse);
      expect(app.ioBusy, isFalse);
    });

    test('an in-flight save prevents a second save or open', () async {
      final persistence =
          _ControlledPersistence()..saveResult = Completer<String?>();
      final app = EditorController(persistence: persistence);
      addTearDown(app.dispose);
      final saving = app.saveProject();
      await app.openProject();
      await app.saveProject();
      expect(persistence.openCalls, 0);
      expect(persistence.savedProjects, hasLength(1));
      persistence.saveResult!.complete(null);
      await saving;
      expect(app.ioBusy, isFalse);
    });

    test('a pending open cannot replace a newly created document', () async {
      final persistence =
          _ControlledPersistence()..openResult = Completer<EcadProject?>();
      final app = EditorController(persistence: persistence);
      addTearDown(app.dispose);
      final opening = app.openProject();
      app.newProject(demo: true);
      final replacement = app.project;
      final status = app.status;
      persistence.openResult!.complete(
        DemoProject.create().copyWith(name: 'Too late'),
      );
      await opening;
      expect(identical(app.project, replacement), isTrue);
      expect(app.dirty, isTrue);
      expect(app.status, status);
      expect(app.ioBusy, isFalse);
    });

    test(
      'a pending open cannot discard edits made while the picker was open',
      () async {
        final persistence =
            _ControlledPersistence()..openResult = Completer<EcadProject?>();
        final app = EditorController(persistence: persistence);
        addTearDown(app.dispose);
        final opening = app.openProject();
        app.renameProject('Keep my edit');
        persistence.openResult!.complete(
          DemoProject.create().copyWith(name: 'Late import'),
        );
        await opening;
        expect(app.project.name, 'Keep my edit');
        expect(app.dirty, isTrue);
        expect(app.status, contains('Otevření odloženo'));
        expect(app.canUndo, isTrue);
      },
    );

    test(
      'finishing a save after disposal does not publish a saved document',
      () async {
        final persistence =
            _ControlledPersistence()..saveResult = Completer<String?>();
        final app = EditorController(persistence: persistence);
        final saving = app.saveProject();
        app.dispose();
        persistence.saveResult!.complete('disposed.oecad');
        await saving;
        expect(app.fileName, isNull);
      },
    );

    testWidgets('old autosave completion cannot label a replacement as saved', (
      tester,
    ) async {
      final persistence =
          _ControlledPersistence()..autosaveResult = Completer<void>();
      final app = EditorController(persistence: persistence);
      try {
        app.renameProject('Old revision one');
        await tester.pump(const Duration(milliseconds: 401));
        expect(persistence.autosavedProjects, hasLength(1));
        app.newProject(demo: true);
        app.renameProject('New revision one');
        expect(
          app.project.revision,
          persistence.autosavedProjects.single.revision,
        );
        persistence.autosaveResult!.complete();
        await tester.pump();
        expect(app.autosaveStatus, 'Ukládání pracovní kopie…');
      } finally {
        app.dispose();
      }
    });
  });

  group('restoring the working copy', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> autosave(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 401));
      await tester.pump();
    }

    Future<EditorController> restart(EditorController previous) async {
      previous.dispose();
      final app = EditorController(persistence: _FilePersistence());
      addTearDown(app.dispose);
      await app.initialize();
      expect(app.status, 'Obnovena místní pracovní kopie');
      return app;
    }

    testWidgets('an immediate restart after save preserves its file state', (
      tester,
    ) async {
      final first = EditorController(persistence: _FilePersistence());
      await first.initialize();
      first.renameProject('Rozvaděč A');
      await autosave(tester);
      await first.saveProject();
      final second = await restart(first);
      expect(second.project.name, 'Rozvaděč A');
      expect(second.dirty, isFalse);
      expect(second.fileName, 'Rozvaděč A.oecad');
    });

    testWidgets('edits after a save restore as unsaved', (tester) async {
      final first = EditorController(persistence: _FilePersistence());
      await first.initialize();
      await first.saveProject();
      first.renameProject('Změna po uložení');
      await autosave(tester);
      final second = await restart(first);
      expect(second.project.name, 'Změna po uložení');
      expect(second.dirty, isTrue);
      expect(second.fileName, 'Rozvaděč A.oecad');
    });

    testWidgets('a save finishing after newer edits does not cover them', (
      tester,
    ) async {
      final persistence = _FilePersistence()..saveGate = Completer<void>();
      final first = EditorController(persistence: persistence);
      await first.initialize();
      final saving = first.saveProject();
      first.renameProject('Během ukládání');
      persistence.saveGate!.complete();
      await saving;
      expect(first.dirty, isTrue);
      final second = await restart(first);
      expect(second.project.name, 'Během ukládání');
      expect(second.dirty, isTrue);
    });

    testWidgets('a replacement does not inherit the previous file state', (
      tester,
    ) async {
      final first = EditorController(persistence: _FilePersistence());
      await first.initialize();
      first.renameProject('Původní');
      await first.saveProject();
      await autosave(tester);
      first.newProject(demo: true);
      await autosave(tester);
      final second = await restart(first);
      expect(second.project.toJson(), DemoProject.create().toJson());
      expect(second.dirty, isTrue);
      expect(second.fileName, isNull);
    });
  });

  test(
    'manual insertion reserves designation aliases globally and shares K numbering',
    () {
      final app = EditorController(persistence: _ControlledPersistence());
      addTearDown(app.dispose);
      app.placeDevice(DeviceKind.terminal, const Vec2(800, 250));
      expect(app.selectedDevices.single.designation, '-X3');
      app.setSheet('sheet_control');
      app.placeDevice(DeviceKind.terminal, const Vec2(800, 250));
      expect(app.selectedDevices.single.designation, '-X4');
      app.placeDevice(DeviceKind.coil, const Vec2(800, 350));
      expect(app.selectedDevices.single.designation, '-K3');
      app.setSheet('sheet_power');
      app.placeDevice(DeviceKind.contactor, const Vec2(800, 450));
      expect(app.selectedDevices.single.designation, '-K4');
    },
  );

  group('assistant transactions and configuration', () {
    test(
      'preview is isolated, apply creates one undo step, undo restores the original',
      () async {
        final app = EditorController(persistence: _ControlledPersistence());
        addTearDown(app.dispose);
        final original = app.project;
        await app.sendPrompt('Vlož svorku');
        expect(app.project.toJson(), original.toJson());
        expect(app.showingProposal, isTrue);
        expect(
          app.displaySheet.devices,
          hasLength(app.sheet.devices.length + 1),
        );
        expect(app.canUndo, isFalse);
        app.moveDevices({'dev_motor': const Vec2(10, 20)});
        expect(app.project.toJson(), original.toJson());
        app.applyProposal();
        expect(app.project.revision, 1);
        expect(
          app.sheet.devices,
          hasLength(original.pages.first.devices.length + 1),
        );
        expect(app.showingProposal, isFalse);
        expect(app.proposal, isNull);
        expect(app.canUndo, isTrue);
        app.undo();
        expect(app.project.toJson(), original.copyWith(revision: 2).toJson());
        expect(app.canUndo, isFalse);
        expect(app.canRedo, isTrue);
      },
    );

    for (final action in [AssistantAction.none, AssistantAction.undo]) {
      test(
        'an AI ${action.name} response from an older revision cannot affect newer edits',
        () async {
          final assistant = _DelayedAssistant();
          final app = EditorController(
            persistence: _ControlledPersistence(),
            assistant: assistant,
          );
          addTearDown(app.dispose);
          await app.configureAi(const AiProviderSettings(), enabled: true);
          final request = app.sendPrompt('A delayed change');
          expect(app.busy, isTrue);
          app.renameProject('Newer manual edit');
          assistant.complete(action: action);
          await request;
          expect(app.project.name, 'Newer manual edit');
          expect(app.project.revision, 1);
          expect(app.proposal, isNull);
          expect(app.showingProposal, isFalse);
          expect(app.busy, isFalse);
          expect(app.conversation.last.text, contains('během přípravy změnil'));
        },
      );
    }

    test(
      'switching sheets cancels a pending AI request with a visible notice',
      () async {
        final assistant = _DelayedAssistant();
        final app = EditorController(
          persistence: _ControlledPersistence(),
          assistant: assistant,
        );
        addTearDown(app.dispose);
        await app.configureAi(const AiProviderSettings(), enabled: true);
        final request = app.sendPrompt('Add a device');
        app.setSheet('sheet_control');
        expect(app.busy, isFalse);
        expect(app.conversation.map((entry) => entry.text), [
          'Add a device',
          contains('zrušen přepnutím listu'),
        ]);
        assistant.complete(message: 'Late answer');
        await request;
        expect(app.activeSheetId, 'sheet_control');
        expect(app.proposal, isNull);
        expect(app.conversation, hasLength(2));
        expect(app.busy, isFalse);
      },
    );

    test('a cancelled request cannot finish a newer request', () async {
      final assistant = _DelayedAssistant();
      final app = EditorController(
        persistence: _ControlledPersistence(),
        assistant: assistant,
      );
      addTearDown(app.dispose);
      await app.configureAi(const AiProviderSettings(), enabled: true);
      final cancelled = app.sendPrompt('First request');
      app.setSheet('sheet_control');
      final current = app.sendPrompt('Second request');
      assistant.complete(message: 'Answer for the old sheet');
      await cancelled;
      expect(app.busy, isTrue);
      expect(app.proposal, isNull);
      expect(app.conversation.last.text, 'Second request');
      assistant.complete(message: 'Answer for this sheet');
      await current;
      expect(app.busy, isFalse);
      expect(app.proposal, isNotNull);
      expect(
        app.conversation.map((entry) => entry.text),
        isNot(contains('Answer for the old sheet')),
      );
      expect(app.conversation.last.text, 'Answer for this sheet');
    });

    test('Escape closes a preview without discarding the proposal', () async {
      final app = EditorController(persistence: _ControlledPersistence());
      addTearDown(app.dispose);
      final devices = app.sheet.devices.length;
      await app.sendPrompt('Vlož svorku');
      expect(app.showingProposal, isTrue);
      app.cancelTool();
      expect(app.showingProposal, isFalse);
      expect(app.proposalIsCurrent, isTrue);
      expect(app.mode, CanvasMode.select);
      app.toggleProposalPreview();
      expect(app.showingProposal, isTrue);
      app.applyProposal();
      expect(app.sheet.devices, hasLength(devices + 1));
      await app.sendPrompt('Vlož svorku');
      app.cancelTool();
      app.discardProposal();
      expect(app.proposal, isNull);
    });

    test(
      'replacing a document invalidates a pending AI response even at the same revision',
      () async {
        final assistant = _DelayedAssistant();
        final app = EditorController(
          persistence: _ControlledPersistence(),
          assistant: assistant,
        );
        addTearDown(app.dispose);
        await app.configureAi(const AiProviderSettings(), enabled: true);
        final request = app.sendPrompt('Add a device');
        app.newProject(demo: true);
        assistant.complete();
        await request;
        expect(app.project.toJson(), DemoProject.create().toJson());
        expect(app.conversation, isEmpty);
        expect(app.proposal, isNull);
        expect(app.busy, isFalse);
      },
    );

    test(
      'invalid AI configuration changes neither live settings nor persistence',
      () async {
        final persistence = _ControlledPersistence();
        final app = EditorController(persistence: persistence);
        addTearDown(app.dispose);
        final original = app.aiSettings;
        var notifications = 0;
        app.addListener(() => notifications++);
        for (final settings in [
          const AiProviderSettings(baseUrl: 'http://localhost:11434?token=bad'),
          AiProviderSettings(model: 'x' * 121),
        ]) {
          await expectLater(
            app.configureAi(settings, enabled: true),
            throwsA(isA<FormatException>()),
          );
        }
        expect(identical(app.aiSettings, original), isTrue);
        expect(app.useOllama, isFalse);
        expect(persistence.savedSettings, isEmpty);
        expect(notifications, 0);
      },
    );

    test('valid AI configuration is available and persisted', () async {
      final persistence = _ControlledPersistence();
      final app = EditorController(persistence: persistence);
      addTearDown(app.dispose);
      const settings = AiProviderSettings(
        baseUrl: 'http://localhost:12000',
        model: 'local-model',
      );
      await app.configureAi(settings, enabled: true);
      expect(app.aiSettings, same(settings));
      expect(app.useOllama, isTrue);
      expect(persistence.savedSettings.single, same(settings));
    });
  });

  group('visible validation results', () {
    test(
      'assistant validation publishes actual counts and the demo diagnostic',
      () async {
        final app = EditorController(persistence: _ControlledPersistence());
        addTearDown(app.dispose);
        await app.sendPrompt('Zkontroluj projekt');
        expect(app.diagnosticsVisible, isTrue);
        expect(app.diagnostics, hasLength(1));
        expect(app.status, contains('chyby 0 · upozornění 1'));
        expect(app.conversation.last.text, contains('chyby 0 · upozornění 1'));
        expect(app.conversation.last.text, contains('-X2'));
        expect(app.busy, isFalse);
        expect(app.proposal, isNull);
        app.hideDiagnostics();
        expect(app.diagnosticsVisible, isFalse);
        expect(app.diagnostics, hasLength(1));
      },
    );

    test('validation opens its panel and edits hide outdated results', () {
      final app = EditorController(persistence: _ControlledPersistence());
      addTearDown(app.dispose);
      app.validate();
      expect(app.diagnosticsVisible, isTrue);
      app.renameProject('Updated');
      expect(app.diagnosticsVisible, isFalse);
      expect(app.diagnostics, isEmpty);
    });

    test('assistant validation explicitly reports a clean document', () async {
      final app = EditorController(persistence: _ControlledPersistence());
      addTearDown(app.dispose);
      app.newProject();
      await app.sendPrompt('Zkontroluj projekt');
      expect(app.diagnosticsVisible, isTrue);
      expect(app.diagnostics, isEmpty);
      expect(app.status, 'Struktura projektu je v pořádku');
      expect(app.conversation.last.text, contains('chyby 0 · upozornění 0'));
    });
  });
}
