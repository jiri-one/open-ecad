// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace_controller.dart';
import 'package:open_ecad/services/document_session.dart';
import 'package:open_ecad/services/pdf_frame_import.dart';
import 'package:open_ecad/services/project_import.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pdf_import_fixtures.dart';

class _Import extends ProjectImportService {
  final done = Completer<EcadProject?>();
  @override
  Future<EcadProject?> importPdf() => done.future;
}

class _ManyImports extends ProjectImportService {
  final ready = [Completer<void>(), Completer<void>()];
  int calls = 0;

  @override
  Future<EcadProject?> importPdf() async {
    final index = calls++;
    await ready[index].future;
    warnings = ['Upozornění $index'];
    return syntheticPdfProject();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'preserve keeps original graphics, page properties, order and explicit none',
    () {
      final original = syntheticPdfProject(pages: 2);
      final before = jsonEncode(original.toJson());
      final result = PdfFrameImportDraft(original).previewProject();
      expect(result.toJson(), original.toJson());
      expect(result.pages.first, same(original.pages.first));
      expect(result.pages.every((p) => p.frame.mode == FrameMode.none), isTrue);
      expect(jsonEncode(original.toJson()), before);
      final native = Sheet(id: 'native', name: 'Nový', number: '3');
      expect(resolveSheetFrame(result, native), isNotNull);
    },
  );

  test(
    'only selected objects are removed; retained artwork uses core fit in source order',
    () {
      final original = syntheticPdfProject();
      final before = jsonEncode(original.toJson());
      final draft = PdfFrameImportDraft(original);
      draft.choice('page1').replace = true;
      draft.toggleRemoved('page1', 'border1');
      final result = draft.previewProject();
      final page = result.pages.single;
      final expected = fitGraphicsToFrame(
        original.pages.single,
        page,
        layoutFrameGeometry(page.paperSizeMm, resolveSheetFrame(result, page)),
        retainedGraphicIds: {'text1', 'image1'},
      );
      expect(
        page.graphics.map((g) => g.toJson()).toList(),
        expected.map((g) => g.toJson()).toList(),
      );
      expect(page.graphics.map((g) => g.id), ['text1', 'image1']);
      expect(page.graphics.first.text, 'Zkouška 1');
      expect(page.graphics.first.fill, '#334455');
      expect(page.graphics.first.bold, isTrue);
      expect(page.graphics.last.imageData, syntheticPdfPng);
      expect(page.graphics.last.opacity, .8);
      expect(page.sourcePage, 1);
      expect(jsonEncode(original.toJson()), before);
    },
  );

  test(
    'graphic-only cabinet imports can replace the old frame without changing page type',
    () {
      final source = syntheticPdfProject();
      final original = source.copyWith(
        pages: [source.pages.single.copyWith(type: SheetType.cabinetLayout)],
      );
      requireValidProject(original);
      final draft = PdfFrameImportDraft(original);
      draft.choice('page1').replace = true;
      draft.toggleRemoved('page1', 'border1');
      final result = draft.previewProject();
      final page = result.pages.single;
      expect(page.type, SheetType.cabinetLayout);
      expect(page.sourcePage, 1);
      expect(page.mountingView, isNull);
      expect(page.graphics.map((g) => g.id), ['text1', 'image1']);
      expect(resolveSheetFrame(result, page), isNotNull);
      expect(original.pages.single.graphics, hasLength(3));
    },
  );

  test(
    'no old frame permits empty removal; repeated previews always use untouched source',
    () {
      final original = syntheticPdfProject(border: false);
      final draft = PdfFrameImportDraft(original);
      draft.choice('page1').replace = true;
      final first = draft.previewProject().toJson();
      for (var i = 0; i < 5; i++) {
        expect(draft.previewProject().toJson(), first);
      }
      expect(draft.choice('page1').removedIds, isEmpty);
      expect(draft.previewPage('page1').graphics.map((g) => g.id), [
        'text1',
        'image1',
      ]);
      draft.choice('page1').replace = false;
      expect(
        draft.previewPage('page1').toJson(),
        original.pages.single.toJson(),
      );
      draft.choice('page1').replace = true;
      expect(draft.previewProject().toJson(), first);
    },
  );

