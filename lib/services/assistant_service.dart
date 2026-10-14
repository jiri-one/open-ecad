// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:http/http.dart' as http;

import 'ollama_provider.dart';
import 'provider_settings.dart';

enum AssistantAction { none, undo, redo, validate }

enum AssistantSource { localParser, ollama }

/// A proposed transaction. The live editor remains unchanged until it applies
/// these commands with [baseRevision] as the expected revision.
class AssistantProposal {
  const AssistantProposal({
    required this.label,
    required this.message,
    required this.commands,
    required this.baseRevision,
    this.action = AssistantAction.none,
    this.source = AssistantSource.localParser,
    this.supported = true,
  });

  final String label;
  final String message;
  final List<EcadCommand> commands;
  final int baseRevision;
  final AssistantAction action;
  final AssistantSource source;
  final bool supported;

  bool get canApply => supported && commands.isNotEmpty;

  EcadProject preview(EcadProject project) {
    if (!canApply) return project;
    final engine = ProjectEngine(project);
    engine.execute(commands, label: label, expectedRevision: baseRevision);
    return engine.project;
  }
}

/// Local commands and optional model output share the same bounded translator
/// and the same core command engine. Neither path directly edits editor state.
class AssistantService {
  AssistantService({http.Client? httpClient}) : _httpClient = httpClient;

  final http.Client? _httpClient;
  static const maxPromptLength = 4000;
  static const maxCommands = 100;

  AssistantProposal propose(
    String prompt, {
    required EcadProject project,
    required String sheetId,
    Set<String> selectedDeviceIds = const {},
    Vec2? insertionPoint,
  }) {
    if (prompt.trim().isEmpty || prompt.length > maxPromptLength) {
      return _unsupported(project, 'Napište příkaz o délce 1 až 4 000 znaků.');
    }
    final normalized = _normalize(
      prompt.trim(),
    ).replaceFirst(RegExp(r'^(?:prosim|please)\s+'), '');
    final actions = <Map<String, Object?>>[];
    if (RegExp(
      r'^(?:undo|zpet|vrat (?:posledni )?zmenu)[.!]?$',
    ).hasMatch(normalized)) {
      actions.add({'op': 'undo'});
    } else if (RegExp(
      r'^(?:redo|znovu|opakuj (?:posledni )?zmenu)[.!]?$',
    ).hasMatch(normalized)) {
      actions.add({'op': 'redo'});
    } else if (RegExp(
      r'^(?:validate|check|zkontroluj|over|validuj)\b',
    ).hasMatch(normalized)) {
      actions.add({'op': 'validate'});
    } else if (RegExp(r'^(?:rename|prejmenuj|oznac)\b').hasMatch(normalized)) {
      if (_hasOtherScope(normalized.split(RegExp(r'\b(?:na|to)\b')).first)) {
        return _unsupported(
          project,
          'Lokální přejmenování pracuje s vybraným přístrojem. Použijte „Přejmenuj výběr na KM2“.',
        );
      }
      final match = RegExp(
        r'\b(?:na|to)\s+(.+)$',
        caseSensitive: false,
      ).firstMatch(prompt);
      if (match == null) {
        return _unsupported(
          project,
          'Použijte například „Přejmenuj výběr na KM2“.',
        );
      }
      final designation = match
          .group(1)!
          .trim()
          .replaceAll(RegExp(r'''^["'„“]+|["'„“]+$'''), '');
      actions.add({'op': 'rename_selected', 'designation': designation});
    } else if (RegExp(
      r'^(?:duplicate|copy|duplikuj|zkopiruj|kopiruj)\b',
    ).hasMatch(normalized)) {
      if (_hasOtherScope(normalized)) return _unsupported(project, _help);
      final match = RegExp(
        r'\b(\d+)\s*(?:x|times|krat)?\b',
      ).firstMatch(normalized);
      final count = match == null ? 1 : int.tryParse(match.group(1)!);
      if (count == null) {
        return _unsupported(project, 'Počet kopií musí být 1 až 20.');
      }
      actions.add({'op': 'duplicate_selected', 'count': count});
    } else if (RegExp(
      r'^(?:delete|remove|smaz|odstran|vymaz)\b',
    ).hasMatch(normalized)) {
      if (_hasOtherScope(normalized)) return _unsupported(project, _help);
      actions.add({'op': 'delete_selected'});
    } else if (RegExp(
      r'^(?:add|insert|create|build|draw|pridej|vloz|vytvor|navrhni|nakresli)\b',
    ).hasMatch(normalized)) {
      final isMotorBranch =
          normalized.contains('motor') &&
          (RegExp(
                r'branch|circuit|vyvod|vetev|zapojeni|single.line',
              ).hasMatch(normalized) ||
              (RegExp(r'breaker|jistic').hasMatch(normalized) &&
                  RegExp(r'contactor|stykac').hasMatch(normalized)));
      if (isMotorBranch) {
        final rating = RegExp(
          r'\b(\d+(?:[.,]\d+)?)\s*kw\b',
        ).firstMatch(normalized);
        actions.add({
          'op': 'motor_branch',
          if (rating != null) 'rating': '${rating.group(1)} kW',
        });
      } else {
        final kind = _kindFromText(normalized);
        if (kind == null) return _unsupported(project, _help);
        final designation =
            // B, C and D are left out: "B16" is a breaker curve and rating.
            RegExp(
              r'\b(?:QF|QS|KM|PE|FU|SB|TA|TV|PA|PV|M|X|K|H|L|Q|S|A|U|F|T|P)\d+(?:[.:_-]\d+)*\b',
              caseSensitive: false,
            ).firstMatch(prompt)?.group(0)?.toUpperCase();
        actions.add({
          'op': 'insert_device',
          'kind': kind.name,
          if (designation != null) 'designation': designation,
        });
      }
    } else {
      return _unsupported(project, _help);
    }
    return fromActions(
      actions,
      project: project,
      sheetId: sheetId,
      selectedDeviceIds: selectedDeviceIds,
      insertionPoint: insertionPoint,
    );
  }

