// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/document_layout.dart';
import 'package:open_ecad/services/export_fonts.dart';
import 'package:open_ecad/services/mounting_annotations.dart';
import 'package:open_ecad/services/project_export.dart';
import 'package:open_ecad/services/report_layout.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ExportFonts.load);
  final exporter = ProjectExportService();

  test(
    'PDF links resolve across derived pages and mixed paper transforms',
    () async {
      final project = _project();
      final before = jsonEncode(project.toJson());
      final layout = layoutDocument(project);
      expect(layout.pages.length, greaterThan(project.pages.length));
      final bytes = await exporter.pdf(project);
      final pdf = _PdfNavigation(bytes);
      expect(pdf.pages.length, layout.pages.length);
      for (var i = 0; i < layout.pages.length; i++) {
        final sheet = layout.pages[i].sheet;
        for (final device in sheet.devices) {
          _expectDestination(pdf, device.id, i, sheet, device.position);
        }
        for (final marker in sheet.continuations) {
          _expectDestination(pdf, marker.id, i, sheet, marker.position);
        }
      }
      final first = project.pages.first;
      final pair =
          pdf.links.where((l) => l.page == 0 && l.target == 'peer').single;
      final font = pw.Font.ttf(
        (await ExportFonts.load()).regular,
      ).getFont(pw.Context(document: PdfDocument()));
      final metrics = font.stringMetrics('PAIR -> 2') * 9;
      _expectRect(
        pair.rect,
        _paperRect(
          first,
          Rect.fromLTRB(
            108 + math.min(0, metrics.left) - .5,
            188 - metrics.bottom - .5,
            108 + math.max(metrics.advanceWidth, metrics.right) + .5,
            188 - metrics.top + .5,
          ),
        ),
      );
      expect(
        pdf.links.where((l) => l.page == 0).map((l) => l.target),
        containsAll(['same-b', 'same-a', 'peer', 'main', 'terminal-2']),
      );
      expect(pdf.links.map((l) => l.target), isNot(contains('orphan')));
      expect(jsonEncode(project.toJson()), before);
      const directory = String.fromEnvironment('EXPORT_QA_DIR');
      if (directory.isNotEmpty) {
        Directory(directory).createSync(recursive: true);
        File('$directory/navigation.pdf').writeAsBytesSync(bytes);
      }
    },
  );

  test(
    'device references preserve every appearance and wrapped label fragment',
    () async {
      final project = _project();
      final pdf = _PdfNavigation(await exporter.pdf(project));
      final first = pdf.links.where((l) => l.page == 0).toList();
      for (final id in ['main', 'repeat', 'terminal-2']) {
        expect(first.where((l) => l.target == id), isNotEmpty);
      }
      final mainPage = layoutDocument(
        project,
      ).pages.indexWhere((p) => p.sheet.id == 'second');
      expect(
        pdf.links.where((l) => l.page == mainPage && l.target == 'aux'),
        isNotEmpty,
      );
      expect(
        pdf.links.where((l) => l.page == mainPage && l.target == 'repeat'),
        isNotEmpty,
      );
      final source = project.pages.first.devices.first;
      final sourcePoint = _paperPoint(project.pages.first, source.position);
      for (final link in first.where(
        (l) => ['main', 'repeat'].contains(l.target),
      )) {
        expect(
          link.rect.contains(Offset(sourcePoint.x, sourcePoint.y)),
          isFalse,
        );
        expect(link.rect.height, lessThan(15));
      }
    },
  );

  test(
    'single-sheet export keeps local links and omits excluded or ambiguous peers',
    () async {
      final project = _project();
      final pdf = _PdfNavigation(await exporter.pdf(project, sheetId: 'first'));
      expect(pdf.pages, hasLength(1));
      expect(pdf.links.map((l) => l.target).toSet(), {
        'same-a',
        'same-b',
        'terminal-2',
        'terminal-local-copy',
      });
      expect(pdf.destinations.keys, isNot(contains('peer')));
      final first = project.pages.first;
      final ambiguous = project.copyWith(
        pages: [
          first.copyWith(
            continuations: [
              ...first.continuations,
              const ContinuationMarker(
                id: 'same-c',
                linkId: 'local',
                position: Vec2(800, 450),
              ),
            ],
          ),
          ...project.pages.skip(1),
        ],
      );
      final ambiguousPdf = _PdfNavigation(
        await exporter.pdf(ambiguous, sheetId: 'first'),
      );
      expect(ambiguousPdf.links.map((l) => l.target).toSet(), {
        'terminal-2',
        'terminal-local-copy',
      });
      expect(exporter.svg(ambiguous), contains('LOCAL -&gt; 1'));
    },
  );

  test(
    'multi-target continuation labels retain separate links through wrapping',
    () async {
      final source = _project();
      final project = source.copyWith(
        pages: [
          ...source.pages,
          Sheet(
            id: 'third',
            name: 'Long reference',
            number: '3',
            structure: StructureContext(functionPath: ['LONG_REFERENCE_' * 4]),
            continuations: const [
              ContinuationMarker(
                id: 'third-peer',
                linkId: 'pair',
                position: Vec2(600, 200),
              ),
            ],
          ),
        ],
      );
      final pdf = _PdfNavigation(await exporter.pdf(project));
      final fragments =
          pdf.links
              .where((l) => l.page == 0 && l.target == 'third-peer')
              .toList();
      expect(fragments.length, greaterThanOrEqualTo(2));
      expect(fragments.map((l) => l.rect.top).toSet().length, fragments.length);
      expect(
        pdf.links.where((l) => l.page == 0 && l.target == 'peer'),
        hasLength(1),
      );
      expect(pdf.destinations['third-peer']!.page, pdf.pages.length - 1);
    },
  );

  test('PDF clips clickable labels at the page edge', () async {
    final source = _project();
    final first = source.pages.first;
    final project = source.copyWith(
      pages: [
        first.copyWith(
          continuations: [
            first.continuations.first.copyWith(position: const Vec2(1190, 200)),
            ...first.continuations.skip(1),
          ],
        ),
        ...source.pages.skip(1),
      ],
    );
    final pdf = _PdfNavigation(await exporter.pdf(project));
    final link = pdf.links.singleWhere(
      (l) => l.page == 0 && l.target == 'peer',
    );
    expect(
      link.rect.right,
      closeTo(first.paperSizeMm.width * PdfPageFormat.mm, .001),
    );
    expect(link.rect.width, lessThan(2));
  });

  test(
    'mounting and terminal plans link exact labels to designated schematic identities',
    () async {
      final project = _project();
      final resolver = ProjectResolver(project);
      final layout = layoutDocument(project);
      final pdf = _PdfNavigation(await exporter.pdf(project));
      for (final sheet in project.pages.where((p) => p.mountingView != null)) {
        final page = layout.pages.indexWhere((p) => p.sheet.id == sheet.id);
        final links = pdf.links.where((l) => l.page == page).toList();
        expect(links.map((l) => l.target).toSet(), {
          'main',
          'terminal-1',
          'terminal-2',
        });
        final annotations = layoutMountingAnnotations(resolver, sheet);
        expect(annotations.any((a) => a.rotated), isTrue);
        final placements =
            resolver.layouts[sheet.mountingView!.layoutId]!.placements;
        for (final annotation in annotations) {
          final placement = placements.singleWhere(
            (p) => p.id == annotation.placementId,
          );
          final target = resolver.schematicOccurrence(placement.componentId);
          if (target == null) continue;
          final viewport = sheet.mountingView!.viewport;
          final bounds = annotation.bounds.intersect(
            Rect.fromLTWH(
              viewport.x,
              viewport.y,
              viewport.width,
              viewport.height,
            ),
          );
          _expectRect(
            links.singleWhere((l) => l.target == target.device.id).rect,
            _paperRect(sheet, bounds),
          );
        }
      }
      expect(resolver.schematicOccurrence('relay')!.device.id, 'main');
      expect(
        resolver.schematicOccurrence('relay')!.device.mode,
        OccurrenceMode.reference,
      );
      expect(resolver.schematicOccurrence('ambiguous'), isNull);
      expect(
        _PdfNavigation(await exporter.pdf(project, sheetId: 'mounting')).links,
        isEmpty,
      );
    },
  );

  test(
    'component report fragments use paper coordinates and omit unresolved rows',
    () async {
      final project = _project();
      final resolver = ProjectResolver(project);
      final document = layoutDocument(project);
      final pdf = _PdfNavigation(await exporter.pdf(project));
      final sheet = project.sheetById('bom')!;
      final layout = layoutReport(project, sheet);
      var count = 0;
      for (final report in layout.pages) {
        final page = document.pages.indexWhere(
          (p) => p.sheet.id == sheet.id && p.report!.index == report.index,
        );
        final links = pdf.links.where((l) => l.page == page).toList();
        final expected = layoutReportNavigationLinks(resolver, layout, report);
        expect(links.length, expected.length);
        for (var i = 0; i < expected.length; i++) {
          expect(links[i].target, expected[i].target.device.id);
          final b = expected[i].bounds;
          _expectRect(
            links[i].rect,
            Rect.fromLTRB(
              b.left * PdfPageFormat.mm,
              (sheet.paperSizeMm.height - b.bottom) * PdfPageFormat.mm,
              b.right * PdfPageFormat.mm,
              (sheet.paperSizeMm.height - b.top) * PdfPageFormat.mm,
            ),
          );
          count++;
        }
      }
      expect(count, greaterThanOrEqualTo(3));
      expect(
        _PdfNavigation(await exporter.pdf(project, sheetId: 'bom')).links,
        isEmpty,
      );
    },
  );

  test(
    'missing model references fail validation instead of exporting broken links',
    () async {
      final project = _project();
      await expectLater(
        exporter.pdf(project.copyWith(continuationLinks: const [])),
        throwsA(isA<EcadException>()),
      );
      final source = project.pages.first;
      await expectLater(
        exporter.pdf(
          project.copyWith(
            pages: [
              source.copyWith(
                devices: [source.devices.first.copyWith(componentId: 'absent')],
              ),
              ...project.pages.skip(1),
            ],
          ),
        ),
        throwsA(isA<EcadException>()),
      );
    },
  );
}