  test('selection is per page and undo/reset restores exact whole objects', () {
    final draft = PdfFrameImportDraft(syntheticPdfProject(pages: 2));
    draft.choice('page1').replace = true;
    draft.choice('page2').replace = true;
    draft.toggleRemoved('page1', 'border1');
    draft.toggleRemoved('page1', 'image1');
    draft.choice('page1').undoSelection();
    expect(draft.choice('page1').removedIds, {'border1'});
    draft.toggleRemoved('page2', 'text2');
    expect(draft.previewPage('page2').graphics.map((g) => g.id), [
      'border2',
      'image2',
    ]);
    draft.choice('page1').clearSelection();
    expect(draft.choice('page1').removedIds, isEmpty);
    draft.choice('page1').undoSelection();
    expect(draft.choice('page1').removedIds, {'border1'});
    draft.resetPage('page1');
    expect(
      draft.previewPage('page1').toJson(),
      draft.source.pages.first.toJson(),
    );
    expect(draft.choice('page2').removedIds, {'text2'});
    expect(
      () => draft.toggleRemoved('page1', 'missing'),
      throwsFormatException,
    );
  });

  test(
    'current document template copies definition with fresh ID and uses its geometry',
    () {
      final source = syntheticPdfProject();
      final template = FrameTemplates.builtin.copyWith(
        name: 'Vlastní šablona',
        marginsMm: const FrameMargins(left: 25, right: 20),
        titleBlock: FrameTemplates.builtin.titleBlock.copyWith(heightMm: 50),
      );
      final draft = PdfFrameImportDraft(source, reusableTemplates: [template]);
      final copied = draft.templates.last.definition;
      draft.choice('page1')
        ..replace = true
        ..templateId = copied.id;
      draft.toggleRemoved('page1', 'border1');
      final result = draft.previewProject();
      expect(copied.id, isNot(template.id));
      expect(copied.copyWith(id: template.id).toJson(), template.toJson());
      expect(result.documentFields, source.documentFields);
      expect(result.frameTemplates, hasLength(2));
      final geometry = layoutFrameGeometry(
        result.pages.single.paperSizeMm,
        resolveSheetFrame(result, result.pages.single),
      );
      expect(geometry.borderRectMm!.x, 25);
      expect(geometry.titleBlockRectMm!.height, 50);
      final originalFrame = PdfFrameImportDraft(source);
      originalFrame.choice('page1').replace = true;
      originalFrame.toggleRemoved('page1', 'border1');
      expect(
        result.pages.single.graphics.first.position,
        isNot(originalFrame.previewPage('page1').graphics.first.position),
      );
      expect(draft.previewProject().toJson(), result.toJson());
    },
  );

  test(
    'unused external definitions are omitted and a none default is made real',
    () {
      final original = syntheticPdfProject().copyWith(
        defaultFrame: const FrameChoice.none(),
      );
      final draft = PdfFrameImportDraft(
        original,
        reusableTemplates: [FrameTemplates.builtin.copyWith(name: 'Nepoužitá')],
      );
      final result = draft.previewProject();
      expect(result.pages.single.toJson(), original.pages.single.toJson());
      expect(result.defaultFrame.mode, FrameMode.template);
      expect(result.frameTemplates.any((t) => t.name == 'Nepoužitá'), isFalse);
      expect(
        resolveSheetFrame(result, Sheet(id: 'new', name: 'Nový', number: '2')),
        isNotNull,
      );
    },
  );

  test('native sheets and native content are never fitted by importer', () {
    final original = syntheticPdfProject();
    for (final page in [
      original.pages.single.copyWith(sourcePage: null),
      original.pages.single.copyWith(
        corners: [
          const ConnectionCorner(id: 'corner', position: Vec2(100, 100)),
        ],
      ),
    ]) {
      final draft = PdfFrameImportDraft(original.copyWith(pages: [page]));
      draft.choice('page1').replace = true;
      expect(
        () => draft.previewProject(),
        throwsA(anyOf(isA<FormatException>(), isA<EcadException>())),
      );
    }
  });

  test(
    'canceling file selection or frame review cannot replace a session',
    () async {
      for (final converted in [null, syntheticPdfProject()]) {
        final importer = _Import();
        final initial = syntheticPdfProject().copyWith(id: 'initial');
        final session = DocumentSession(
          initial,
          persistence: ProjectPersistence(),
        );
        addTearDown(session.dispose);
        var calls = 0;
        final reviewed = importer.reviewNextImport((request) async {
          calls++;
          return null;
        }, isCurrent: () => true);
        final pending = session.open(importProject: reviewed.importPdf);
        importer.done.complete(converted);
        expect(await pending, DocumentIoResult.canceled);
        expect(session.project, same(initial));
        expect(calls, converted == null ? 0 : 1);
      }
    },
  );

