// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

const _pixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf2cAAAAASUVORK5CYII=';

Matcher _error(String code) =>
    isA<EcadException>().having((error) => error.code, 'code', code);

DrawingElement _line({String id = 'line'}) => DrawingElement(
  id: id,
  kind: DrawingKind.path,
  position: const Vec2(25, 30),
  width: 100,
  height: 0,
  stroke: '#123456',
  path: [
    PathSegment(verb: PathVerb.moveTo, points: [Vec2.zero]),
    PathSegment(verb: PathVerb.lineTo, points: [const Vec2(100, 0)]),
  ],
);

DrawingElement _text() => DrawingElement(
  id: 'text',
  kind: DrawingKind.text,
  position: const Vec2(50, 60),
  width: 200,
  height: 40,
  text: 'Panel A\nŘídicí obvod',
  fontSize: 15,
  bold: true,
  fill: '#000000',
);

DrawingElement _image() => DrawingElement(
  id: 'image',
  kind: DrawingKind.image,
  position: const Vec2(300, 40),
  width: 25,
  height: 25,
  imageData: _pixelPng,
);

EcadProject _project(List<DrawingElement> graphics) => EcadProject(
  id: 'drawing_project',
  name: 'Synthetic drawing',
  pages: [
    Sheet(
      id: 'drawing_sheet',
      name: 'Drawing',
      number: '1',
      width: 1191,
      height: 842,
      showFrame: false,
      sourcePage: 1,
      graphics: graphics,
    ),
  ],
);