  Future<AssistantProposal> proposeWithOllama(
    String prompt, {
    required EcadProject project,
    required String sheetId,
    required AiProviderSettings settings,
    Set<String> selectedDeviceIds = const {},
    Vec2? insertionPoint,
  }) async {
    if (prompt.trim().isEmpty || prompt.length > maxPromptLength) {
      return _unsupported(
        project,
        'Napište příkaz o délce 1 až 4 000 znaků.',
        source: AssistantSource.ollama,
      );
    }
    try {
      final sheet = project.pages.firstWhere((page) => page.id == sheetId);
      final result = await OllamaProvider(client: _httpClient).propose(
        prompt: prompt,
        settings: settings,
        sheet: sheet,
        selectedDeviceIds: selectedDeviceIds,
      );
      return fromActions(
        result.actions,
        project: project,
        sheetId: sheetId,
        selectedDeviceIds: selectedDeviceIds,
        insertionPoint: insertionPoint,
        source: AssistantSource.ollama,
        label: result.label,
        message: result.message,
      );
    } on Object catch (error) {
      return _unsupported(
        project,
        'Model neposkytl použitelný návrh: ${_errorText(error)}',
        source: AssistantSource.ollama,
      );
    }
  }

  /// Translates a small allowlist of JSON operations, then dry-runs the entire
  /// transaction on an isolated engine. Unknown operations and fields fail.
  AssistantProposal fromActions(
    Object? actions, {
    required EcadProject project,
    required String sheetId,
    Set<String> selectedDeviceIds = const {},
    Vec2? insertionPoint,
    AssistantSource source = AssistantSource.localParser,
    String? label,
    String? message,
  }) {
    try {
      if (actions is! List || actions.isEmpty || actions.length > 20) {
        throw const FormatException('Návrh musí obsahovat 1 až 20 operací.');
      }
      final sheet = project.pages.firstWhere((page) => page.id == sheetId);
      final builder = _CommandBuilder(
        project,
        sheet,
        selectedDeviceIds,
        insertionPoint,
      );
      AssistantAction action = AssistantAction.none;
      final labels = <String>[];
      for (final raw in actions) {
        if (raw is! Map<String, dynamic>) {
          throw const FormatException('Operace musí být objekt JSON.');
        }
        final op = _string(raw, 'op', maxLength: 40);
        switch (op) {
          case 'insert_device':
            _fields(raw, {
              'op',
              'kind',
              'designation',
              'x',
              'y',
              'rating',
              'description',
            });
            final kindName = _string(raw, 'kind', maxLength: 30);
            final kind = DeviceKind.values.where(
              (kind) => kind.name == kindName,
            );
            if (kind.isEmpty) {
              throw const FormatException('Neznámý typ přístroje.');
            }
            Vec2? position;
            if (raw.containsKey('x') || raw.containsKey('y')) {
              position = Vec2(_coordinate(raw['x']), _coordinate(raw['y']));
            }
            builder.insert(
              kind.first,
              designation: _optionalString(raw, 'designation', maxLength: 32),
              rating:
                  _optionalString(
                    raw,
                    'rating',
                    maxLength: 80,
                    allowEmpty: true,
                  ) ??
                  '',
              description:
                  _optionalString(
                    raw,
                    'description',
                    maxLength: 500,
                    allowEmpty: true,
                  ) ??
                  '',
              position: position,
            );
            labels.add('Vložit přístroj');
          case 'motor_branch':
            _fields(raw, {'op', 'rating'});
            builder.motorBranch(
              _optionalString(raw, 'rating', maxLength: 80, allowEmpty: true) ??
                  '',
            );
            labels.add('Motorový vývod');
          case 'rename_selected':
            _fields(raw, {'op', 'designation'});
            builder.rename(_string(raw, 'designation', maxLength: 32));
            labels.add('Přejmenovat přístroj');
          case 'duplicate_selected':
            _fields(raw, {'op', 'count'});
            final count = raw['count'] ?? 1;
            if (count is! int || count < 1 || count > 20) {
              throw const FormatException('Počet kopií musí být 1 až 20.');
            }
            builder.duplicate(count);
            labels.add('Duplikovat výběr');
          case 'delete_selected':
            _fields(raw, {'op'});
            builder.delete();
            labels.add('Odstranit výběr');
          case 'undo':
          case 'redo':
          case 'validate':
            _fields(raw, {'op'});
            if (actions.length != 1) {
              throw const FormatException(
                'Zpět, znovu a kontrolu zadávejte samostatně.',
              );
            }
            action = AssistantAction.values.byName(op);
          default:
            throw FormatException('Nepodporovaná operace: $op.');
        }
        if (builder.commands.length > maxCommands) {
          throw const FormatException('Návrh překračuje limit 100 změn.');
        }
      }
      if (builder.commands.isNotEmpty) {
        final engine = ProjectEngine(project);
        engine.execute(builder.commands, expectedRevision: project.revision);
      }
      final defaultMessage = switch (action) {
        AssistantAction.undo => 'Vrátit poslední změnu projektu.',
        AssistantAction.redo => 'Znovu provést poslední vrácenou změnu.',
        AssistantAction.validate =>
          'Spustit kontrolu označení a elektrických spojení.',
        AssistantAction.none =>
          '${builder.commands.length} změn je připraveno. Prohlédněte náhled a potvrďte použití.',
      };
      return AssistantProposal(
        label:
            label ??
            (labels.isEmpty ? 'Příkaz asistenta' : labels.toSet().join(' + ')),
        message:
            message == null || message.trim().isEmpty
                ? defaultMessage
                : message,
        commands: List.unmodifiable(builder.commands),
        baseRevision: project.revision,
        action: action,
        source: source,
      );
    } on Object catch (error) {
      return _unsupported(project, _errorText(error), source: source);
    }
  }