EcadProject _project() {
  final relay = createBuiltinComponent(
    componentId: 'relay',
    deviceId: 'aux',
    kind: DeviceKind.coil,
    designation: '-K1',
    position: const Vec2(150, 300),
  );
  final contact = createBuiltinComponent(
    componentId: 'relay',
    deviceId: 'aux',
    kind: DeviceKind.contactNo,
    designation: '-K1',
    position: relay.device.position,
  );
  final terminals = [
    for (var i = 1; i <= 2; i++)
      createTerminalComponent(
        componentId: 'terminal-component-$i',
        deviceId: 'terminal-$i',
        stripId: 'strip',
        number: '$i',
        position: Vec2(500, 170.0 + i * 100),
      ),
  ];
  final ambiguous = Component(
    id: 'ambiguous',
    designation: '-K2',
    mountingSizeOverrideMm: const DimensionsMm(width: 20, height: 30),
    electrical: ElectricalModel(
      terminals: const [],
      functions: [
        ComponentFunction(
          id: 'function-a',
          name: 'Auxiliary A',
          terminalIds: const [],
        ),
        ComponentFunction(
          id: 'function-b',
          name: 'Auxiliary B',
          terminalIds: const [],
        ),
      ],
    ),
  );
  return EcadProject(
    id: 'project',
    name: 'Synthetic PDF navigation',
    components: [
      relay.component.copyWith(
        mountingSizeOverrideMm: const DimensionsMm(width: 50, height: 70),
        electrical: ElectricalModel(
          terminals: [
            ...relay.component.electrical!.terminals,
            ...contact.component.electrical!.terminals,
          ],
          functions: [
            ...relay.component.electrical!.functions,
            ...contact.component.electrical!.functions,
          ],
        ),
      ),
      for (final seed in terminals)
        seed.component.copyWith(
          mountingSizeOverrideMm: const DimensionsMm(width: 5, height: 50),
        ),
      ambiguous,
      const Component(
        id: 'unresolved',
        designation: '-U1',
        mountingSizeOverrideMm: DimensionsMm(width: 20, height: 30),
      ),
      for (var i = 0; i < 110; i++)
        Component(
          id: 'material-$i',
          kind: ComponentKind.material,
          description: 'Synthetic material row $i',
          quantity: const Quantity.pieces(1),
        ),
    ],
    terminalStrips: [
      TerminalStrip(
        id: 'strip',
        reference: ComponentReference(
          context: const StructureContext.empty(),
          localDesignation: 'X1',
        ),
      ),
    ],
    continuationLinks: const [
      ContinuationLink(id: 'pair', label: 'PAIR'),
      ContinuationLink(id: 'local', label: 'LOCAL'),
      ContinuationLink(id: 'dangling', label: 'NO PEER'),
    ],
    mountingLayouts: [
      MountingLayout(
        id: 'surface',
        name: 'Synthetic mounting',
        widthMm: 200,
        heightMm: 150,
        placements: const [
          MountingPlacement(
            id: 'relay-placement',
            componentId: 'relay',
            centerMm: Vec2(70, 75),
            rotation: 90,
          ),
          MountingPlacement(
            id: 'terminal-placement-1',
            componentId: 'terminal-component-1',
            centerMm: Vec2(120, 75),
          ),
          MountingPlacement(
            id: 'terminal-placement-2',
            componentId: 'terminal-component-2',
            centerMm: Vec2(130, 75),
          ),
          MountingPlacement(
            id: 'ambiguous-placement',
            componentId: 'ambiguous',
            centerMm: Vec2(155, 100),
          ),
          MountingPlacement(
            id: 'unresolved-placement',
            componentId: 'unresolved',
            centerMm: Vec2(185, 100),
          ),
        ],
      ),
    ],
    pages: [
      Sheet(
        id: 'first',
        name: 'First',
        number: '1',
        width: 1200,
        height: 600,
        paperSizeMm: const SizeMm(width: 210, height: 297),
        devices: [
          contact.device.copyWith(rotation: 90),
          terminals.first.device.copyWith(
            id: 'terminal-copy',
            mode: OccurrenceMode.reference,
            position: const Vec2(400, 450),
          ),
          terminals.last.device,
          terminals.last.device.copyWith(
            id: 'terminal-local-copy',
            mode: OccurrenceMode.reference,
            position: const Vec2(900, 300),
          ),
        ],
        continuations: const [
          ContinuationMarker(
            id: 'pair-source',
            linkId: 'pair',
            position: Vec2(100, 200),
            direction: PortSide.top,
          ),
          ContinuationMarker(
            id: 'same-a',
            linkId: 'local',
            position: Vec2(100, 400),
          ),
          ContinuationMarker(
            id: 'same-b',
            linkId: 'local',
            position: Vec2(700, 400),
            direction: PortSide.bottom,
          ),
          ContinuationMarker(
            id: 'orphan',
            linkId: 'dangling',
            position: Vec2(100, 500),
          ),
        ],
      ),
      Sheet(
        id: 'bom',
        name: 'Components',
        number: 'B01',
        type: SheetType.billOfMaterials,
        width: 3000,
        height: 500,
        paperSizeMm: const SizeMm(width: 210, height: 297),
        report: const BomTableSpec(kind: BomReportKind.components),
      ),
      Sheet(
        id: 'second',
        name: 'Second',
        number: '2',
        width: 1000,
        height: 1000,
        paperSizeMm: const SizeMm(width: 420, height: 297),
        devices: [
          relay.device.copyWith(
            id: 'repeat',
            position: const Vec2(100, 500),
            mode: OccurrenceMode.reference,
            symbol: PortBlockSpec(
              width: 80,
              height: 70,
              ports: [
                for (var i = 0; i < 2; i++)
                  BlockPort(
                    id: 'pin-$i',
                    terminalId: relay.component.electrical!.terminals[i].id,
                    side: i == 0 ? PortSide.top : PortSide.bottom,
                    fraction: .5,
                  ),
              ],
            ),
          ),
          relay.device.copyWith(
            id: 'main',
            position: const Vec2(300, 200),
            isMainFunction: true,
            mode: OccurrenceMode.reference,
          ),
          terminals.first.device.copyWith(rotation: 270),
          for (final id in ['a', 'b'])
            Device(
              id: 'ambiguous-$id',
              componentId: 'ambiguous',
              functionId: 'function-$id',
              position: Vec2(id == 'a' ? 100 : 300, 750),
              symbol: PortBlockSpec(width: 50, height: 40, ports: const []),
            ),
        ],
        continuations: const [
          ContinuationMarker(
            id: 'peer',
            linkId: 'pair',
            position: Vec2(400, 350),
            direction: PortSide.left,
          ),
        ],
      ),
      for (final detail in [false, true])
        Sheet(
          id: detail ? 'terminal-plan' : 'mounting',
          name: 'Construction',
          number: detail ? 'M02' : 'M01',
          type: SheetType.cabinetLayout,
          width: 1000,
          height: 800,
          paperSizeMm:
              detail
                  ? const SizeMm(width: 297, height: 420)
                  : const SizeMm(width: 420, height: 420),
          mountingView: MountingView(
            layoutId: 'surface',
            originMm: detail ? const Vec2(20, 30) : Vec2.zero,
            viewport: const RectUnits(x: 100, y: 150, width: 800, height: 500),
            scaleDenominator: detail ? 1 : 2,
          ),
        ),
    ],
  );
}

