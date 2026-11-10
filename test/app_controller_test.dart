import 'model_fixtures.dart';
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
  Future<SavedProjectFile?> saveAs(
    EcadProject project, {
    DocumentFileHandle? currentFile,
    Iterable<String> Function()? protectedPaths,
    EncodedProject? encoded,
    required bool Function() canCommit,
  }) {
    savedProjects.add(project);
    return (saveResult?.future ?? Future.value('current.oecad')).then(
      (name) => name == null ? null : SavedProjectFile(name: name),
    );
  }

  @override
  Future<LoadedProject?> pickAndLoad() {
    openCalls++;
    return (openResult?.future ?? Future<EcadProject?>.value()).then(
      (project) => project == null ? null : LoadedProject(project),
    );
  }

  @override
  Future<String> saveWorkingCopy(WorkingCopy copy, {EncodedProject? encoded}) {
    autosavedProjects.add(copy.project);
    return (autosaveResult?.future ?? Future<void>.value()).then(
      (_) => 'memory',
    );
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

void main() {
  group('document-bound project copies', () {
    for (final sameDemoId in [false, true]) {
      test(
        'copy completion cannot affect a replacement (demo: $sameDemoId)',
        () async {
          final persistence =
              _ControlledPersistence()..saveResult = Completer<String?>();
          final app = EditorController(persistence: persistence);
          addTearDown(app.dispose);
          final copying = app.exportProjectCopy();
          expect(app.ioBusy, isTrue);
          app.newProject(demo: sameDemoId);
          final replacement = app.project;
          final status = app.status;
          persistence.saveResult!.complete('old.oecad');
          expect(await copying, isFalse);
          expect(app.project, same(replacement));
          expect(app.fileName, isNull);
          expect(app.status, status);
          expect(app.ioBusy, isFalse);
          expect(await app.flushWorkingCopy(), isTrue);
          expect(app.changesSaved, isTrue);
        },
      );
    }

    test('copying a snapshot leaves later edits automatically saved', () async {
      final persistence =
          _ControlledPersistence()..saveResult = Completer<String?>();
      final app = EditorController(persistence: persistence);
      addTearDown(app.dispose);
      final copying = app.exportProjectCopy();
      app.renameProject('Changed while copying');
      persistence.saveResult!.complete('copy.oecad');
      expect(await copying, isTrue);
      expect(await app.flushWorkingCopy(), isTrue);
      expect(app.project.name, 'Changed while copying');
      expect(app.fileName, isNull);
      expect(app.dirty, isFalse);
      expect(persistence.savedProjects.single.revision, 0);
      expect(persistence.autosavedProjects.last.revision, app.project.revision);
    });

    test('an open operation prevents overlapping pickers and copies', () async {
      final persistence =
          _ControlledPersistence()..openResult = Completer<EcadProject?>();
      final app = EditorController(persistence: persistence);
      addTearDown(app.dispose);
      final opening = app.openProject();
      expect(await app.openProject(), isFalse);
      expect(await app.exportProjectCopy(), isFalse);
      expect(persistence.openCalls, 1);
      expect(persistence.savedProjects, isEmpty);
      persistence.openResult!.complete(
        DemoProject.create().copyWith(name: 'Opened'),
      );
      expect(await opening, isTrue);
      expect(app.project.name, 'Opened');
      expect(app.ioBusy, isFalse);
    });

    test('a pending open cannot replace newer work', () async {
      final persistence =
          _ControlledPersistence()..openResult = Completer<EcadProject?>();
      final app = EditorController(persistence: persistence);
      addTearDown(app.dispose);
      final opening = app.openProject();
      app.renameProject('Keep my edit');
      persistence.openResult!.complete(
        DemoProject.create().copyWith(name: 'Late'),
      );
      expect(await opening, isFalse);
      expect(app.project.name, 'Keep my edit');
      expect(app.status, contains('Otevření odloženo'));
      expect(await app.flushWorkingCopy(), isTrue);
    });

    test('a disposed controller ignores a late copy completion', () async {
      final persistence =
          _ControlledPersistence()..saveResult = Completer<String?>();
      final app = EditorController(persistence: persistence);
      final copying = app.exportProjectCopy();
      app.dispose();
      persistence.saveResult!.complete('disposed.oecad');
      expect(await copying, isFalse);
      expect(app.fileName, isNull);
    });

    testWidgets('old autosave cannot label a replacement as saved', (
      tester,
    ) async {
      final oldSave = Completer<void>(), newSave = Completer<void>();
      final persistence = _ControlledPersistence()..autosaveResult = oldSave;
      final app = EditorController(persistence: persistence);
      addTearDown(app.dispose);
      app.renameProject('Old revision');
      await tester.pump();
      expect(persistence.autosavedProjects, hasLength(1));
      persistence.autosaveResult = newSave;
      app.newProject(demo: true);
      app.renameProject('New revision');
      await tester.pump();
      oldSave.complete();
      await tester.pump();
      expect(app.autosaveStatus, 'Ukládání…');
      expect(app.changesSaved, isFalse);
      newSave.complete();
      await tester.pump();
      expect(app.autosaveStatus, 'Uloženo místně');
      expect(app.changesSaved, isTrue);
    });
  });

  group('restoring automatically saved local projects', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<EditorController> restart(EditorController previous) async {
      expect(await previous.flushWorkingCopy(), isTrue);
      previous.dispose();
      final app = EditorController();
      addTearDown(app.dispose);
      await app.initialize();
      expect(app.status, 'Otevřen místně uložený projekt');
      expect(await app.flushWorkingCopy(), isTrue);
      return app;
    }

    test('new projects and later edits survive immediate restart', () async {
      final first = EditorController();
      await first.initialize();
      first.renameProject('Rozvaděč A');
      final second = await restart(first);
      expect(second.project.name, 'Rozvaděč A');
      expect(second.dirty, isFalse);
      expect(second.fileName, isNull);
      second.renameProject('Změna po obnovení');
      final third = await restart(second);
      expect(third.project.name, 'Změna po obnovení');
      expect(third.changesSaved, isTrue);
    });

    test(
      'an exported copy does not become the active file on restart',
      () async {
        final persistence = _ControlledPersistence();
        final first = EditorController(persistence: persistence);
        addTearDown(first.dispose);
        first.renameProject('Original');
        expect(await first.exportProjectCopy(), isTrue);
        expect(first.currentFile, isNull);
        expect(first.fileName, isNull);
        expect(await first.flushWorkingCopy(), isTrue);
        expect(first.dirty, isFalse);
      },
    );
  });

  test(
    'manual insertion reserves designation aliases globally and shares K numbering',
    () {
      final app = EditorController(
        initialProject: testDemoProject(),
        persistence: _ControlledPersistence(),
      );
      addTearDown(app.dispose);
      app.placeDevice(DeviceKind.terminal, const Vec2(800, 250));
      expect(
        app.resolver.fullDesignation(
          app.componentFor(app.selectedDevices.single),
        ),
        '-X3:1',
      );
      app.setSheet(app.project.pages[1].id);
      app.placeDevice(DeviceKind.terminal, const Vec2(800, 250));
      expect(
        app.resolver.fullDesignation(
          app.componentFor(app.selectedDevices.single),
        ),
        '-X3:2',
      );
      app.placeDevice(DeviceKind.coil, const Vec2(800, 350));
      expect(app.componentFor(app.selectedDevices.single).designation, '-K3');
      app.setSheet('sheet_power');
      app.placeDevice(DeviceKind.contactor, const Vec2(800, 450));
      expect(app.componentFor(app.selectedDevices.single).designation, '-K4');
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
        app.setSheet(app.project.pages[1].id);
        expect(app.busy, isFalse);
        expect(app.conversation.map((entry) => entry.text), [
          'Add a device',
          contains('zrušen přepnutím listu'),
        ]);
        assistant.complete(message: 'Late answer');
        await request;
        expect(app.activeSheetId, app.project.pages[1].id);
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
      app.setSheet(app.project.pages[1].id);
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
        expect(app.diagnostics, isNotEmpty);
        expect(app.status, contains('chyby 0 · upozornění'));
        expect(app.conversation.last.text, contains('chyby 0 · upozornění'));
        expect(app.diagnostics.any((d) => d.componentId != null), isTrue);
        expect(app.busy, isFalse);
        expect(app.proposal, isNull);
        app.hideDiagnostics();
        expect(app.diagnosticsVisible, isFalse);
        expect(app.diagnostics, isNotEmpty);
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