  /// Manual duplication with the assistant's cloning rules: new IDs and
  /// designations, copied internal wires and one offset shared by graphics.
  /// Only the engine's transaction size bounds it, not [maxCommands].
  List<EcadCommand> duplicateCommands({
    required EcadProject project,
    required String sheetId,
    required Set<String> deviceIds,
    required Set<String> graphicIds,
  }) {
    final sheet = project.pages.firstWhere((page) => page.id == sheetId);
    final graphics =
        sheet.graphics
            .where((graphic) => graphicIds.contains(graphic.id))
            .toList();
    final builder = _CommandBuilder(project, sheet, deviceIds, null);
    final offset =
        deviceIds.isEmpty
            ? const Vec2(20, 20)
            : builder.duplicate(
              1,
              limit: ProjectLimits.maxCommands,
              reserved: graphics.isEmpty ? 0 : 1,
            );
    return [
      ...builder.commands,
      if (graphics.isNotEmpty)
        AddGraphics(sheetId, [
          for (final graphic in graphics)
            graphic.copyWith(
              id: newId('graphic'),
              position: graphic.position + offset,
            ),
        ]),
    ];
  }

  static AssistantProposal _unsupported(
    EcadProject project,
    String message, {
    AssistantSource source = AssistantSource.localParser,
  }) => AssistantProposal(
    label: 'Návrh není k dispozici',
    message: message,
    commands: const [],
    baseRevision: project.revision,
    supported: false,
    source: source,
  );