void main() {
  group('versioned native drawing format', () {
    test('loads v1 and writes v2 with legacy canvas defaults', () {
      final old = DemoProject.create().toJson();
      old['formatVersion'] = 1;
      for (final raw in old['pages']! as List) {
        final page = raw as Map<String, Object?>;
        for (final field in [
          'width',
          'height',
          'showFrame',
          'sourcePage',
          'graphics',
        ]) {
          page.remove(field);
        }
      }
      final migrated = EcadProject.fromJson(old);
      final engine = ProjectEngine(migrated);
      expect(engine.project.pages.first.width, 1100);
      expect(engine.project.pages.first.height, 780);
      expect(engine.project.pages.first.showFrame, isTrue);
      expect(engine.project.pages.first.sourcePage, isNull);
      expect(engine.project.pages.first.graphics, isEmpty);
      expect(engine.project.toJson()['formatVersion'], 2);
      expect(engine.project.pages.first.devices, isNotEmpty);
      expect(engine.project.pages.first.wires, isNotEmpty);
    });

    test('round-trips all geometry and styles without default field bloat', () {
      final shape = _line().copyWith(
        height: 80,
        rotation: 45,
        fill: '#aBcDeF',
        strokeWidth: 0.00315,
        opacity: 0.6,
        lineCap: 1,
        lineJoin: 2,
        evenOdd: true,
        dash: [2, 0, 1, 3],
        path: [
          PathSegment(verb: PathVerb.moveTo, points: [Vec2.zero]),
          PathSegment(verb: PathVerb.lineTo, points: [const Vec2(100, 0)]),
          PathSegment(
            verb: PathVerb.cubicTo,
            points: [const Vec2(100, 80), const Vec2(20, 80), const Vec2(0, 0)],
          ),
          PathSegment(verb: PathVerb.close),
        ],
      );
      final original = _project([shape, _text(), _image()]);
      final decoded = EcadProject.fromJson(
        jsonDecode(jsonEncode(original.toJson())),
      );
      expect(decoded.toJson(), original.toJson());
      expect(validateProject(decoded), isEmpty);
      expect(decoded.pages.single.graphicById('line')!.lineCap, 1);
      expect(
        decoded.pages.single.graphicById('text')!.text,
        'Panel A\nŘídicí obvod',
      );
      expect(decoded.pages.single.graphicById('missing'), isNull);
      final compact = _line().toJson();
      expect(
        compact.keys,
        unorderedEquals([
          'id',
          'kind',
          'position',
          'width',
          'height',
          'path',
          'stroke',
        ]),
      );
      expect(shape.path.last.toJson(), {'verb': 'Z'});
    });

    test('copies and owns every mutable graphics collection', () {
      final points = [Vec2.zero];
      final segment = PathSegment(verb: PathVerb.moveTo, points: points);
      final path = [segment];
      final dash = [1.0, 2.0];
      final graphic = _line().copyWith(path: path, dash: dash);
      final graphics = [graphic];
      final sheet = _project(graphics).pages.single;
      final positions = {'line': Vec2.zero};
      final ids = {'line'};
      final add = AddGraphics(sheet.id, graphics);
      final move = MoveGraphics(sheet.id, positions);
      final delete = DeleteGraphics(sheet.id, ids);
      points.clear();
      path.clear();
      dash.clear();
      graphics.clear();
      positions.clear();
      ids.clear();
      expect(segment.points, [Vec2.zero]);
      expect(graphic.path, [segment]);
      expect(graphic.dash, [1, 2]);
      expect(sheet.graphics, [graphic]);
      expect(add.graphics, [graphic]);
      expect(move.positions, {'line': Vec2.zero});
      expect(delete.ids, {'line'});
      for (final mutate in <void Function()>[
        segment.points.clear,
        graphic.path.clear,
        graphic.dash.clear,
        sheet.graphics.clear,
        add.graphics.clear,
        move.positions.clear,
        delete.ids.clear,
      ]) {
        expect(mutate, throwsUnsupportedError);
      }
      expect(graphic.copyWith().stroke, '#123456');
      expect(graphic.copyWith(stroke: null).stroke, isNull);
      expect(sheet.copyWith().sourcePage, 1);
      expect(sheet.copyWith(sourcePage: null).sourcePage, isNull);
    });

    test('supports a drawing document larger than the legacy page count', () {
      final project = _project([]).copyWith(
        pages: List.generate(
          256,
          (index) => Sheet(
            id: 'page_$index',
            name: 'Page ${index + 1}',
            number: '${index + 1}',
            sourcePage: index + 1,
            width: 1191,
            height: 842,
            showFrame: false,
          ),
        ),
      );
      expect(
        ProjectEngine(EcadProject.fromJson(project.toJson())).project.pages,
        hasLength(256),
      );
    });
  });

  group('graphics integrity', () {
    test('rejects invalid dimensions and values from JSON and Dart', () {
      final invalid = <DrawingElement>[
        _line().copyWith(width: -1),
        _line().copyWith(height: double.nan),
        _line().copyWith(position: const Vec2(double.infinity, 0)),
        _line().copyWith(rotation: ProjectLimits.maxCoordinate + 1),
        _line().copyWith(opacity: -0.01),
        _line().copyWith(opacity: 1.01),
        _line().copyWith(opacity: double.nan),
        _line().copyWith(strokeWidth: -1),
        _line().copyWith(fontSize: 0),
        _line().copyWith(dash: [0, 0]),
        _line().copyWith(dash: [-1, 2]),
        _line().copyWith(dash: [double.infinity]),
        _text().copyWith(width: 0),
        _image().copyWith(height: 0),
      ];
      for (final graphic in invalid) {
        expect(
          () => ProjectEngine(_project([graphic])),
          throwsA(_error('invalid_geometry')),
        );
        expect(
          () => DrawingElement.fromJson(graphic.toJson()),
          throwsA(_error('invalid_geometry')),
        );
      }
      expect(() => ProjectEngine(_project([_line()])), returnsNormally);
      expect(
        () => ProjectEngine(_project([_line().copyWith(strokeWidth: 0)])),
        returnsNormally,
      );
    });

    test('rejects invalid colors, text, payload kinds and style enums', () {
      for (final graphic in <DrawingElement>[
        _line().copyWith(stroke: 'red'),
        _line().copyWith(fill: '#123'),
        _line().copyWith(stroke: '#11223344'),
        _line().copyWith(lineCap: -1),
        _line().copyWith(lineJoin: 3),
        _text().copyWith(text: 'bad\u0000text'),
        _text().copyWith(text: 'x' * (ProjectLimits.maxDrawingText + 1)),
        _line().copyWith(text: 'wrong payload'),
        _text().copyWith(path: _line().path),
        _text().copyWith(imageData: _pixelPng),
      ]) {
        expect(
          () => ProjectEngine(_project([graphic])),
          throwsA(_error('invalid_schema')),
        );
        expect(
          () => DrawingElement.fromJson(graphic.toJson()),
          throwsA(_error('invalid_schema')),
        );
      }
      for (final patch in <Map<String, Object?>>[
        {'kind': 'remote'},
        {'url': 'https://example.invalid/a.png'},
        {'bold': 1},
        {'evenOdd': null},
        {'lineCap': 1.0},
      ]) {
        expect(
          () => DrawingElement.fromJson({..._line().toJson(), ...patch}),
          throwsA(_error('invalid_schema')),
        );
      }
    });

    test('path verb arity, numeric bounds and initial move are mandatory', () {
      for (final path in <List<PathSegment>>[
        [],
        [
          PathSegment(verb: PathVerb.lineTo, points: [Vec2.zero]),
        ],
        [PathSegment(verb: PathVerb.close)],
        [PathSegment(verb: PathVerb.moveTo)],
        [
          PathSegment(
            verb: PathVerb.moveTo,
            points: [const Vec2(double.nan, 0)],
          ),
        ],
        [
          PathSegment(verb: PathVerb.moveTo, points: [Vec2.zero]),
          PathSegment(verb: PathVerb.cubicTo, points: [Vec2.zero, Vec2.zero]),
        ],
        [
          PathSegment(verb: PathVerb.moveTo, points: [Vec2.zero]),
          PathSegment(verb: PathVerb.close, points: [Vec2.zero]),
        ],
      ]) {
        final graphic = _line().copyWith(path: path);
        expect(
          () => ProjectEngine(_project([graphic])),
          throwsA(_error('invalid_geometry')),
        );
        expect(
          () => DrawingElement.fromJson(graphic.toJson()),
          throwsA(isA<EcadException>()),
        );
      }
      expect(
        () => PathSegment.fromJson({'verb': 'Q', 'points': <Object?>[]}),
        throwsA(_error('invalid_schema')),
      );
    });

    test(
      'checks sheet size and source page in decoded and direct documents',
      () {
        final project = _project([]);
        for (final sheet in <Sheet>[
          project.pages.single.copyWith(width: 0),
          project.pages.single.copyWith(height: -1),
          project.pages.single.copyWith(width: double.nan),
          project.pages.single.copyWith(height: double.infinity),
          project.pages.single.copyWith(width: ProjectLimits.maxCoordinate + 1),
        ]) {
          expect(
            () => ProjectEngine(project.copyWith(pages: [sheet])),
            throwsA(_error('invalid_geometry')),
          );
          expect(
            () => Sheet.fromJson(sheet.toJson()),
            throwsA(_error('invalid_geometry')),
          );
        }
        expect(
          () => ProjectEngine(
            project.copyWith(
              pages: [project.pages.single.copyWith(sourcePage: 0)],
            ),
          ),
          throwsA(_error('invalid_metadata')),
        );
        expect(
          () => Sheet.fromJson({
            ...project.pages.single.toJson(),
            'sourcePage': 0,
          }),
          throwsA(_error('invalid_metadata')),
        );
      },
    );

    test(
      'PNG is embedded, bounded, and has a valid signature and dimensions',
      () {
        final bytes = base64Decode(_pixelPng);
        final oversizedDimensions = Uint8List.fromList(bytes);
        ByteData.sublistView(
          oversizedDimensions,
        ).setUint32(16, ProjectLimits.maxImageDimension + 1);
        for (final data in <String>[
          '',
          'not base64',
          'https://example.invalid/image.png',
          'data:image/png;base64,$_pixelPng',
          base64Encode(
            utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"/>'),
          ),
          base64Encode(bytes.sublist(0, 8)),
          base64Encode(oversizedDimensions),
        ]) {
          final graphic = _image().copyWith(imageData: data);
          expect(
            () => DrawingElement.fromJson(graphic.toJson()),
            throwsA(_error('invalid_image')),
          );
          expect(
            () => ProjectEngine(_project([graphic])),
            throwsA(_error('invalid_image')),
          );
        }
        expect(() => ProjectEngine(_project([_image()])), returnsNormally);
        final tooLarge = _image().copyWith(
          imageData: 'A' * (ProjectLimits.maxImageBase64Chars + 4),
        );
        expect(
          () => ProjectEngine(_project([tooLarge])),
          throwsA(_error('limit_exceeded')),
        );
        expect(
          () => DrawingElement.fromJson(tooLarge.toJson()),
          throwsA(isA<EcadException>()),
        );
      },
    );

    test(
      'graphics share the project-wide ID namespace and diagnostics locate them',
      () {
        final demo = DemoProject.create();
        for (final id in [
          demo.id,
          demo.pages.first.id,
          demo.pages.first.devices.first.id,
          demo.pages.first.wires.first.id,
        ]) {
          final project = demo.copyWith(
            pages: [
              demo.pages.first.copyWith(graphics: [_line(id: id)]),
              demo.pages.last,
            ],
          );
          expect(() => ProjectEngine(project), throwsA(_error('duplicate_id')));
        }
        final invalid =
            validateProject(_project([_line().copyWith(width: -1)])).single;
        expect(invalid.graphicId, 'line');
        expect(invalid.toJson()['graphicId'], 'line');
        expect(
          () => ProjectEngine(_project([_line(id: '../invalid')])),
          throwsA(_error('invalid_id')),
        );
        final project = _project([_line()]);
        expect(
          () => ProjectEngine(
            project.copyWith(
              pages: [
                project.pages.single,
                project.pages.single.copyWith(id: 'other_sheet', number: '2'),
              ],
            ),
          ),
          throwsA(_error('duplicate_id')),
        );
      },
    );

    test(
      'enforces path, graphic, dash and aggregate payload limits before commit',
      () {
        final line = _line();
        final tooManySegments = line.copyWith(
          path: List.filled(ProjectLimits.maxPathSegments + 1, line.path.first),
        );
        expect(
          () => ProjectEngine(_project([tooManySegments])),
          throwsA(_error('limit_exceeded')),
        );
        expect(
          () => DrawingElement.fromJson(tooManySegments.toJson()),
          throwsA(_error('limit_exceeded')),
        );
        final tooManyGraphics = _project(
          List.filled(ProjectLimits.maxGraphics + 1, line),
        );
        expect(
          () => ProjectEngine(tooManyGraphics),
          throwsA(_error('limit_exceeded')),
        );
        expect(
          () => Sheet.fromJson({
            ..._project([]).pages.single.toJson(),
            'graphics': List<Object?>.filled(
              ProjectLimits.maxGraphics + 1,
              null,
            ),
          }),
          throwsA(_error('limit_exceeded')),
        );
        expect(
          () => ProjectEngine(
            _project([
              line.copyWith(
                dash: List.filled(ProjectLimits.maxDashValues + 1, 1),
              ),
            ]),
          ),
          throwsA(_error('invalid_geometry')),
        );

        final hugeData = 'A' * ProjectLimits.maxImageBase64Chars;
        final payload = _project([]).toJson();
        (payload['pages'] as List).single['graphics'] = List.filled(5, {
          'imageData': hugeData,
        });
        expect(
          () => EcadProject.fromJson(payload),
          throwsA(_error('limit_exceeded')),
        );
      },
    );
  });

  group('atomic graphics commands', () {
    test(
      'all command codecs preserve graphics and reject malformed command shapes',
      () {
        final commands = <EcadCommand>[
          AddGraphics('drawing_sheet', [_line(), _text(), _image()]),
          UpdateGraphic('drawing_sheet', _line().copyWith(rotation: 90)),
          UpdateGraphics('drawing_sheet', [
            _line().copyWith(rotation: 180),
            _text(),
          ]),
          MoveGraphics('drawing_sheet', {'line': const Vec2(10, 20)}),
          DeleteGraphics('drawing_sheet', {'line', 'text'}),
        ];
        final data = jsonDecode(
          jsonEncode(commands.map((c) => c.toJson()).toList()),
        );
        expect(
          decodeCommands(data).map((c) => c.toJson()).toList(),
          commands.map((c) => c.toJson()).toList(),
        );
        for (final command in <Map<String, Object?>>[
          {'type': 'addGraphics', 'sheetId': 'drawing_sheet', 'graphics': []},
          {'type': 'moveGraphics', 'sheetId': 'drawing_sheet', 'positions': {}},
          {
            'type': 'deleteGraphics',
            'sheetId': 'drawing_sheet',
            'ids': ['a', 'a'],
          },
          {'type': 'deleteGraphics', 'sheetId': 'drawing_sheet', 'ids': []},
          {
            'type': 'updateGraphics',
            'sheetId': 'drawing_sheet',
            'graphics': [],
          },
          {
            'type': 'updateGraphics',
            'sheetId': 'drawing_sheet',
            'graphics': [_line().toJson(), _line().toJson()],
          },
          {...commands.first.toJson(), 'execute': 'invalid'},
          {
            'type': 'moveGraphics',
            'sheetId': 'drawing_sheet',
            'positions': {'x' * 129: Vec2.zero.toJson()},
          },
        ]) {
          expect(
            () => EcadCommand.fromJson(command),
            throwsA(isA<EcadException>()),
          );
        }
      },
    );

    test(
      'mixed semantic and drawing edits undo and redo as one transaction',
      () {
        final engine = ProjectEngine(DemoProject.create());
        final before = engine.project;
        final line = _line();
        engine.execute(
          [
            AddGraphics('sheet_power', [line, _text()]),
            MoveDevices('sheet_power', {'dev_motor': const Vec2(500, 500)}),
            MoveGraphics('sheet_power', {'line': const Vec2(10, 20)}),
            UpdateGraphic(
              'sheet_power',
              _text().copyWith(text: 'Edited label', rotation: 90),
            ),
          ],
          label: 'Mixed edit',
          expectedRevision: 0,
        );
        expect(engine.project.revision, 1);
        expect(
          engine.project.pages.first.graphicById('line')!.position,
          const Vec2(10, 20),
        );
        expect(
          engine.project.pages.first.graphicById('text')!.text,
          'Edited label',
        );
        expect(
          engine.project.pages.first.deviceById('dev_motor')!.position,
          const Vec2(500, 500),
        );
        final after = engine.project;
        expect(engine.undo(), isTrue);
        expect(engine.project.toJson(), before.copyWith(revision: 2).toJson());
        expect(engine.redo(), isTrue);
        expect(engine.project.toJson(), after.copyWith(revision: 3).toJson());
        engine.execute([
          DeleteGraphics('sheet_power', {'line'}),
        ]);
        expect(engine.project.pages.first.graphics.map((g) => g.id), ['text']);
        expect(
          engine.project.pages.first.devices,
          hasLength(before.pages.first.devices.length),
        );
        engine.undo();
        expect(engine.project.pages.first.graphics, hasLength(2));
      },
    );

    test(
      'invalid graphics roll back a mixed transaction and preserve redo',
      () {
        final engine = ProjectEngine(_project([_line()]));
        engine.execute([const RenameProject('Changed')]);
        engine.undo();
        final before = engine.project;
        for (final command in <EcadCommand>[
          AddGraphics('drawing_sheet', [_text().copyWith(width: -1)]),
          AddGraphics('drawing_sheet', [_line()]),
          AddGraphics('drawing_sheet', [_text(), _text()]),
          AddGraphics('drawing_sheet', []),
          UpdateGraphic('drawing_sheet', _line().copyWith(opacity: 2)),
          UpdateGraphic('drawing_sheet', _line(id: 'missing')),
          UpdateGraphics('drawing_sheet', [_line().copyWith(width: -1)]),
          UpdateGraphics('drawing_sheet', [_line(), _line()]),
          UpdateGraphics('drawing_sheet', [_line(id: 'missing')]),
          UpdateGraphics('drawing_sheet', []),
          MoveGraphics('drawing_sheet', {'line': const Vec2(double.nan, 0)}),
          MoveGraphics('drawing_sheet', {'missing': Vec2.zero}),
          MoveGraphics('drawing_sheet', {}),
          DeleteGraphics('drawing_sheet', {'missing'}),
          DeleteGraphics('drawing_sheet', {}),
          AddGraphics('missing_sheet', [_text()]),
        ]) {
          expect(
            () => engine.execute([
              const RenameProject('Must roll back'),
              command,
            ]),
            throwsA(isA<EcadException>()),
          );
          expect(identical(engine.project, before), isTrue);
          expect(engine.canUndo, isFalse);
          expect(engine.canRedo, isTrue);
        }
        expect(engine.redo(), isTrue);
        expect(engine.project.name, 'Changed');
      },
    );

    test('copyWith supports duplicate geometry with a fresh ID', () {
      final line = _line();
      final engine = ProjectEngine(_project([line]));
      engine.execute([
        AddGraphics('drawing_sheet', [
          line.copyWith(id: 'copy', position: const Vec2(20, 40)),
        ]),
      ]);
      expect(engine.project.pages.single.graphics, hasLength(2));
      expect(
        engine.project.pages.single
            .graphicById('copy')!
            .path
            .map((s) => s.toJson())
            .toList(),
        line.path.map((s) => s.toJson()).toList(),
      );
    });

    test('bulk update rotates over 1000 elements in one ordered undo step', () {
      final graphics = List.generate(2001, (index) => _line(id: 'line_$index'));
      final engine = ProjectEngine(_project(graphics));
      final before = engine.project;
      final replacements =
          graphics.reversed
              .map((graphic) => graphic.copyWith(rotation: 90))
              .toList();
      final command = UpdateGraphics('drawing_sheet', replacements);
      replacements.clear();
      expect(command.graphics, hasLength(2001));
      expect(command.graphics.clear, throwsUnsupportedError);
      engine.execute([command], label: 'Rotate all graphics');
      expect(engine.project.revision, 1);
      expect(
        engine.project.pages.single.graphics.every(
          (graphic) => graphic.rotation == 90,
        ),
        isTrue,
      );
      expect(
        engine.project.pages.single.graphics.map((graphic) => graphic.id),
        graphics.map((graphic) => graphic.id),
      );
      final after = engine.project;
      expect(engine.undo(), isTrue);
      expect(engine.project.toJson(), before.copyWith(revision: 2).toJson());
      expect(engine.canUndo, isFalse);
      expect(engine.redo(), isTrue);
      expect(engine.project.toJson(), after.copyWith(revision: 3).toJson());
    });
  });
}
