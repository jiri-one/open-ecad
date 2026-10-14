import 'dart:convert';
import 'dart:ui' as ui;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/ecad_services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _palette = CanvasPalette(
  background: Colors.white,
  paper: Colors.white,
  ink: Colors.black,
  muted: Colors.black,
  grid: Colors.black,
  selection: Colors.black,
  wire: Colors.black,
  sheetBorder: Colors.black,
  highContrast: true,
);

/// Symbol-local geometry in a form both renderers can be reduced to.
class _Glyph {
  final segments = <String>[];
  final circles = <String>[];
  final fills = <String>[];
  final dashes = <(Offset, Offset)>[];
  final curves = <(Offset, Offset, double)>[];
  final texts = <Offset>[];
  final points = <Offset>[];

  void segment(Offset a, Offset b) {
    final first = _key(a);
    final second = _key(b);
    segments.add(
      first.compareTo(second) <= 0 ? '$first $second' : '$second $first',
    );
    points.addAll([a, b]);
  }

  void outline(Rect rect) {
    segment(rect.topLeft, rect.topRight);
    segment(rect.topRight, rect.bottomRight);
    segment(rect.bottomRight, rect.bottomLeft);
    segment(rect.bottomLeft, rect.topLeft);
  }

  void circle(Offset center, double radius, {required bool filled}) {
    circles.add('${filled ? 'fill' : 'stroke'} ${_key(center)} r${_n(radius)}');
    points.addAll([
      center - Offset(radius, radius),
      center + Offset(radius, radius),
    ]);
  }

  static String _n(double value) =>
      (value.abs() < .005 ? 0.0 : value).toStringAsFixed(2);
  static String _key(Offset point) => '${_n(point.dx)},${_n(point.dy)}';
}

Future<_Glyph> _paintedGlyph(WidgetTester tester, DeviceKind kind) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SymbolPreview(kind: kind, palette: _palette, size: 64),
      ),
    ),
  );
  final painter =
      tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(SymbolPreview),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter!;
  final canvas = TestRecordingCanvas();
  painter.paint(canvas, const Size(64, 64));
  final glyph = _Glyph();
  for (final recorded in canvas.invocations) {
    final arguments = recorded.invocation.positionalArguments;
    switch (recorded.invocation.memberName) {
      case #drawLine:
        glyph.segment(arguments[0] as Offset, arguments[1] as Offset);
      case #drawRect:
        final rect = arguments[0] as Rect;
        if ((arguments[1] as Paint).style == PaintingStyle.stroke) {
          glyph.outline(rect);
        } else {
          glyph.fills.add(
            '${_Glyph._key(rect.topLeft)} ${_Glyph._key(rect.bottomRight)}',
          );
          glyph.points.addAll([rect.topLeft, rect.bottomRight]);
        }
      case #drawCircle:
        glyph.circle(
          arguments[0] as Offset,
          arguments[1] as double,
          filled: (arguments[2] as Paint).style == PaintingStyle.fill,
        );
      case #drawPath:
        for (final metric in (arguments[0] as Path).computeMetrics()) {
          final start = metric.getTangentForOffset(0)!.position;
          final end = metric.getTangentForOffset(metric.length)!.position;
          for (var step = 0; step <= 20; step++) {
            glyph.points.add(
              metric.getTangentForOffset(metric.length * step / 20)!.position,
            );
          }
          // Straight pieces come only from dashed strokes.
          if ((metric.length - (end - start).distance).abs() < 1e-3) {
            glyph.dashes.add((start, end));
          } else {
            glyph.curves.add((start, end, metric.length));
          }
        }
      case #drawParagraph:
        final paragraph = arguments[0] as ui.Paragraph;
        final offset = arguments[1] as Offset;
        glyph.texts.add(
          Offset(
            offset.dx + paragraph.maxIntrinsicWidth / 2,
            offset.dy + paragraph.alphabeticBaseline,
          ),
        );
        glyph.points.addAll([
          offset,
          offset + Offset(paragraph.maxIntrinsicWidth, paragraph.height),
        ]);
    }
  }
  return glyph;
}