  static String _errorText(Object error) {
    final message = error.toString().replaceFirst(
      RegExp(r'^(?:FormatException|Bad state):\s*'),
      '',
    );
    return message.length > 500 ? '${message.substring(0, 500)}…' : message;
  }

  static const _help =
      'Lokální parser tento příkaz neumí. Zkuste „Přidej jistič QF2“, '
      '„Vytvoř motorový vývod“, „Duplikuj výběr 3×“, '
      '„Přejmenuj výběr na KM2“, „Smaž výběr“ nebo „Zkontroluj projekt“. '
      'Volnější zadání vyžaduje připojený model Ollama.';

  static bool _hasOtherScope(String text) =>
      RegExp(r'\b(?:project|projekt|sheet|list)[a-z0-9]*\b').hasMatch(text);

  static const _threePole =
      r'(?:three.?(?:pole|phase)|3.?(?:pol|phase|faz)|tripol|trifaz|\b3p\b)';

  // Specific phrases come first: "rozpínací kontakt" must not become the
  // generic "kontakt", nor "třípólový jistič" the single-pole "jistič".
  static DeviceKind? _kindFromText(String text) {
    for (final entry
        in <DeviceKind, String>{
          DeviceKind.contactNc:
              r'normally.closed|\bnc\b|break.contact|rozpinac',
          DeviceKind.pushbuttonNo: r'push.?button|tlacitk',
          DeviceKind.contactNo: r'normally.open|no.contact|kontakt',
          DeviceKind.contactor: r'contactor|stykac',
          DeviceKind.threePoleBreaker:
              '^(?=.*$_threePole)(?=.*(?:breaker|jistic))',
          DeviceKind.threePoleDisconnector:
              '^(?=.*$_threePole)(?=.*(?:disconnector|isolator|odpojovac|odpinac))',
          DeviceKind.breaker: r'breaker|jistic',
          DeviceKind.disconnector: r'disconnector|isolator|odpojovac|odpinac',
          DeviceKind.fuse: r'fuse|pojistk',
          DeviceKind.currentTransformer:
              r'current.transformer|transformator.proudu|proudov\w* transformator|\bct\b',
          DeviceKind.transformer: r'transformer|transformator|trafo',
          DeviceKind.ammeter: r'ammeter|ampermetr',
          DeviceKind.voltmeter: r'voltmeter|voltmetr',
          DeviceKind.terminal: r'terminal|svork',
          DeviceKind.supply: r'supply|source|napajeni|privod|zdroj',
          DeviceKind.earth: r'earth|ground|uzemneni|ochranny',
          DeviceKind.coil: r'coil|civk',
          DeviceKind.lamp: r'lamp|light|kontrolk|svetl',
          DeviceKind.motor: r'motor',
        }.entries) {
      if (RegExp(entry.value).hasMatch(text)) return entry.key;
    }
    return null;
  }

