import 'dart:async';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/services/schematic_clipboard.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'continuation_fixtures.dart';

Future<void> shortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
  bool alt = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(key);
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

class ClipboardMemoryPersistence extends ProjectPersistence {
  final saved = <WorkingCopy>[];
  WorkingCopy? loaded;
  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async {
    saved.add(copy);
    return 'memory';
  }

  @override
  Future<WorkingCopy?> loadAutosave({String? sessionId}) async => loaded;
}

void main() {
  String clipboard = '';
  Completer<Object?>? read;
  var reads = 0, writes = 0;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clipboard = '';
    read = null;
    reads = 0;
    writes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard = (call.arguments as Map)['text'] as String;
              writes++;
              return null;
            case 'Clipboard.getData':
              reads++;
              return read == null ? {'text': clipboard} : read!.future;
            case 'Clipboard.hasStrings':
              return {'value': clipboard.isNotEmpty};
            default:
              return null;
          }
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  for (final grid in [true, false]) {
    testWidgets(
      'paste preserves relative geometry with off-grid graphics, grid: $grid',
      (tester) async {
        final base = continuationProject(sameSheet: 0);
        final project = base.copyWith(
          pages: [
            base.pages.first.copyWith(
              graphics: [
                DrawingElement(
                  id: 'label',
                  kind: DrawingKind.path,
                  position: const Vec2(903.4, 677.7),
                  width: 30,
                  height: 20,
                  stroke: '#000000',
                  path: [
                    PathSegment(
                      verb: PathVerb.moveTo,
                      points: const [Vec2(0, 0)],
                    ),
                    PathSegment(
                      verb: PathVerb.lineTo,
                      points: const [Vec2(30, 20)],
                    ),
                  ],
                ),
              ],
            ),
            base.pages.last,
          ],
        );
        final app = continuationController(project);
        await mountContinuations(tester, app);
        if (app.showGrid != grid) app.toggleGrid();
        app.select({'symbol', 'source', 'label'});
        await tester.pump();
        await shortcut(tester, LogicalKeyboardKey.keyC);
        await shortcut(tester, LogicalKeyboardKey.keyV);
        await tester.pumpAndSettle();
        final anchor = app.pastePreview!.anchor;
        final target = continuationPoint(tester, app, const Vec2(1350, 900));
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: target - const Offset(30, 0));
        await mouse.moveTo(target);
        await tester.pump();
        final ghost = app.viewport.pastePosition!;
        final delta = ghost - anchor;
        if (grid) {
          expect(
            delta.x / SchematicCanvas.gridSpacing,
            closeTo(
              (delta.x / SchematicCanvas.gridSpacing).roundToDouble(),
              1e-9,
            ),
          );
          expect(
            delta.y / SchematicCanvas.gridSpacing,
            closeTo(
              (delta.y / SchematicCanvas.gridSpacing).roundToDouble(),
              1e-9,
            ),
          );
        } else {
          expect(ghost.x, closeTo(1350, 1e-9));
          expect(ghost.y, closeTo(900, 1e-9));
        }
        await mouse.down(target);
        await mouse.up();
        await tester.pumpAndSettle();
        final pasted = app.sheet.devices.last;
        final expected = project.pages.first.devices.single.position + delta;
        expect(pasted.position.x, closeTo(expected.x, 1e-9));
        expect(pasted.position.y, closeTo(expected.y, 1e-9));
        expect(
          app.sheet.continuations.last.position - pasted.position,
          project.pages.first.continuations.single.position -
              project.pages.first.devices.single.position,
        );
        final graphicExpected =
            project.pages.first.graphics.single.position + delta;
        expect(
          app.sheet.graphics.last.position.x,
          closeTo(graphicExpected.x, 1e-9),
        );
        expect(
          app.sheet.graphics.last.position.y,
          closeTo(graphicExpected.y, 1e-9),
        );
        expect(app.sheet.wires.last.waypoints, [
          for (final p in project.pages.first.wires.single.waypoints) p + delta,
        ]);
        if (grid) {
          expect(
            pasted.position.x / SchematicCanvas.gridSpacing,
            closeTo(
              (pasted.position.x / SchematicCanvas.gridSpacing).roundToDouble(),
              1e-9,
            ),
          );
          expect(
            pasted.position.y / SchematicCanvas.gridSpacing,
            closeTo(
              (pasted.position.y / SchematicCanvas.gridSpacing).roundToDouble(),
              1e-9,
            ),
          );
        }
        await shortcut(tester, LogicalKeyboardKey.keyZ);
        expect(app.sheet.devices.map((d) => d.id), ['symbol']);
        expect(app.sheet.graphics.map((g) => g.id), ['label']);
        expect(app.sheet.continuations.map((m) => m.id), ['source']);
        await mouse.removePointer();
        await unmountContinuations(tester);
      },
    );
  }

  testWidgets(
    'Ctrl C/V places selected marker then F and F4 edit; one paste is one undo',
    (tester) async {
      final app = continuationController(continuationProject(sameSheet: 0));
      await mountContinuations(tester, app);
      await selectContinuation(tester, app);
      final original = app.project;
      await shortcut(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, startsWith(SchematicFragment.begin));
      expect(writes, 1);
      expect(app.project, same(original));
      await shortcut(tester, LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(find.byKey(const ValueKey('clipboard-preview')), findsOneWidget);
      expect(app.pastePreview, isNotNull);
      expect(app.project, same(original));
      expect(app.canUndo, isFalse);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final target = continuationPoint(tester, app, const Vec2(1350, 900));
      await mouse.addPointer(location: target - const Offset(40, 0));
      await mouse.moveTo(target);
      await tester.pump();
      expect(app.viewport.pastePosition, const Vec2(1350, 900));
      expect(app.project, same(original));
      await mouse.down(target);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(app.pastePreview, isNull);
      final pasted = app.sheet.continuations.last;
      expect(pasted.id, isNot('source'));
      expect(pasted.linkId, 'network');
      expect(pasted.position, const Vec2(1350, 900));
      expect(app.selectedIds, {pasted.id});
      expect(app.project.revision, original.revision + 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      expect(find.text('Upravit pokračovací odkaz'), findsOneWidget);
      await tester.tap(find.text('Zrušit').last);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(app.selectedIds, {'source'});
      expect(app.project.revision, original.revision + 1);
      await shortcut(tester, LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      await mouse.moveTo(continuationPoint(tester, app, const Vec2(1450, 900)));
      await mouse.down(continuationPoint(tester, app, const Vec2(1450, 900)));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(app.sheet.continuations.length, 3);
      expect(app.project.continuationLinks.length, 2);
      await shortcut(tester, LogicalKeyboardKey.keyZ);
      expect(app.sheet.continuations.length, 2);
      await shortcut(tester, LogicalKeyboardKey.keyZ);
      expect(app.sheet.continuations.length, 1);
      expect(app.canUndo, isFalse);
      await shortcut(tester, LogicalKeyboardKey.keyZ, shift: true);
      expect(app.sheet.continuations.length, 2);
      await shortcut(tester, LogicalKeyboardKey.keyY);
      expect(app.sheet.continuations.length, 3);
      await mouse.removePointer();
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'copy snapshots actual selection, preview starts without destination hover, Escape cancels',
    (tester) async {
      final app = continuationController();
      await mountContinuations(tester, app);
      await selectContinuation(tester, app);
      await shortcut(tester, LogicalKeyboardKey.keyC);
      app.select({'symbol'});
      final original = app.project;
      await shortcut(tester, LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      expect(app.pastePreview!.preview.pages.single.devices, isEmpty);
      expect(app.pastePreview!.preview.pages.single.continuations.length, 1);
      expect(app.viewport.pastePosition, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(app.pastePreview, isNull);
      expect(find.byKey(const ValueKey('clipboard-preview')), findsNothing);
      expect(app.project, same(original));
      expect(app.dirty, isFalse);
      expect(app.canUndo, isFalse);
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'text input retains ordinary copy/paste, modifiers and active gestures do not read drawing clipboard',
    (tester) async {
      final app = continuationController();
      await mountContinuations(tester, app, panel: true);
      await selectContinuation(tester, app);
      final field = find.byType(TextField).last;
      await tester.enterText(field, 'plain text');
      await shortcut(tester, LogicalKeyboardKey.keyA);
      await shortcut(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, 'plain text');
      clipboard = 'replacement';
      await shortcut(tester, LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, 'replacement');
      expect(app.pastePreview, isNull);
      final before = reads;
      app.viewport.focus();
      await tester.pump();
      await shortcut(tester, LogicalKeyboardKey.keyV, alt: true);
      await shortcut(tester, LogicalKeyboardKey.keyV, shift: true);
      expect(reads, before);
      app.setMode(CanvasMode.wire);
      await tester.pump();
      await shortcut(tester, LogicalKeyboardKey.keyV);
      expect(reads, before);
      app.cancelTool();
      await tester.pump();
      final mouse = await tester.startGesture(
        continuationPoint(tester, app, const Vec2(1200, 800)),
      );
      await shortcut(tester, LogicalKeyboardKey.keyV);
      await shortcut(tester, LogicalKeyboardKey.keyC);
      expect(reads, before);
      expect(clipboard, 'replacement');
      await mouse.up();
      await unmountContinuations(tester);
    },
  );

  for (final stale in [
    'switch',
    'away-back',
    'sheet-away-back',
    'replace',
    'revision',
    'close',
    'escape',
  ]) {
    testWidgets('async clipboard read is rejected after $stale', (
      tester,
    ) async {
      final root = continuationController();
      final workspace = await mountContinuations(tester, root);
      final app = continuationController(root.project);
      workspace.add(app);
      await tester.pumpAndSettle();
      app.viewport.reset();
      await tester.pump();
      await selectContinuation(tester, app);
      await shortcut(tester, LogicalKeyboardKey.keyC);
      final copied = clipboard;
      final before = app.project;
      read = Completer<Object?>();
      await shortcut(tester, LogicalKeyboardKey.keyV);
      expect(reads, 1);
      switch (stale) {
        case 'switch':
          workspace.openSheet(root, root.activeSheetId);
        case 'away-back':
          workspace.openSheet(root, root.activeSheetId);
          workspace.openSheet(app, app.activeSheetId);
        case 'sheet-away-back':
          workspace.openSheet(app, 'target-sheet');
          workspace.openSheet(app, 'source-sheet');
        case 'replace':
          app.newProject();
        case 'revision':
          app.renameProject('Edited');
        case 'close':
          await workspace.closeDocument(app);
        case 'escape':
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      }
      read!.complete({'text': copied});
      await tester.pumpAndSettle();
      expect(app.pastePreview, isNull);
      expect(workspace.active.pastePreview, isNull);
      if (!{'replace', 'revision'}.contains(stale)) {
        expect(app.project, same(before));
      }
      expect(find.byKey(const ValueKey('clipboard-preview')), findsNothing);
      await unmountContinuations(tester);
    });
  }

  testWidgets(
    'preview invalidates on switch-away-back and malformed paste cannot alter history',
    (tester) async {
      final app = continuationController();
      final workspace = await mountContinuations(tester, app);
      await selectContinuation(tester, app);
      await shortcut(tester, LogicalKeyboardKey.keyC);
      await shortcut(tester, LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      expect(app.pastePreview, isNotNull);
      workspace.openSheet(app, 'target-sheet');
      workspace.openSheet(app, 'source-sheet');
      await tester.pumpAndSettle();
      expect(app.pastePreview, isNull);
      final before = app.project;
      for (final invalid in [
        'bad clipboard',
        'X' * (SchematicFragment.maxBytes + 1),
      ]) {
        clipboard = invalid;
        app.viewport.focus();
        await tester.pump();
        await shortcut(tester, LogicalKeyboardKey.keyV);
        await tester.pumpAndSettle();
        expect(app.pastePreview, isNull);
        expect(app.status, startsWith('Vložení selhalo:'));
        expect(app.project, same(before));
        expect(app.canUndo, isFalse);
      }
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'cross-document actual shortcuts with identical IDs import a new network',
    (tester) async {
      final app = continuationController();
      final workspace = await mountContinuations(tester, app);
      await selectContinuation(tester, app);
      await shortcut(tester, LogicalKeyboardKey.keyC);
      final other = continuationController(app.project);
      workspace.add(other);
      await tester.pumpAndSettle();
      other.viewport.reset();
      await tester.pump();
      other.viewport.focus();
      await tester.pump();
      await shortcut(tester, LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      await tester.tapAt(
        continuationPoint(tester, other, const Vec2(1300, 900)),
      );
      await tester.pumpAndSettle();
      final copied = other.sheet.continuations.last;
      expect(copied.linkId, isNot('network'));
      expect(
        other.project.continuationLinkById(copied.linkId)!.label,
        'SIGNAL (2)',
      );
      expect(app.project.revision, 0);
      await unmountContinuations(tester);
    },
  );
  testWidgets(
    'transient preview and cancel never enter autosave or BOM; invalid placement is atomic',
    (tester) async {
      final persistence = ClipboardMemoryPersistence();
      final app = EditorController(
        initialProject: continuationProject(),
        persistence: persistence,
      );
      await mountContinuations(tester, app);
      expect(persistence.saved.single.project.revision, 0);
      persistence.saved.clear();
      await selectContinuation(tester, app);
      final original = app.project, bom = app.bom;
      await shortcut(tester, LogicalKeyboardKey.keyC);
      await shortcut(tester, LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(persistence.saved, isEmpty);
      expect(app.bom, same(bom));
      expect(app.project, same(original));
      app.placeClipboard(const Vec2(double.infinity, 20));
      await tester.pumpAndSettle();
      expect(app.project, same(original));
      expect(app.canUndo, isFalse);
      expect(app.pastePreview, isNull);
      await shortcut(tester, LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(seconds: 1));
      expect(persistence.saved, isEmpty);
      await shortcut(tester, LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      await tester.tapAt(continuationPoint(tester, app, const Vec2(1300, 900)));
      await tester.pump(const Duration(seconds: 1));
      expect(persistence.saved, hasLength(1));
      expect(
        persistence.saved.single.project.pages.first.continuations,
        hasLength(3),
      );
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'synthetic restore with same session, sheet and revision rejects pending read and later imports fresh network',
    (tester) async {
      final persistence = ClipboardMemoryPersistence();
      final app = EditorController(
        initialProject: continuationProject(),
        persistence: persistence,
      );
      await mountContinuations(tester, app);
      await selectContinuation(tester, app);
      await shortcut(tester, LogicalKeyboardKey.keyC);
      final copied = clipboard,
          session = app.documentSessionId,
          generation = app.documentGeneration;
      persistence.loaded = WorkingCopy(
        app.project,
        sessionId: session,
        savedRevision: 0,
      );
      read = Completer<Object?>();
      await shortcut(tester, LogicalKeyboardKey.keyV);
      expect(await app.restoreWorkingCopy(session), isTrue);
      expect(app.documentSessionId, session);
      expect(app.documentGeneration, generation + 1);
      read!.complete({'text': copied});
      await tester.pumpAndSettle();
      expect(app.pastePreview, isNull);
      expect(app.project.revision, 0);
      read = null;
      app.viewport.focus();
      await tester.pump();
      await shortcut(tester, LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      expect(
        app.pastePreview!.preview.pages.single.continuations.single.linkId,
        isNot('network'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await unmountContinuations(tester);
    },
  );

  testWidgets(
    'toolbar and palette can start clipboard placement after focus was in text',
    (tester) async {
      final app = continuationController();
      await mountContinuations(tester, app, panel: true);
      await selectContinuation(tester, app);
      await shortcut(tester, LogicalKeyboardKey.keyC);
      await tester.tap(find.byType(TextField).last);
      await tester.pump();
      await tester.tap(find.byTooltip('Vložit ze schránky · Ctrl V'));
      await tester.pumpAndSettle();
      expect(app.pastePreview, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await shortcut(tester, LogicalKeyboardKey.keyK);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Vložit ze schránky');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Vložit ze schránky'));
      await tester.pumpAndSettle();
      expect(app.pastePreview, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await unmountContinuations(tester);
    },
  );
  for (final corner in [false, true]) {
    testWidgets(
      'pasted ${corner ? 'corner' : 'graphic'} opens with F4 and edits the new object',
      (tester) async {
        final base = continuationProject();
        final p = base.copyWith(
          pages: [
            base.pages.first.copyWith(
              corners:
                  corner
                      ? const [
                        ConnectionCorner(
                          id: 'object',
                          position: Vec2(1100, 950),
                        ),
                      ]
                      : const [],
              graphics:
                  corner
                      ? const []
                      : [
                        DrawingElement(
                          id: 'object',
                          kind: DrawingKind.text,
                          position: const Vec2(1100, 950),
                          width: 70,
                          height: 20,
                          text: 'Generic text',
                        ),
                      ],
            ),
            base.pages.last,
          ],
        );
        final app = continuationController(p);
        await mountContinuations(tester, app);
        await tester.tapAt(
          continuationPoint(tester, app, const Vec2(1100, 950)),
        );
        await tester.pump();
        expect(app.selectedIds, {'object'});
        await shortcut(tester, LogicalKeyboardKey.keyC);
        await shortcut(tester, LogicalKeyboardKey.keyV);
        await tester.pumpAndSettle();
        await tester.tapAt(
          continuationPoint(tester, app, const Vec2(1300, 950)),
        );
        await tester.pumpAndSettle();
        final id = app.selectedIds.single;
        expect(id, isNot('object'));
        await tester.sendKeyEvent(LogicalKeyboardKey.f4);
        await tester.pumpAndSettle();
        if (corner) {
          expect(find.text('Upravit spojovací roh'), findsOneWidget);
          await tester.tap(
            find.byType(DropdownButtonFormField<CornerOrientation>),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text(CornerOrientation.bottomRight.glyph).last);
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.widgetWithText(FilledButton, 'Uložit'),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            app.sheet.corners.last.orientation,
            CornerOrientation.bottomRight,
          );
          expect(
            app.sheet.corners.first.orientation,
            CornerOrientation.topLeft,
          );
        } else {
          await tester.enterText(continuationField('Text'), 'Edited copy');
          await tester.ensureVisible(find.text('Použít vlastnosti'));
          await tester.tap(find.text('Použít vlastnosti'));
          await tester.pumpAndSettle();
          expect(app.sheet.graphics.last.text, 'Edited copy');
          expect(app.sheet.graphics.first.text, 'Generic text');
        }
        expect(app.project.revision, 2);
        app.undo();
        app.undo();
        expect(app.project.copyWith(revision: 0).toJson(), p.toJson());
        await unmountContinuations(tester);
      },
    );
  }

  testWidgets('corner double click opens editor, stale owner cannot save it', (
    tester,
  ) async {
    final base = continuationProject();
    final app = continuationController(
      base.copyWith(
        pages: [
          base.pages.first.copyWith(
            corners: const [
              ConnectionCorner(id: 'corner', position: Vec2(1100, 950)),
            ],
          ),
          base.pages.last,
        ],
      ),
    );
    final workspace = await mountContinuations(tester, app);
    final point = continuationPoint(tester, app, const Vec2(1100, 950));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(find.text('Upravit spojovací roh'), findsOneWidget);
    final other = continuationController(app.project);
    workspace.add(other);
    workspace.openSheet(app, app.activeSheetId);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<CornerOrientation>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(CornerOrientation.bottomRight.glyph).last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Uložit'),
      ),
    );
    await tester.pumpAndSettle();
    expect(app.project.revision, 0);
    expect(other.project.revision, 0);
    expect(app.sheet.corners.single.orientation, CornerOrientation.topLeft);
    await unmountContinuations(tester);
  });
}
