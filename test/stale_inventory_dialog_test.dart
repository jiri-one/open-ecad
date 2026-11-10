import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/widgets/inventory.dart';
import 'package:open_ecad/widgets/occurrence_dialog.dart';

EcadProject _project() => EcadProject(
  id: 'project',
  name: 'Synthetic',
  articles: const [
    Article(id: 'article', name: 'Part', unit: QuantityUnit.piece),
  ],
  components: const [
    Component(
      id: 'component',
      designation: '-A1',
      mountingSizeOverrideMm: DimensionsMm(width: 40, height: 40),
    ),
  ],
  mountingLayouts: [
    MountingLayout(id: 'layout', name: 'Panel', widthMm: 300, heightMm: 200),
  ],
  pages: [
    Sheet(
      id: 'sheet',
      name: 'Panel',
      number: '1',
      type: SheetType.cabinetLayout,
      mountingView: const MountingView(
        layoutId: 'layout',
        viewport: RectUnits(x: 50, y: 50, width: 900, height: 500),
      ),
    ),
  ],
);

class _Persistence extends ProjectPersistence {
  @override
  Future<LoadedProject> loadPath(String path) async =>
      LoadedProject(_project());
  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async => 'memory';
}

void main() {
  for (final mounting in [false, true]) {
    testWidgets(
      'a pending ${mounting ? 'placement' : 'assignment'} cannot edit a replacement document',
      (tester) async {
        final app = EditorController(
          initialProject: _project(),
          persistence: _Persistence(),
        );
        addTearDown(app.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder:
                  (context) => Scaffold(
                    body: TextButton(
                      onPressed: () {
                        if (mounting) {
                          showMountPlacementDialog(
                            context,
                            app,
                            component: app.project.components.single,
                          );
                        } else {
                          assignArticle(
                            context,
                            app,
                            app.project.articles.single,
                          );
                        }
                      },
                      child: const Text('Open'),
                    ),
                  ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        if (!mounting) {
          await tester.tap(find.byType(DropdownButtonFormField<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('-A1').last);
          await tester.pumpAndSettle();
        }
        expect(await app.openProject(path: 'replacement'), isTrue);
        await tester.pump();
        final replacement = app.project;
        await tester.tap(
          find.widgetWithText(FilledButton, mounting ? 'Umístit' : 'Uložit'),
        );
        await tester.pumpAndSettle();
        expect(app.project, same(replacement));
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Zrušit'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
      },
    );
  }
}