  static String _normalize(String value) {
    var result = value.toLowerCase().replaceAll('×', 'x');
    const accented = 'áčďéěíňóřšťúůýž';
    const plain = 'acdeeinorstuuyz';
    for (var i = 0; i < accented.length; i++) {
      result = result.replaceAll(accented[i], plain[i]);
    }
    return result;
  }

  static void _fields(Map<String, dynamic> value, Set<String> allowed) {
    if (value.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Operace obsahuje nepovolené položky.');
    }
  }

  static String _string(
    Map<String, dynamic> value,
    String key, {
    required int maxLength,
  }) {
    final result = value[key];
    if (result is! String ||
        result.trim().isEmpty ||
        result.length > maxLength ||
        result.contains(RegExp(r'[\x00-\x1f]'))) {
      throw FormatException('Neplatná hodnota $key.');
    }
    return result.trim();
  }

  static String? _optionalString(
    Map<String, dynamic> value,
    String key, {
    required int maxLength,
    bool allowEmpty = false,
  }) {
    if (!value.containsKey(key)) return null;
    if (allowEmpty && value[key] == '') return '';
    return _string(value, key, maxLength: maxLength);
  }

  static double _coordinate(Object? value) {
    if (value is! num || !value.isFinite || value.abs() > 10000) {
      throw const FormatException(
        'Souřadnice musí být konečné číslo v rozsahu ±10 000.',
      );
    }
    return value.toDouble();
  }
}

class _CommandBuilder {
  _CommandBuilder(
    EcadProject project,
    this.sheet,
    this.selectedIds,
    this.insertionPoint,
  ) : devices = [...sheet.devices],
      wires = [...sheet.wires],
      _namingDevices = project.pages.expand((page) => page.devices).toList(),
      _reservedDesignations =
          project.pages
              .expand((page) => page.devices)
              .map((device) => _designationKey(device.designation))
              .toSet();

  final Sheet sheet;
  final Set<String> selectedIds;
  final Vec2? insertionPoint;
  final List<Device> devices;
  final List<Wire> wires;
  final List<Device> _namingDevices;
  final Set<String> _reservedDesignations;
  final List<EcadCommand> commands = [];
  static int _idCounter = 0;

  String _id(String kind) =>
      '${kind}_${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';

  static String _designationKey(String label) =>
      label.trim().toUpperCase().replaceFirst(RegExp(r'^-+'), '');

  // Reservations only grow, so a prefix can resume after its last result
  // instead of rescanning every taken number for each copy.
  final Map<String, int> _nextNumbers = {};

  String _designation(String prefix) {
    final key = _designationKey(prefix);
    for (var number = _nextNumbers[key] ?? 1; number < 100000; number++) {
      final candidate = '$prefix$number';
      if (!_reservedDesignations.contains(_designationKey(candidate))) {
        _nextNumbers[key] = number + 1;
        return candidate;
      }
    }
    throw const FormatException('Nelze vygenerovat jedinečné označení.');
  }

  // The drawing area excludes the sheet heading, border and title block.
  static const _paper = _PlacementBox(48, 110, 1052, 650);