typedef _Destination = ({int page, double x, double y});
typedef _Link = ({int page, String target, Rect rect});

class _PdfNavigation {
  _PdfNavigation(List<int> bytes) {
    final raw = latin1.decode(bytes);
    final objects = {
      for (final m in RegExp(
        r'(\d+) 0 obj\s*([\s\S]*?)\s*endobj',
      ).allMatches(raw))
        int.parse(m[1]!): m[2]!,
    };
    pages.addAll(
      objects.entries
          .where((e) => RegExp(r'/Type\s*/Page\b').hasMatch(e.value))
          .map((e) => e.key),
    );
    for (final m in RegExp(
      r'\(ecad:([^)]*)\)\s*<<\s*/D\[(\d+) 0 R\s*/XYZ\s+([\d.-]+)\s+([\d.-]+)\s+null\]\s*>>',
    ).allMatches(raw)) {
      destinations[m[1]!] = (
        page: pages.indexOf(int.parse(m[2]!)),
        x: double.parse(m[3]!),
        y: double.parse(m[4]!),
      );
    }
    for (final object in objects.entries.where(
      (e) => RegExp(r'/Subtype\s*/Link\b').hasMatch(e.value),
    )) {
      final value = object.value;
      expect(value, contains('/S/GoTo'));
      expect(value, contains('/Border[0 0 0]'));
      final page = pages.indexOf(
        int.parse(RegExp(r'/P\s*(\d+) 0 R').firstMatch(value)![1]!),
      );
      expect(page, isNonNegative);
      expect(
        objects[pages[page]],
        contains(RegExp('/Annots\\[[^\\]]*\\b${object.key} 0 R')),
      );
      final target = RegExp(r'/D\(ecad:([^)]*)\)').firstMatch(value)![1]!;
      expect(destinations, contains(target));
      expect(destinations[target]!.page, isNonNegative);
      final coords =
          RegExp(r'/Rect\[([^\]]+)\]')
              .firstMatch(value)![1]!
              .split(RegExp(r'\s+'))
              .map(double.parse)
              .toList();
      final rect = Rect.fromLTRB(coords[0], coords[1], coords[2], coords[3]);
      expect(rect.isEmpty, isFalse);
      links.add((page: page, target: target, rect: rect));
    }
  }
  final pages = <int>[];
  final destinations = <String, _Destination>{};
  final links = <_Link>[];
}