/// Reads the absolute M/L/H/V/C/S/Z subset written by [ProjectExportService].
_Glyph _exportedGlyph(DeviceKind kind) {
  final glyph = _Glyph();
  final svg = ProjectExportService.symbolSvg(kind);
  final elements = RegExp(
    r'<(path|circle|rect|text)\b([^>]*?)/?>(?:[^<]*</text>)?',
  ).allMatches(svg);
  expect(
    elements.map((element) => element.group(0)).join(),
    svg,
    reason: '${kind.name} uses an element this reader does not compare',
  );
  for (final element in elements) {
    final attributes = {
      for (final match in RegExp(
        r'([\w-]+)="([^"]*)"',
      ).allMatches(element.group(2)!))
        match.group(1)!: match.group(2)!,
    };
    double number(String name) => double.parse(attributes[name]!);
    final stroked = attributes['stroke'] != 'none';
    final filled = (attributes['fill'] ?? 'none') != 'none';
    switch (element.group(1)) {
      case 'circle':
        final center = Offset(number('cx'), number('cy'));
        if (filled) glyph.circle(center, number('r'), filled: true);
        if (stroked) glyph.circle(center, number('r'), filled: false);
      case 'rect':
        final rect = Rect.fromLTWH(
          number('x'),
          number('y'),
          number('width'),
          number('height'),
        );
        if (filled) {
          glyph.fills.add(
            '${_Glyph._key(rect.topLeft)} ${_Glyph._key(rect.bottomRight)}',
          );
        }
        if (stroked) glyph.outline(rect);
      case 'text':
        expect(attributes['text-anchor'], 'middle');
        glyph.texts.add(Offset(number('x'), number('y')));
      case 'path':
        if (attributes.containsKey('stroke-dasharray')) {
          expect(attributes['stroke-dasharray'], '3 3');
        }
        _readPath(
          glyph,
          attributes['d']!,
          dashed: attributes.containsKey('stroke-dasharray'),
        );
    }
  }
  return glyph;
}

void _readPath(_Glyph glyph, String data, {required bool dashed}) {
  final tokens =
      RegExp(
        r'[MLHVCSZ]|-?\d*\.?\d+',
      ).allMatches(data).map((match) => match.group(0)!).toList();
  var index = 0;
  var command = '';
  var current = Offset.zero;
  var start = Offset.zero;
  var control = Offset.zero;
  final lines = <(Offset, Offset)>[];
  final samples = <Offset>[];
  var curved = false;
  double number() => double.parse(tokens[index++]);
  Offset point() => Offset(number(), number());
  void flush() {
    if (curved) {
      var length = 0.0;
      for (var i = 1; i < samples.length; i++) {
        length += (samples[i] - samples[i - 1]).distance;
      }
      glyph.curves.add((samples.first, samples.last, length));
      glyph.points.addAll(samples);
    } else {
      for (final (a, b) in lines) {
        if (dashed) {
          glyph.dashes.add((a, b));
          glyph.points.addAll([a, b]);
        } else {
          glyph.segment(a, b);
        }
      }
    }
    lines.clear();
    samples.clear();
    curved = false;
  }

  void lineTo(Offset next) {
    lines.add((current, next));
    samples.add(next);
    current = next;
  }

  void cubicTo(Offset c1, Offset c2, Offset end) {
    final from = current;
    for (var step = 1; step <= 400; step++) {
      final t = step / 400;
      final u = 1 - t;
      samples.add(
        from * (u * u * u) +
            c1 * (3 * u * u * t) +
            c2 * (3 * u * t * t) +
            end * (t * t * t),
      );
    }
    control = c2;
    current = end;
    curved = true;
  }

  while (index < tokens.length) {
    if (RegExp(r'^[A-Z]$').hasMatch(tokens[index])) command = tokens[index++];
    switch (command) {
      case 'M':
        flush();
        current = start = point();
        samples.add(current);
        command = 'L';
      case 'L':
        lineTo(point());
      case 'H':
        lineTo(Offset(number(), current.dy));
      case 'V':
        lineTo(Offset(current.dx, number()));
      case 'C':
        final c1 = point();
        final c2 = point();
        cubicTo(c1, c2, point());
      case 'S':
        final c1 = current * 2 - control;
        final c2 = point();
        cubicTo(c1, c2, point());
      case 'Z':
        lineTo(start);
      default:
        fail('Unsupported path command "$command" in "$data".');
    }
  }
  flush();
}

Device _device(String designation, DeviceKind kind, double x, double y) =>
    Device(
      id: designation.substring(1).toLowerCase(),
      kind: kind,
      designation: designation,
      position: Vec2(x, y),
    );