  Vec2 _freePosition(_PlacementBox footprint) {
    final occupied = _occupiedFootprints();
    bool fits(Vec2 position) {
      final candidate = footprint.translated(position);
      return _paper.contains(candidate) &&
          !occupied.any((existing) => existing.overlaps(candidate));
    }

    if (commands.isEmpty && insertionPoint != null && fits(insertionPoint!)) {
      return insertionPoint!;
    }
    final firstX = ((_paper.left - footprint.left) / 10).ceil() * 10.0;
    final firstY = ((_paper.top - footprint.top) / 10).ceil() * 10.0;
    for (var y = firstY; y + footprint.bottom <= _paper.bottom; y += 10) {
      for (var x = firstX; x + footprint.right <= _paper.right; x += 10) {
        final position = Vec2(x, y);
        if (fits(position)) return position;
      }
    }
    throw const FormatException(
      'Na listu není dost volného místa. Přidejte nový list nebo přesuňte stávající přístroje.',
    );
  }

  /// Connected devices reserve their whole branch, including labels and route
  /// waypoints. This remains true after saving/reopening, without layout state.
  List<_PlacementBox> _occupiedFootprints() {
    final byId = {for (final device in devices) device.id: device};
    final links = <String, List<Wire>>{};
    for (final wire in wires) {
      (links[wire.from.deviceId] ??= []).add(wire);
      (links[wire.to.deviceId] ??= []).add(wire);
    }
    final visited = <String>{};
    final result = <_PlacementBox>[];
    for (final device in devices) {
      if (!visited.add(device.id)) continue;
      var bounds = _deviceFootprint(device);
      final queue = [device.id];
      for (var index = 0; index < queue.length; index++) {
        final id = queue[index];
        bounds = bounds.union(_deviceFootprint(byId[id]!));
        for (final wire in links[id] ?? const <Wire>[]) {
          for (final point in wire.waypoints) {
            bounds = bounds.union(
              _PlacementBox(point.x - 8, point.y - 8, point.x + 8, point.y + 8),
            );
          }
          final other =
              wire.from.deviceId == id ? wire.to.deviceId : wire.from.deviceId;
          if (byId.containsKey(other) && visited.add(other)) queue.add(other);
        }
      }
      result.add(bounds);
    }
    return result;
  }

  static _PlacementBox _deviceFootprint(Device device) {
    final definition = SymbolCatalog.definitionFor(device.kind);
    final angle = device.rotation * math.pi / 180;
    final halfWidth =
        (definition.width * math.cos(angle).abs() +
            definition.height * math.sin(angle).abs()) /
        2;
    final halfHeight =
        (definition.height * math.cos(angle).abs() +
            definition.width * math.sin(angle).abs()) /
        2;
    final subtitle = device.rating.isEmpty ? definition.label : device.rating;
    var labelWidth = math.max(
      _textWidth(device.designation, 12),
      _textWidth(subtitle, 9),
    );
    var labelBottom = 22.0;
    if (device.description.isNotEmpty) {
      // SVG export wraps descriptions at 45 characters; keep that text clear.
      labelWidth = math.max(
        labelWidth,
        math.min(_textWidth(device.description, 9), 285),
      );
      labelBottom = 30 + ((device.description.length / 45).ceil()) * 13.0;
    }
    return _PlacementBox(
      device.position.x - halfWidth - 6,
      device.position.y - math.max(halfHeight + 6, 25),
      device.position.x + halfWidth + 16 + labelWidth + 6,
      device.position.y + math.max(halfHeight + 6, labelBottom),
    );
  }

