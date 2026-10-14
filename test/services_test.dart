import 'dart:convert';
import 'dart:io';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_ecad/services/ecad_services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EcadProject project;
  late AssistantService assistant;
  setUp(() {
    project = DemoProject.create();
    assistant = AssistantService();
    SharedPreferences.setMockInitialValues({});
  });

  group('assistant proposals', () {
    test('Czech motor branch is a nonmutating, valid, atomic proposal', () {
      final original = jsonEncode(project.toJson());
      final proposal = assistant.propose(
        'Přidej motorový vývod 3 kW',
        project: project,
        sheetId: 'sheet_power',
      );
      expect(proposal.supported, isTrue, reason: proposal.message);
      expect(proposal.source, AssistantSource.localParser);
      expect(proposal.commands, hasLength(9));
      expect(proposal.baseRevision, project.revision);
      final preview = proposal.preview(project);
      expect(
        preview.pages.first.devices.length,
        project.pages.first.devices.length + 5,
      );
      expect(
        preview.pages.first.wires.length,
        project.pages.first.wires.length + 4,
      );
      expect(
        preview.pages.first.devices
            .lastWhere((device) => device.kind == DeviceKind.motor)
            .rating,
        '3 kW',
      );
      expect(
        validateProject(preview).where(
          (diagnostic) => diagnostic.severity == DiagnosticSeverity.error,
        ),
        isEmpty,
      );
      expect(jsonEncode(project.toJson()), original);
      final engine = ProjectEngine(project);
      engine.execute(
        proposal.commands,
        expectedRevision: proposal.baseRevision,
      );
      expect(engine.undo(), isTrue);
      expect(
        engine.project.pages.first.devices.length,
        project.pages.first.devices.length,
      );
    });

    test('English insertion and Czech rename use the selected device', () {
      final insert = assistant.propose(
        'Add circuit breaker QF7',
        project: project,
        sheetId: 'sheet_power',
      );
      expect(
        insert.preview(project).pages.first.devices.last.designation,
        'QF7',
      );
      final rename = assistant.propose(
        'Přejmenuj výběr na KM2',
        project: project,
        sheetId: 'sheet_power',
        selectedDeviceIds: {'dev_contactor'},
      );
      expect(
        rename
            .preview(project)
            .pages
            .first
            .devices
            .firstWhere((device) => device.id == 'dev_contactor')
            .designation,
        'KM2',
      );
    });

    test(
      'default designations are global and treat bare labels as aliases',
      () {
        final terminal = assistant.propose(
          'Přidej svorku',
          project: project,
          sheetId: 'sheet_power',
        );
        expect(
          terminal.preview(project).pages.first.devices.last.designation,
          '-X3',
        );
        final aliased = project.copyWith(
          pages: [
            project.pages.first,
            project.pages.last.copyWith(
              devices: [
                ...project.pages.last.devices,
                const Device(
                  id: 'bare_terminal',
                  kind: DeviceKind.terminal,
                  designation: 'x3',
                  position: Vec2(850, 150),
                ),
              ],
            ),
          ],
        );
        final copy = assistant.propose(
          'Duplikuj výběr',
          project: aliased,
          sheetId: 'sheet_power',
          selectedDeviceIds: {'dev_pe_terminal'},
        );
        expect(
          copy.preview(aliased).pages.first.devices.last.designation,
          '-X4',
        );
        final explicit = assistant.propose(
          'Přidej jistič QF2',
          project: project,
          sheetId: 'sheet_power',
        );
        expect(
          explicit.preview(project).pages.first.devices.last.designation,
          'QF2',
        );
      },
    );

    test(
      'repeated automatic insertion stays inside paper without overlapping devices',
      () {
        var current = project;
        var inserted = 0;
        for (var attempt = 0; attempt < 200; attempt++) {
          final proposal = assistant.propose(
            'Přidej svorku',
            project: current,
            sheetId: 'sheet_power',
          );
          if (!proposal.supported) {
            expect(proposal.message, contains('Přidejte nový list'));
            break;
          }
          final next = proposal.preview(current);
          final device = next.pages.first.devices.last;
          expect(device.position.x, inInclusiveRange(48, 980));
          expect(device.position.y, inInclusiveRange(126, 628));
          final definition = SymbolCatalog.definitionFor(device.kind);
          for (final existing in current.pages.first.devices) {
            final other = SymbolCatalog.definitionFor(existing.kind);
            final separateX =
                (device.position.x - existing.position.x).abs() >=
                (definition.width + other.width) / 2;
            final separateY =
                (device.position.y - existing.position.y).abs() >=
                (definition.height + other.height) / 2;
            expect(
              separateX || separateY,
              isTrue,
              reason: '${device.designation} overlaps ${existing.designation}',
            );
            if (existing.kind == DeviceKind.terminal) {
              // Reserve the visible terminal symbol and its short label too.
              final labelsSeparate =
                  device.position.x + 64 <= existing.position.x - 14 ||
                  existing.position.x + 64 <= device.position.x - 14 ||
                  (device.position.y - existing.position.y).abs() >= 38;
              expect(labelsSeparate, isTrue);
            }
          }
          current = next;
          inserted++;
        }
        expect(inserted, greaterThanOrEqualTo(20));
        expect(inserted, lessThan(200));
      },
    );

    test(
      'motor branch fits demo left side and a full-sheet proposal is atomic',
      () {
        final first = assistant.propose(
          'Vytvoř motorový vývod',
          project: project,
          sheetId: 'sheet_power',
        );
        expect(first.supported, isTrue, reason: first.message);
        final filled = first.preview(project);
        final added =
            filled.pages.first.devices
                .skip(project.pages.first.devices.length)
                .toList();
        expect(added.first.position.x, lessThan(300));
        for (final device in added) {
          final definition = SymbolCatalog.definitionFor(device.kind);
          expect(device.position.x - definition.width / 2, greaterThan(32));
          expect(device.position.x + definition.width / 2, lessThan(1068));
          expect(device.position.y - definition.height / 2, greaterThan(100));
          expect(device.position.y + definition.height / 2, lessThan(650));
        }
        final second = assistant.propose(
          'Vytvoř motorový vývod',
          project: filled,
          sheetId: 'sheet_power',
        );
        expect(second.supported, isFalse);
        expect(second.message, contains('Přidejte nový list'));
        final original = jsonEncode(project.toJson());
        final atomic = assistant.fromActions(
          [
            {'op': 'motor_branch'},
            {'op': 'motor_branch'},
          ],
          project: project,
          sheetId: 'sheet_power',
        );
        expect(atomic.supported, isFalse);
        expect(atomic.commands, isEmpty);
        expect(jsonEncode(project.toJson()), original);
      },
    );

    test('empty sheet packs whole branches then requests a new sheet', () {
      var current = EcadProject(
        id: 'empty_project',
        name: 'Prázdný projekt',
        pages: [Sheet(id: 'empty_sheet', name: 'První list', number: '01')],
      );
      var branches = 0;
      for (var attempt = 0; attempt < 10; attempt++) {
        final proposal = assistant.propose(
          'Vytvoř motorový vývod',
          project: current,
          sheetId: 'empty_sheet',
        );
        if (!proposal.supported) {
          expect(proposal.message, contains('Přidejte nový list'));
          break;
        }
        current = proposal.preview(current);
        branches++;
      }
      expect(branches, inInclusiveRange(2, 4));
      expect(current.pages.single.devices, hasLength(branches * 5));
      final explicit = assistant.fromActions(
        [
          {'op': 'insert_device', 'kind': 'terminal', 'x': 2000, 'y': 900},
        ],
        project: current,
        sheetId: 'empty_sheet',
      );
      expect(explicit.supported, isTrue, reason: explicit.message);
      expect(
        explicit.preview(current).pages.single.devices.last.position,
        const Vec2(2000, 900),
      );
    });

    test(
      'duplication clones internal wires and leaves external wires alone',
      () {
        final proposal = assistant.propose(
          'Duplikuj výběr 3×',
          project: project,
          sheetId: 'sheet_power',
          selectedDeviceIds: {'dev_breaker', 'dev_contactor'},
        );
        expect(proposal.supported, isTrue, reason: proposal.message);
        final result = proposal.preview(project).pages.first;
        expect(result.devices.length, project.pages.first.devices.length + 6);
        expect(result.wires.length, project.pages.first.wires.length + 3);
        expect(
          result.devices.map((device) => device.designation).toSet().length,
          result.devices.length,
        );
        final allDevices = [
          ...result.devices,
          ...project.pages.skip(1).expand((page) => page.devices),
        ];
        expect(
          allDevices.map((device) => device.designation).toSet().length,
          allDevices.length,
        );
        final newWires = result.wires.skip(project.pages.first.wires.length);
        for (final wire in newWires) {
          expect(wire.from.deviceId, isNot('dev_breaker'));
          expect(wire.to.deviceId, isNot('dev_contactor'));
        }
      },
    );

    test('destructive selection commands require a real selection', () {
      final unsupported = assistant.propose(
        'Smaž výběr',
        project: project,
        sheetId: 'sheet_power',
      );
      expect(unsupported.supported, isFalse);
      final wrongScope = assistant.propose(
        'Smaž projekt',
        project: project,
        sheetId: 'sheet_power',
        selectedDeviceIds: {'dev_breaker'},
      );
      expect(wrongScope.supported, isFalse);
      final delete = assistant.propose(
        'Smaž výběr',
        project: project,
        sheetId: 'sheet_power',
        selectedDeviceIds: {'dev_breaker'},
      );
      final preview = delete.preview(project).pages.first;
      expect(
        preview.devices.any((device) => device.id == 'dev_breaker'),
        isFalse,
      );
      expect(
        preview.wires.any(
          (wire) =>
              wire.from.deviceId == 'dev_breaker' ||
              wire.to.deviceId == 'dev_breaker',
        ),
        isFalse,
      );
    });

    test('undo, redo and validation are explicit controller actions', () {
      for (final entry
          in {
            'Vrať poslední změnu': AssistantAction.undo,
            'Redo': AssistantAction.redo,
            'Zkontroluj projekt': AssistantAction.validate,
          }.entries) {
        final proposal = assistant.propose(
          entry.key,
          project: project,
          sheetId: 'sheet_power',
        );
        expect(proposal.action, entry.value);
        expect(proposal.commands, isEmpty);
      }
    });

    test('stale proposals cannot overwrite a later edit', () {
      final proposal = assistant.propose(
        'Přidej jistič QF2',
        project: project,
        sheetId: 'sheet_power',
      );
      final engine = ProjectEngine(project)
        ..execute([RenameProject('Nový název')]);
      expect(
        () => proposal.preview(engine.project),
        throwsA(isA<EcadException>()),
      );
    });

    test('unknown, overlarge and malformed model operations are rejected', () {
      final invalid = <Object?>[
        [
          {'op': 'run_code', 'source': 'print(1)'},
        ],
        [
          {'op': 'insert_device', 'kind': 'motor', 'shell': 'anything'},
        ],
        [
          {'op': 'insert_device', 'kind': 'motor', 'x': double.nan, 'y': 0},
        ],
        [
          {'op': 'insert_device', 'kind': 'arbitrary'},
        ],
        [
          {'op': 'duplicate_selected', 'count': 100000},
        ],
        [
          {'op': 'undo'},
          {'op': 'delete_selected'},
        ],
        List.generate(21, (_) => {'op': 'insert_device', 'kind': 'motor'}),
      ];
      for (final actions in invalid) {
        final proposal = assistant.fromActions(
          actions,
          project: project,
          sheetId: 'sheet_power',
          selectedDeviceIds: {'dev_motor'},
        );
        expect(proposal.supported, isFalse, reason: '$actions');
        expect(proposal.commands, isEmpty);
      }
      expect(
        assistant
            .propose(
              'Duplikuj výběr ${'9' * 200}x',
              project: project,
              sheetId: 'sheet_power',
            )
            .supported,
        isFalse,
      );
      expect(
        assistant
            .propose(
              'Jaké je dnes počasí?',
              project: project,
              sheetId: 'sheet_power',
            )
            .supported,
        isFalse,
      );
    });
  });

  group('optional Ollama', () {
    test(
      'requests JSON schema only on explicit model call and validates output',
      () async {
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          expect(request.url.toString(), 'http://localhost:11434/api/chat');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['stream'], isFalse);
          expect((body['format'] as Map)['type'], 'object');
          return http.Response(
            jsonEncode({
              'message': {
                'content': jsonEncode({
                  'label': 'Nový motor',
                  'message': 'Připraven motor M9.',
                  'actions': [
                    {
                      'op': 'insert_device',
                      'kind': 'motor',
                      'designation': 'M9',
                      'rating': '',
                    },
                  ],
                }),
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });
        final service = AssistantService(httpClient: client);
        service.propose(
          'Přidej motor',
          project: project,
          sheetId: 'sheet_power',
        );
        expect(requests, 0);
        final proposal = await service.proposeWithOllama(
          'Přidej další motor.',
          project: project,
          sheetId: 'sheet_power',
          settings: const AiProviderSettings(),
        );
        expect(requests, 1);
        expect(proposal.supported, isTrue, reason: proposal.message);
        expect(proposal.source, AssistantSource.ollama);
        expect(
          proposal.preview(project).pages.first.devices.last.designation,
          'M9',
        );
        client.close();
      },
    );

    test('model output never escapes the command allowlist', () async {
      final service = AssistantService(
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'message': {
                'content': jsonEncode({
                  'actions': [
                    {'op': 'execute', 'code': 'rm'},
                  ],
                }),
              },
            }),
            200,
          ),
        ),
      );
      final proposal = await service.proposeWithOllama(
        'Přidej motor',
        project: project,
        sheetId: 'sheet_power',
        settings: const AiProviderSettings(),
      );
      expect(proposal.supported, isFalse);
      expect(proposal.commands, isEmpty);
    });

    test('settings reject credentials in endpoint URL', () {
      expect(
        () =>
            const AiProviderSettings(
              baseUrl: 'http://user:secret@localhost:11434',
            ).validate(),
        throwsFormatException,
      );
      expect(
        () => const AiProviderSettings(baseUrl: 'file:///tmp/model').validate(),
        throwsFormatException,
      );
    });

    test(
      'oversized HTTP responses are rejected before JSON processing',
      () async {
        final client = MockClient(
          (_) async => http.Response('x' * (65 * 1024), 200),
        );
        final service = AssistantService(httpClient: client);
        final proposal = await service.proposeWithOllama(
          'Přidej motor',
          project: project,
          sheetId: 'sheet_power',
          settings: const AiProviderSettings(),
        );
        expect(proposal.supported, isFalse);
        expect(proposal.commands, isEmpty);
        expect(proposal.message, contains('64 kB'));
        client.close();
      },
    );
  });

  group('project persistence', () {
    test('round-trips complete, versioned project documents', () {
      final persistence = ProjectPersistence();
      final encoded = persistence.encode(project);
      expect(jsonDecode(encoded)['formatVersion'], 2);
      expect(persistence.decode(encoded).toJson(), project.toJson());
      final invalid = project.toJson()..['formatVersion'] = 900;
      expect(
        () => persistence.decode(jsonEncode(invalid)),
        throwsA(isA<EcadException>()),
      );
      final brokenGraph = project.copyWith(
        pages: [
          project.pages.first.copyWith(
            wires: [
              Wire(
                id: 'broken_wire',
                from: const TerminalRef(deviceId: 'missing', portId: 'out'),
                to: const TerminalRef(deviceId: 'dev_motor', portId: 'in'),
              ),
            ],
          ),
        ],
      );
      expect(
        () => persistence.decode(jsonEncode(brokenGraph.toJson())),
        throwsA(isA<EcadException>()),
      );
    });

    test('queued autosave preserves the most recent revision', () async {
      final persistence = ProjectPersistence();
      final latest = project.copyWith(name: 'Poslední změna', revision: 4);
      await Future.wait([
        persistence.saveAutosave(project),
        persistence.saveAutosave(latest),
      ]);
      expect((await persistence.loadAutosave())?.toJson(), latest.toJson());
      await persistence.clearAutosave();
      expect(await persistence.loadAutosave(), isNull);
    });
  });

  group('vector exports', () {
    test(
      'SVG includes all pages, escaped text and the actual vector paths',
      () {
        final named = project.copyWith(name: 'Řízení <motor> & "1"');
        final exporter = ProjectExportService();
        final svg = exporter.svg(named);
        expect(svg, contains('height="1560"'));
        expect(svg, contains('Řízení &lt;motor&gt; &amp; &quot;1&quot;'));
        expect(svg, contains('1 / 2'));
        expect(svg, contains('2 / 2'));
        expect(svg, contains('<polyline'));
        expect(svg, contains('<circle'));
        expect(svg, isNot(contains('<image')));
        final single = exporter.svg(project, sheetId: 'sheet_control');
        expect(single, contains('height="780"'));
        expect(single, isNot(contains('1 / 2')));
        expect(
          () => exporter.svg(project, sheetId: 'missing'),
          throwsFormatException,
        );
      },
    );

    test('PDF uses local fonts and exports every sheet', () async {
      final named = project.copyWith(
        name: 'Dílna · Řízení motoru',
        description: 'Napájení a ovládání · ověření českých znaků',
      );
      final exporter = ProjectExportService();
      final pdf = await exporter.pdf(named);
      expect(utf8.decode(pdf.take(5).toList()), '%PDF-');
      expect(pdf.length, greaterThan(10000));
      if (const bool.fromEnvironment('EXPORT_QA')) {
        final directory = Directory('tmp/pdfs')..createSync(recursive: true);
        File('${directory.path}/services-qa.pdf').writeAsBytesSync(pdf);
        File(
          '${directory.path}/services-qa.svg',
        ).writeAsStringSync(exporter.svg(named));
      }
    });
  });
}