  test(
    'review callback receives warnings unchanged and retains them after adoption',
    () async {
      final importer = _Import()..warnings = ['Syntetické upozornění převodu'];
      final app = EditorController(importer: importer);
      final workspace = WorkspaceController(app);
      addTearDown(() {
        workspace.dispose();
        app.dispose();
      });
      final pending = workspace.open(
        importPdf: true,
        reviewPdf: (request) async {
          expect(request.warnings, ['Syntetické upozornění převodu']);
          expect(request.reusableTemplates, app.project.frameTemplates);
          return PdfFrameImportDraft(request.project).previewProject();
        },
      );
      importer.done.complete(syntheticPdfProject(pages: 2));
      expect(await pending, isTrue);
      expect(workspace.documents, hasLength(2));
      expect(workspace.active.dirty, isTrue);
      expect(
        workspace.active.conversation.single.text,
        'Syntetické upozornění převodu',
      );
      expect(workspace.active.project.pages.map((p) => p.sourcePage), [1, 2]);
      expect(workspace.active.importer.source, same(importer));
    },
  );

  test('concurrent reviews retain their own conversion warnings', () async {
    final source = _ManyImports();
    final firstReview = Completer<EcadProject?>();
    final firstStarted = Completer<void>();
    final first = source.reviewNextImport((request) {
      expect(request.warnings, ['Upozornění 0']);
      firstStarted.complete();
      return firstReview.future;
    }, isCurrent: () => true);
    final second = source.reviewNextImport((request) async {
      expect(request.warnings, ['Upozornění 1']);
      return request.project;
    }, isCurrent: () => true);
    final a = first.importPdf();
    final b = second.importPdf();
    expect(source.calls, 1);
    source.ready.first.complete();
    await firstStarted.future;
    source.ready.last.complete();
    expect(await b, isNotNull);
    firstReview.complete(syntheticPdfProject());
    expect(await a, isNotNull);
    expect(first.warnings, ['Upozornění 0']);
    expect(second.warnings, ['Upozornění 1']);
  });

  test(
    'superseded queued conversion never opens another file picker',
    () async {
      final source = _ManyImports();
      var current = true;
      final first = source.reviewNextImport(
        (r) async => r.project,
        isCurrent: () => true,
      );
      final second = source.reviewNextImport(
        (_) async => fail('Stale review'),
        isCurrent: () => current,
      );
      final a = first.importPdf();
      final b = second.importPdf();
      current = false;
      source.ready.first.complete();
      expect(await a, isNotNull);
      expect(await b, isNull);
      expect(source.calls, 1);
    },
  );

  for (final stage in ['conversion', 'review']) {
    test('sheet navigation during $stage explains discarded import', () async {
      final importer = _Import();
      final app = EditorController(importer: importer);
      final workspace = WorkspaceController(app);
      addTearDown(() {
        workspace.dispose();
        app.dispose();
      });
      final review = Completer<EcadProject?>();
      final started = Completer<void>();
      final pending = workspace.open(
        importPdf: true,
        reviewPdf: (_) {
          started.complete();
          return review.future;
        },
      );
      if (stage == 'review') {
        importer.done.complete(syntheticPdfProject());
        await started.future;
      }
      workspace.openSheet(app, app.project.pages.last.id);
      if (stage == 'conversion') {
        importer.done.complete(syntheticPdfProject());
      } else {
        review.complete(syntheticPdfProject());
      }
      expect(await pending, isFalse);
      expect(app.status, contains('Import PDF zrušen'));
      expect(workspace.documents, hasLength(1));
    });
    for (final action in ['switch', 'edit', 'close']) {
      test(
        'stale owner at $stage after $action cannot adopt a PDF or overwrite status',
        () async {
          final importer = _Import();
          final app = EditorController(importer: importer);
          final workspace = WorkspaceController(app);
          final review = Completer<EcadProject?>();
          final started = Completer<void>();
          var called = false;
          addTearDown(() {
            workspace.dispose();
            if (action != 'close') app.dispose();
          });
          final pending = workspace.open(
            importPdf: true,
            reviewPdf: (request) {
              called = true;
              started.complete();
              return review.future;
            },
          );
          if (stage == 'review') {
            importer.done.complete(syntheticPdfProject());
            await started.future;
          }
          switch (action) {
            case 'switch':
              workspace.create();
            case 'edit':
              app.renameProject('Novější práce');
            case 'close':
              workspace.closeDocument(app);
          }
          workspace.active.reportStatus('Aktuální zpráva');
          final count = workspace.documents.length;
          if (stage == 'conversion') {
            importer.done.complete(syntheticPdfProject());
          } else {
            review.complete(syntheticPdfProject());
          }
          expect(await pending, isFalse);
          expect(called, stage == 'review');
          expect(workspace.documents, hasLength(count));
          expect(workspace.active.status, 'Aktuální zpráva');
          expect(
            workspace.documents.any((d) => d.project.id == 'pdf-import-test'),
            isFalse,
          );
        },
      );
    }
  }
}