  static double _textWidth(String value, double size) {
    var width = 0.0;
    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      final factor =
          'MW@%&#'.contains(character)
              ? .95
              : 'ilI1.,:;|! \'`'.contains(character)
              ? .32
              : character.toUpperCase() == character
              ? .72
              : .58;
      width += size * factor;
    }
    return width;
  }

  Device insert(
    DeviceKind kind, {
    String? designation,
    String rating = '',
    String description = '',
    Vec2? position,
  }) {
    var device = Device(
      id: _id('device'),
      kind: kind,
      designation:
          designation ?? SymbolCatalog.nextDesignation(_namingDevices, kind),
      position: position ?? const Vec2(0, 0),
      description: description,
      rating: rating,
    );
    if (position == null) {
      device = device.copyWith(
        position: _freePosition(_deviceFootprint(device)),
      );
    }
    commands.add(AddDevice(sheet.id, device));
    devices.add(device);
    _namingDevices.add(device);
    _reservedDesignations.add(_designationKey(device.designation));
    return device;
  }

  void motorBranch(String rating) {
    // Plan the complete footprint before adding any command. This includes the
    // PE device at (+140, +470) and the labels to the right of every symbol.
    final prototypes = [
      for (final entry in [
        (DeviceKind.supply, const Vec2(0, 0)),
        (DeviceKind.breaker, const Vec2(0, 120)),
        (DeviceKind.contactor, const Vec2(0, 250)),
        (DeviceKind.motor, const Vec2(0, 390)),
        (DeviceKind.earth, const Vec2(140, 470)),
      ])
        Device(
          id: 'placement_preview',
          kind: entry.$1,
          designation: SymbolCatalog.nextDesignation(_namingDevices, entry.$1),
          position: entry.$2,
          rating: entry.$1 == DeviceKind.motor ? rating : '',
        ),
    ];
    final footprint = prototypes
        .map(_deviceFootprint)
        .reduce((a, b) => a.union(b));
    final origin = _freePosition(footprint);
    final supply = insert(DeviceKind.supply, position: origin);
    final breaker = insert(
      DeviceKind.breaker,
      position: Vec2(origin.x, origin.y + 120),
    );
    final contactor = insert(
      DeviceKind.contactor,
      position: Vec2(origin.x, origin.y + 250),
    );
    final motor = insert(
      DeviceKind.motor,
      position: Vec2(origin.x, origin.y + 390),
      rating: rating,
    );
    final earth = insert(
      DeviceKind.earth,
      position: Vec2(origin.x + 140, origin.y + 470),
    );
    _connect(supply, 'out', breaker, 'in');
    _connect(breaker, 'out', contactor, 'in');
    _connect(contactor, 'out', motor, 'in');
    final motorPe = SymbolCatalog.worldPortPosition(motor, 'pe');
    final earthPort = SymbolCatalog.worldPortPosition(earth, 'in');
    _connect(motor, 'pe', earth, 'in', [Vec2(earthPort.x, motorPe.y)]);
  }

  void _connect(
    Device from,
    String fromPort,
    Device to,
    String toPort, [
    List<Vec2> waypoints = const [],
  ]) {
    final wire = Wire(
      id: _id('wire'),
      from: TerminalRef(deviceId: from.id, portId: fromPort),
      to: TerminalRef(deviceId: to.id, portId: toPort),
      waypoints: waypoints,
    );
    commands.add(AddWire(sheet.id, wire));
    wires.add(wire);
  }

  List<Device> get _selection {
    final selection =
        devices.where((device) => selectedIds.contains(device.id)).toList();
    if (selection.isEmpty) {
      throw const FormatException('Nejprve vyberte přístroj na výkresu.');
    }
    if (selection.length != selectedIds.length) {
      throw const FormatException(
        'Výběr již není aktuální. Vyberte přístroje znovu.',
      );
    }
    return selection;
  }

  void rename(String designation) {
    final selected = _selection;
    if (selected.length != 1) {
      throw const FormatException(
        'Pro přejmenování vyberte právě jeden přístroj.',
      );
    }
    final old = selected.single;
    final updated = _copy(
      old,
      id: old.id,
      designation: designation,
      position: old.position,
    );
    commands.add(UpdateDevice(sheet.id, updated));
    _namingDevices.add(updated);
    _reservedDesignations.add(_designationKey(updated.designation));
    devices[devices.indexWhere((device) => device.id == old.id)] = updated;
  }

  void delete() {
    final ids = _selection.map((device) => device.id).toSet();
    commands.add(DeleteDevices(sheet.id, ids));
    devices.removeWhere((device) => ids.contains(device.id));
    wires.removeWhere(
      (wire) =>
          ids.contains(wire.from.deviceId) || ids.contains(wire.to.deviceId),
    );
  }

  /// Returns the offset of the first copy. [reserved] commands are added by
  /// the caller within the same [limit].
  Vec2 duplicate(
    int count, {
    int limit = AssistantService.maxCommands,
    int reserved = 0,
  }) {
    final selected = _selection;
    final internalWires =
        wires
            .where(
              (wire) =>
                  selectedIds.contains(wire.from.deviceId) &&
                  selectedIds.contains(wire.to.deviceId),
            )
            .toList();
    if ((selected.length + internalWires.length) * count +
            commands.length +
            reserved >
        limit) {
      throw FormatException(
        'Kopie překračují limit $limit změn. Snižte počet kopií nebo výběr.',
      );
    }
    final minX = selected.map((device) => device.position.x).reduce(math.min);
    final maxX = selected.map((device) => device.position.x).reduce(math.max);
    final spacing = math.max(160.0, maxX - minX + 160);
    for (var copy = 1; copy <= count; copy++) {
      final ids = <String, String>{};
      final dx = spacing * copy;
      for (final device in selected) {
        final id = _id('device');
        ids[device.id] = id;
        final prefix = device.designation.replaceFirst(RegExp(r'\d+$'), '');
        final clone = _copy(
          device,
          id: id,
          designation: _designation(
            prefix.isEmpty
                ? SymbolCatalog.definitionFor(device.kind).prefix
                : prefix,
          ),
          position: Vec2(device.position.x + dx, device.position.y),
        );
        commands.add(AddDevice(sheet.id, clone));
        devices.add(clone);
        _namingDevices.add(clone);
        _reservedDesignations.add(_designationKey(clone.designation));
      }
      for (final wire in internalWires) {
        final clone = Wire(
          id: _id('wire'),
          from: TerminalRef(
            deviceId: ids[wire.from.deviceId]!,
            portId: wire.from.portId,
          ),
          to: TerminalRef(
            deviceId: ids[wire.to.deviceId]!,
            portId: wire.to.portId,
          ),
          waypoints:
              wire.waypoints
                  .map((point) => Vec2(point.x + dx, point.y))
                  .toList(),
        );
        commands.add(AddWire(sheet.id, clone));
        wires.add(clone);
      }
    }
    return Vec2(spacing, 0);
  }

  Device _copy(
    Device source, {
    required String id,
    required String designation,
    required Vec2 position,
  }) => Device(
    id: id,
    kind: source.kind,
    designation: designation,
    position: position,
    description: source.description,
    rating: source.rating,
    rotation: source.rotation,
  );
}

class _PlacementBox {
  const _PlacementBox(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;

  _PlacementBox translated(Vec2 delta) => _PlacementBox(
    left + delta.x,
    top + delta.y,
    right + delta.x,
    bottom + delta.y,
  );
  _PlacementBox union(_PlacementBox other) => _PlacementBox(
    math.min(left, other.left),
    math.min(top, other.top),
    math.max(right, other.right),
    math.max(bottom, other.bottom),
  );
  bool contains(_PlacementBox other) =>
      left <= other.left &&
      top <= other.top &&
      right >= other.right &&
      bottom >= other.bottom;
  bool overlaps(_PlacementBox other) =>
      left < other.right &&
      right > other.left &&
      top < other.bottom &&
      bottom > other.top;
}
