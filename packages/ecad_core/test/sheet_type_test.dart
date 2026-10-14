// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

Matcher _error(String code) =>
    isA<EcadException>().having((error) => error.code, 'code', code);

const _pixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf2cAAAAASUVORK5CYII=';

EcadProject _project() => EcadProject(
  id: 'typed_project',
  name: 'Typed pages',
  pages: [
    Sheet(
      id: 'sheet_circuit',
      name: 'Řízení čerpadla',
      number: '1',
      devices: const [
        Device(
          id: 'pump_lamp',
          kind: DeviceKind.lamp,
          designation: '-H7',
          position: Vec2(300, 300),
        ),
      ],
    ),
    Sheet(
      id: 'sheet_layout',
      name: 'Skříň A',
      number: '2',
      type: SheetType.cabinetLayout,
    ),
  ],
);

Map<String, Object?> _encoded(EcadProject project) =>
    jsonDecode(jsonEncode(project.toJson())) as Map<String, Object?>;

Map<String, Object?> _firstPage(Map<String, Object?> project) =>
    (project['pages']! as List).first as Map<String, Object?>;

void main() {
  group('sheet type persistence', () {
    test('every type survives a JSON round trip', () {
      for (final type in SheetType.values) {
        final project = _project().copyWith(
          pages: [_project().pages.first.copyWith(type: type)],
        );
        final json = _encoded(project);
        expect(_firstPage(json)['type'], type.name);
        final decoded = EcadProject.fromJson(json);
        expect(decoded.pages.single.type, type);
        expect(decoded.toJson(), project.toJson());
      }
    });

    test('a missing type takes the compatibility fallback', () {
      // v3 too: the PDF converter leaves unclassified pages untyped.
      for (final version in [1, 2, 3]) {
        final json = _encoded(_project())..['formatVersion'] = version;
        for (final page
            in (json['pages']! as List).cast<Map<String, Object?>>()) {
          page.remove('type');
        }
        final engine = ProjectEngine(EcadProject.fromJson(json));
        expect(
          engine.project.pages.map((sheet) => sheet.type),
          everyElement(SheetType.multiLine),
        );
        final written = _encoded(engine.project);
        expect(written['formatVersion'], 3);
        expect(_firstPage(written)['type'], 'multiLine');
      }
      expect(Sheet(id: 's', name: 'S', number: '1').type, SheetType.multiLine);
    });

    test('unknown, misspelled and non-string types are rejected', () {
      for (final invalid in <Object?>[
        'schematic',
        'MultiLine',
        'form ',
        '',
        'x' * 41,
        null,
        2,
        true,
      ]) {
        for (final version in [1, 2, 3]) {
          final json = _encoded(_project())..['formatVersion'] = version;
          _firstPage(json)['type'] = invalid;
          expect(
            () => EcadProject.fromJson(json),
            throwsA(_error('invalid_schema')),
            reason: 'v$version: $invalid',
          );
        }
      }
    });
  });

  group('format migration', () {
    test('v2 graphical project without types keeps every graphic', () {
      final v2 = <String, Object?>{
        'format': 'open-ecad',
        'formatVersion': 2,
        'id': 'v2_drawing',
        'name': 'Starší grafika',
        'description': 'Synthetic v2 document',
        'revision': 7,
        'pages': [
          {
            'id': 'page_imported',
            'name': 'Strana 1',
            'number': '1',
            'width': 842,
            'height': 595,
            'showFrame': false,
            'sourcePage': 1,
            'devices': <Object?>[],
            'wires': <Object?>[],
            'graphics': [
              {
                'id': 'g_curve',
                'kind': 'path',
                'position': {'x': 40, 'y': 50},
                'width': 120,
                'height': 60,
                'path': [
                  {
                    'verb': 'M',
                    'points': [
                      {'x': 0, 'y': 0},
                    ],
                  },
                  {
                    'verb': 'C',
                    'points': [
                      {'x': 40, 'y': 60},
                      {'x': 80, 'y': 0},
                      {'x': 120, 'y': 60},
                    ],
                  },
                  {'verb': 'Z'},
                ],
                'stroke': '#102030',
                'fill': '#A0B0C0',
                'strokeWidth': 0.5,
                'evenOdd': true,
                'opacity': 0.75,
                'dash': [3, 1],
              },
              {
                'id': 'g_text',
                'kind': 'text',
                'position': {'x': 200, 'y': 80},
                'width': 90,
                'height': 24,
                'rotation': 90,
                'fill': '#000000',
                'text': 'Rezerva\nA',
                'fontSize': 10,
                'bold': true,
              },
              {
                'id': 'g_image',
                'kind': 'image',
                'position': {'x': 300, 'y': 300},
                'width': 20,
                'height': 20,
                'imageData': _pixelPng,
              },
            ],
          },
          {
            'id': 'page_native',
            'name': 'Ovládání',
            'number': '2',
            'width': 1100,
            'height': 780,
            'showFrame': true,
            'devices': [
              {
                'id': 'dev_lamp',
                'kind': 'lamp',
                'designation': '-H1',
                'position': {'x': 500, 'y': 400},
                'description': '',
                'rating': '',
                'rotation': 0,
              },
            ],
            'wires': <Object?>[],
            'graphics': [
              {
                'id': 'g_line',
                'kind': 'path',
                'position': {'x': 100, 'y': 600},
                'width': 300,
                'height': 0,
                'path': [
                  {
                    'verb': 'M',
                    'points': [
                      {'x': 0, 'y': 0},
                    ],
                  },
                  {
                    'verb': 'L',
                    'points': [
                      {'x': 300, 'y': 0},
                    ],
                  },
                ],
                'stroke': '#000000',
              },
            ],
          },
        ],
      };
      final engine = ProjectEngine(
        EcadProject.fromJson(jsonDecode(jsonEncode(v2))),
      );
      expect(engine.project.revision, 7);
      final written = _encoded(engine.project);
      expect(written['formatVersion'], 3);
      final before = (v2['pages']! as List).cast<Map<String, Object?>>();
      final after = (written['pages']! as List).cast<Map<String, Object?>>();
      expect(after, hasLength(before.length));
      for (var index = 0; index < before.length; index++) {
        expect(after[index].remove('type'), 'multiLine');
        // Graphics, devices and page geometry survive unchanged.
        expect(after[index], before[index]);
      }
    });

    test('v1 document gets page defaults and the fallback type', () {
      final project = EcadProject.fromJson({
        'format': 'open-ecad',
        'formatVersion': 1,
        'id': 'v1_project',
        'name': 'Starý projekt',
        'revision': 2,
        'pages': [
          {
            'id': 'v1_sheet',
            'name': 'Napájení',
            'number': '01',
            'devices': <Object?>[],
            'wires': <Object?>[],
          },
        ],
      });
      final sheet = ProjectEngine(project).project.pages.single;
      expect((sheet.width, sheet.height, sheet.showFrame), (1100, 780, true));
      expect(sheet.graphics, isEmpty);
      expect(sheet.type, SheetType.multiLine);
      expect(project.toJson()['formatVersion'], 3);
    });

    test('future, malformed or missing versions are unsupported', () {
      final current = _encoded(_project());
      expect(current['formatVersion'], EcadProject.formatVersion);
      for (final version in <Object?>[
        EcadProject.formatVersion + 1,
        99,
        0,
        -1,
        '3',
        3.5,
        null,
      ]) {
        expect(
          () => EcadProject.fromJson({...current, 'formatVersion': version}),
          throwsA(_error('unsupported_format')),
          reason: '$version',
        );
      }
      expect(
        () => EcadProject.fromJson({...current}..remove('formatVersion')),
        throwsA(_error('unsupported_format')),
      );
    });
  });

  group('setSheetType command', () {
    test('changes only the type and follows undo and redo', () {
      final engine = ProjectEngine(_project());
      final before = engine.project.pages.first;
      engine.execute(const [
        SetSheetType('sheet_circuit', SheetType.form),
      ], label: 'Typ listu');
      final changed = engine.project.pages.first;
      expect(changed.type, SheetType.form);
      expect(changed.toJson()..remove('type'), before.toJson()..remove('type'));
      expect(engine.project.pages.last.type, SheetType.cabinetLayout);
      expect(engine.project.revision, 1);
      expect(engine.undoLabel, 'Typ listu');

      expect(engine.undo(), isTrue);
      expect(engine.project.pages.first.type, SheetType.multiLine);
      expect(engine.redo(), isTrue);
      expect(engine.project.pages.first.type, SheetType.form);
      expect(engine.project.revision, 3);
    });

    test('a missing sheet rejects the whole transaction', () {
      final engine = ProjectEngine(_project());
      expect(
        () => engine.execute(const [
          RenameProject('Never applied'),
          SetSheetType('missing_sheet', SheetType.singleLine),
        ]),
        throwsA(_error('missing_sheet')),
      );
      expect(engine.project.name, 'Typed pages');
      expect(engine.project.revision, 0);
      expect(engine.canUndo, isFalse);
    });

    test('codec round-trips and decodes strictly', () {
      final commands = <EcadCommand>[
        for (final type in SheetType.values) SetSheetType('sheet_layout', type),
        AddSheet(
          Sheet(
            id: 'sheet_new',
            name: 'Přehled napájení',
            number: '3',
            type: SheetType.singleLine,
          ),
        ),
      ];
      final data = jsonDecode(
        jsonEncode(commands.map((command) => command.toJson()).toList()),
      );
      expect(
        decodeCommands(data).map((command) => command.toJson()).toList(),
        commands.map((command) => command.toJson()).toList(),
      );
      final engine = ProjectEngine(_project())..execute(decodeCommands(data));
      expect(engine.project.pages.map((sheet) => sheet.type), [
        SheetType.multiLine,
        SheetType.form,
        SheetType.singleLine,
      ]);

      for (final invalid in <Map<String, Object?>>[
        {'type': 'setSheetType', 'sheetId': 'sheet_layout'},
        {'type': 'setSheetType', 'sheetId': 'sheet_layout', 'sheetType': null},
        {
          'type': 'setSheetType',
          'sheetId': 'sheet_layout',
          'sheetType': 'panel',
        },
        {
          'type': 'setSheetType',
          'sheetId': 'sheet_layout',
          'sheetType': 'form',
          'name': 'Extra',
        },
      ]) {
        expect(
          () => EcadCommand.fromJson(invalid),
          throwsA(_error('invalid_schema')),
          reason: '$invalid',
        );
      }
    });
  });

  group('blank form starter', () {
    test('creates valid editable graphics inside the drawing area', () {
      final graphics = SheetTemplates.blankForm();
      for (final graphic in graphics) {
        requireValidDrawingElement(graphic);
        expect(graphic.position.x, greaterThanOrEqualTo(65));
        expect(graphic.position.y, greaterThanOrEqualTo(114));
        expect(graphic.position.x + graphic.width, lessThanOrEqualTo(1035));
        expect(graphic.position.y + graphic.height, lessThan(674));
      }
      expect(
        graphics
            .where((graphic) => graphic.kind == DrawingKind.text)
            .map((graphic) => graphic.text),
        SheetTemplates.formColumns.map((column) => column.$1),
      );
      expect(
        SheetTemplates.formColumns.fold<double>(0, (sum, c) => sum + c.$2),
        closeTo(1, 1e-9),
      );
      expect(
        graphics.where((graphic) => graphic.kind == DrawingKind.path),
        hasLength(
          1 + SheetTemplates.formRows + SheetTemplates.formColumns.length - 1,
        ),
      );
    });

    test('two starters can coexist and stay one undoable page', () {
      final engine = ProjectEngine(_project());
      for (final id in ['sheet_form_a', 'sheet_form_b']) {
        engine.execute([
          AddSheet(
            Sheet(
              id: id,
              name: 'Formulář',
              number: id,
              type: SheetType.form,
              graphics: SheetTemplates.blankForm(),
            ),
          ),
        ]);
      }
      final ids = engine.project.pages
          .expand((sheet) => sheet.graphics)
          .map((graphic) => graphic.id);
      expect(ids.toSet(), hasLength(ids.length));
      expect(engine.project.pages.last.devices, isEmpty);
      expect(engine.project.pages.last.wires, isEmpty);
      engine.undo();
      expect(engine.project.pages, hasLength(3));
      expect(engine.project.pages.last.type, SheetType.form);
    });
  });
}