Wire _wire(String id, Device from, String fromPort, Device to, String toPort) =>
    Wire(
      id: id,
      from: TerminalRef(deviceId: from.id, portId: fromPort),
      to: TerminalRef(deviceId: to.id, portId: toPort),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'canvas and vector export draw the same geometry for every kind',
    (tester) async {
      for (final kind in DeviceKind.values) {
        final painted = await _paintedGlyph(tester, kind);
        final exported = _exportedGlyph(kind);
        final name = kind.name;
        expect(
          painted.segments..sort(),
          exported.segments..sort(),
          reason: '$name strokes',
        );
        expect(
          painted.circles..sort(),
          exported.circles..sort(),
          reason: '$name circles',
        );
        expect(painted.fills..sort(), exported.fills..sort(), reason: name);

        // Canvas dashes are separate 3-unit pieces of the exported 3 3 pattern.
        for (final (from, to) in exported.dashes) {
          final direction = (to - from) / (to - from).distance;
          final pieces =
              painted.dashes.where((piece) {
                  final along = (piece.$1 - from).distance;
                  return (from + direction * along - piece.$1).distance < 1e-6;
                }).toList()
                ..sort(
                  (a, b) =>
                      (a.$1 - from).distance.compareTo((b.$1 - from).distance),
                );
          expect(pieces, isNotEmpty, reason: '$name dashes');
          for (final (index, piece) in pieces.indexed) {
            expect((piece.$1 - from).distance, closeTo(index * 6, 1e-6));
            expect((piece.$2 - piece.$1).distance, lessThanOrEqualTo(3 + 1e-6));
          }
          expect(
            (to - pieces.last.$2).distance,
            lessThanOrEqualTo(3 + 1e-6),
            reason: '$name dashes reach the end',
          );
          painted.dashes.removeWhere(pieces.contains);
        }
        expect(painted.dashes, isEmpty, reason: '$name stray dashes');

        expect(painted.curves, hasLength(exported.curves.length), reason: name);
        for (final (index, curve) in painted.curves.indexed) {
          final other = exported.curves[index];
          expect(curve.$1, offsetMoreOrLessEquals(other.$1, epsilon: .01));
          expect(curve.$2, offsetMoreOrLessEquals(other.$2, epsilon: .01));
          expect(curve.$3, closeTo(other.$3, other.$3 * .005), reason: name);
        }

        expect(painted.texts, hasLength(exported.texts.length), reason: name);
        // The motor predates centered symbol text and keeps its hand placement.
        if (kind != DeviceKind.motor) {
          for (final (index, anchor) in painted.texts.indexed) {
            expect(
              anchor,
              offsetMoreOrLessEquals(exported.texts[index], epsilon: .01),
              reason: '$name text anchor',
            );
          }
        }
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('drawings stay inside selection bounds and reach every port', (
    tester,
  ) async {
    for (final kind in DeviceKind.values) {
      final definition = SymbolCatalog.definitionFor(kind);
      final glyph = await _paintedGlyph(tester, kind);
      // Stroke widths may extend past the outline; selection adds 4 more.
      final bounds = Rect.fromCenter(
        center: Offset.zero,
        width: definition.width,
        height: definition.height,
      ).inflate(1);
      for (final point in glyph.points) {
        expect(
          bounds.contains(point),
          isTrue,
          reason: '${kind.name} draws at $point outside $bounds',
        );
      }
      final endpoints =
          glyph.segments.expand((segment) => segment.split(' ')).toSet();
      for (final port in definition.ports) {
        expect(
          endpoints,
          contains(_Glyph._key(Offset(port.position.x, port.position.y))),
          reason: '${kind.name}:${port.id} has no lead',
        );
      }
    }
  });

  testWidgets('library finds, describes and places the new symbols', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = EditorController();
    addTearDown(app.dispose);
    await tester.pumpWidget(OpenEcadApp(controller: app));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, 'Přístroje'));
    await tester.pumpAndSettle();
    final search = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == 'Najít symbol…',
    );
    for (final (query, labels, subtitle) in [
      (
        'třípól',
        ['Třípólový jistič', 'Třípólový odpojovač'],
        'Q · 6 připojovacích bodů',
      ),
      (
        'transformátor',
        ['Transformátor', 'Transformátor proudu'],
        'T · 4 připojovací body',
      ),
      ('pojist', ['Pojistka'], 'F · 2 připojovací body'),
      ('metr', ['Ampérmetr', 'Voltmetr'], 'P · 2 připojovací body'),
      (
        'kontakt',
        ['Spínací kontakt', 'Rozpínací kontakt'],
        'S · 2 připojovací body',
      ),
      ('tlačítko', ['Spínací tlačítko'], 'S · 2 připojovací body'),
      ('odpojovač', ['Odpojovač', 'Třípólový odpojovač'], null),
    ]) {
      await tester.enterText(search, query);
      await tester.pumpAndSettle();
      for (final label in labels) {
        expect(find.text(label), findsOneWidget, reason: query);
      }
      if (subtitle != null) {
        expect(find.text(subtitle), findsNWidgets(labels.length));
      }
    }

    await tester.enterText(search, 'třípólový jistič');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Třípólový jistič'));
    await tester.pumpAndSettle();
    expect(app.mode, CanvasMode.place);
    expect(app.placingKind, DeviceKind.threePoleBreaker);
    final count = app.sheet.devices.length;
    await tester.tapAt(tester.getCenter(find.byType(SchematicCanvas)));
    await tester.pumpAndSettle();
    expect(app.sheet.devices, hasLength(count + 1));
    final placed = app.sheet.devices.last;
    expect(placed.kind, DeviceKind.threePoleBreaker);
    expect(placed.designation, matches(RegExp(r'^-Q\d+$')));
    expect(app.selectedIds, {placed.id});
    app.rotateSelection();
    await tester.pumpAndSettle();
    expect(app.sheet.deviceById(placed.id)!.rotation, 90);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('wire tool and selection address individual poles', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final breaker = _device('-Q1', DeviceKind.threePoleBreaker, 400, 300);
    final fuse = _device('-F1', DeviceKind.fuse, 420, 420);
    final sheet = Sheet(
      id: 'poles',
      name: 'Póly',
      number: '1',
      devices: [breaker, fuse],
    );
    final controller = SchematicViewportController();
    final pairs = <(TerminalRef, TerminalRef)>[];
    var selection = <String>{};
    Future<void> mount(CanvasMode mode) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SchematicCanvas(
            sheet: sheet,
            selectedIds: selection,
            mode: mode,
            showGrid: true,
            palette: _palette,
            controller: controller,
            onSelectionChanged: (ids) => selection = ids,
            onMoveDevices: (_) {},
            onPlaceDevice: (_, _) {},
            onConnect: (from, to) => pairs.add((from, to)),
            onDeleteWire: (_) {},
          ),
        ),
      );
      controller.reset();
      await tester.pump();
    }

    await mount(CanvasMode.wire);
    // Canvas and sheet coordinates coincide at zoom 1 on this viewport.
    final pole = worldPortPosition(breaker, '6');
    final input = worldPortPosition(fuse, 'in');
    expect(pole.x, input.x);
    await tester.tapAt(Offset(pole.x + 3, pole.y));
    await tester.tapAt(Offset(input.x, input.y - 2));
    expect(pairs, [
      (
        const TerminalRef(deviceId: 'q1', portId: '6'),
        const TerminalRef(deviceId: 'f1', portId: 'in'),
      ),
    ]);

    await mount(CanvasMode.select);
    await tester.tapAt(const Offset(431, 300));
    expect(selection, {'q1'}, reason: 'A click beside the third pole.');
    expect(tester.takeException(), isNull);
  });

  test('local assistant inserts the new kinds from Czech and English', () {
    final project = DemoProject.create();
    final assistant = AssistantService();
    for (final (prompt, kind, designation) in [
      ('Přidej pojistku F3', DeviceKind.fuse, 'F3'),
      ('Vlož rozpínací kontakt', DeviceKind.contactNc, null),
      ('Přidej spínací kontakt', DeviceKind.contactNo, null),
      ('Přidej tlačítko S5', DeviceKind.pushbuttonNo, 'S5'),
      ('Přidej třípólový jistič Q7', DeviceKind.threePoleBreaker, 'Q7'),
      ('Add a three-pole disconnector', DeviceKind.threePoleDisconnector, null),
      ('Přidej odpojovač', DeviceKind.disconnector, null),
      ('Přidej jistič B16', DeviceKind.breaker, null),
      ('Přidej transformátor proudu TA7', DeviceKind.currentTransformer, 'TA7'),
      ('Add current transformer', DeviceKind.currentTransformer, null),
      ('Přidej transformátor T2', DeviceKind.transformer, 'T2'),
      ('Přidej ampérmetr PA9', DeviceKind.ammeter, 'PA9'),
      ('Add voltmeter P4', DeviceKind.voltmeter, 'P4'),
    ]) {
      final proposal = assistant.propose(
        prompt,
        project: project,
        sheetId: 'sheet_power',
      );
      expect(
        proposal.supported,
        isTrue,
        reason: '$prompt: ${proposal.message}',
      );
      final device = proposal.preview(project).pages.first.devices.last;
      expect(device.kind, kind, reason: prompt);
      expect(
        device.designation,
        designation ??
            matches(
              RegExp('^-${SymbolCatalog.definitionFor(kind).prefix}\\d+\$'),
            ),
        reason: prompt,
      );
    }
  });

  test('model proposals may use every kind from the request schema', () async {
    List<Object?>? offered;
    final client = MockClient((request) async {
      final dynamic body = jsonDecode(request.body);
      offered =
          body['format']['properties']['actions']['items']['anyOf'][0]['properties']['kind']['enum']
              as List<Object?>;
      return http.Response(
        jsonEncode({
          'message': {
            'content': jsonEncode({
              'label': 'Měření proudu',
              'message': 'Transformátor proudu a ampérmetr.',
              'actions': [
                {'op': 'insert_device', 'kind': 'currentTransformer'},
                {'op': 'insert_device', 'kind': 'ammeter', 'designation': 'P7'},
              ],
            }),
          },
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    addTearDown(client.close);
    final project = DemoProject.create();
    final proposal = await AssistantService(
      httpClient: client,
    ).proposeWithOllama(
      'Přidej měření proudu.',
      project: project,
      sheetId: 'sheet_power',
      settings: const AiProviderSettings(),
    );
    expect(offered, DeviceKind.values.map((kind) => kind.name).toList());
    expect(proposal.supported, isTrue, reason: proposal.message);
    final added = proposal.preview(project).pages.first.devices.reversed;
    expect(added.first.designation, 'P7');
    expect(added.first.kind, DeviceKind.ammeter);
    expect(added.elementAt(1).kind, DeviceKind.currentTransformer);
  });

  test('SVG and PDF exports attach wires to the exact pole terminals', () async {
    final breaker = _device('-Q1', DeviceKind.threePoleBreaker, 200, 200);
    final fuses = [
      for (final (index, x) in [180.0, 200.0, 220.0].indexed)
        _device('-F${index + 1}', DeviceKind.fuse, x, 330),
    ];
    final currentTransformer = _device(
      '-T1',
      DeviceKind.currentTransformer,
      500,
      200,
    );
    final ammeter = _device('-P1', DeviceKind.ammeter, 420, 200);
    final others = [
      for (final (index, kind) in DeviceKind.values.indexed)
        _device(
          '-${SymbolCatalog.definitionFor(kind).prefix}${index + 10}',
          kind,
          100.0 + index % 6 * 150,
          450.0 + index ~/ 6 * 110,
        ),
    ];
    final wires = [
      for (final (index, pole) in ['2', '4', '6'].indexed)
        _wire('pole_$index', breaker, pole, fuses[index], 'in'),
      _wire('secondary_out', currentTransformer, 's1', ammeter, 'in'),
      _wire('secondary_back', ammeter, 'out', currentTransformer, 's2'),
    ];
    final project = EcadProject(
      id: 'export_project',
      name: 'Měření a jištění',
      pages: [
        Sheet(
          id: 'export_sheet',
          name: 'Silové obvody',
          number: '1',
          devices: [breaker, ...fuses, currentTransformer, ammeter, ...others],
          wires: wires,
        ),
      ],
    );
    expect(
      ProjectExportService.symbolSvg(DeviceKind.ammeter),
      contains('>A</text>'),
    );
    expect(
      ProjectExportService.symbolSvg(DeviceKind.voltmeter),
      contains('>V</text>'),
    );
    final exporter = ProjectExportService();
    final svg = exporter.svg(project);
    for (final kind in DeviceKind.values) {
      expect(
        svg,
        contains(ProjectExportService.symbolSvg(kind)),
        reason: kind.name,
      );
    }
    for (final label in [
      'Třípólový jistič',
      'Třípólový odpojovač',
      'Pojistka',
      'Odpojovač',
      'Transformátor proudu',
      'Rozpínací kontakt',
      'Spínací tlačítko',
      'Ampérmetr',
      'Voltmetr',
    ]) {
      expect(svg, contains('>$label</text>'));
    }
    String n(double value) =>
        value.toStringAsFixed(6).replaceFirst(RegExp(r'\.?0+$'), '');
    final devices = {
      for (final device in project.pages.single.devices) device.id: device,
    };
    for (final wire in wires) {
      final from = worldPortPosition(
        devices[wire.from.deviceId]!,
        wire.from.portId,
      );
      final to = worldPortPosition(devices[wire.to.deviceId]!, wire.to.portId);
      expect(
        svg,
        contains(
          RegExp(
            '<polyline points="${n(from.x)},${n(from.y)} [^"]*${n(to.x)},${n(to.y)}"',
          ),
        ),
        reason: wire.id,
      );
    }

    final pdf = await exporter.pdf(project);
    expect(utf8.decode(pdf.take(5).toList()), '%PDF-');
    expect(pdf.length, greaterThan(10000));
  });
}