Vec2 _paperPoint(Sheet sheet, Vec2 p) {
  final scale = math.min(
    sheet.paperSizeMm.width / sheet.width,
    sheet.paperSizeMm.height / sheet.height,
  );
  return Vec2(
    ((sheet.paperSizeMm.width - sheet.width * scale) / 2 + p.x * scale) *
        PdfPageFormat.mm,
    ((sheet.paperSizeMm.height + sheet.height * scale) / 2 - p.y * scale) *
        PdfPageFormat.mm,
  );
}

Rect _paperRect(Sheet sheet, Rect r) {
  final a = _paperPoint(sheet, Vec2(r.left, r.bottom));
  final b = _paperPoint(sheet, Vec2(r.right, r.top));
  return Rect.fromLTRB(a.x, a.y, b.x, b.y);
}

void _expectDestination(
  _PdfNavigation pdf,
  String id,
  int page,
  Sheet sheet,
  Vec2 position,
) {
  final target = pdf.destinations[id]!;
  final point = _paperPoint(sheet, position);
  expect(target.page, page, reason: id);
  expect(target.x, closeTo(point.x, .001), reason: id);
  expect(target.y, closeTo(point.y, .001), reason: id);
}

void _expectRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, .001));
  expect(actual.top, closeTo(expected.top, .001));
  expect(actual.right, closeTo(expected.right, .001));
  expect(actual.bottom, closeTo(expected.bottom, .001));
}
