import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ecad_core/ecad_core.dart';

/// Only explicit selection dependencies cross the system clipboard boundary.
class SchematicFragment {
  SchematicFragment._(
    this.sessionId,
    this.generation,
    this.instanceId,
    this.data,
    this.anchor,
  );

  static const begin = 'OPEN_ECAD_FRAGMENT/1\n';
  static const end = '\nEND_OPEN_ECAD_FRAGMENT';
  static const maxBytes = 2 * 1024 * 1024;
  static const maxObjects = 500;
  final String sessionId, instanceId;
  final int generation;
  final EcadProject data;
  final Vec2 anchor;
  Sheet get sheet => data.pages.single;

  static SchematicFragment capture({
    required EcadProject project,
    required Sheet sheet,
    required Set<String> selectedIds,
    required String sessionId,
    required String instanceId,
    required int generation,
  }) {
    if (sheet.type == SheetType.cabinetLayout ||
        sheet.type == SheetType.billOfMaterials) {
      throw const FormatException(
        'Schránka podporuje schémata a grafické formuláře. Montážní zobrazení ani kusovník nelze kopírovat jako nové fyzické kusy.',
      );
    }
    final devices =
        sheet.devices.where((d) => selectedIds.contains(d.id)).toList();
    final markers =
        sheet.continuations.where((m) => selectedIds.contains(m.id)).toList();
    final corners =
        sheet.corners.where((c) => selectedIds.contains(c.id)).toList();
    final graphics =
        sheet.graphics.where((g) => selectedIds.contains(g.id)).toList();
    final ids = {
      for (final d in devices) d.id,
      for (final m in markers) m.id,
      for (final c in corners) c.id,
      for (final g in graphics) g.id,
    };
    if (ids.isEmpty) {
      throw const FormatException('Nejprve vyberte objekty ve výkrese.');
    }
    if (!ids.containsAll(selectedIds)) {
      throw const FormatException(
        'Výběr obsahuje objekt, který schránka nepodporuje.',
      );
    }
    final componentIds = devices.map((d) => d.componentId).toSet();
    final components =
        project.components.where((c) => componentIds.contains(c.id)).map((c) {
          if (c.procurement.includedInComponentId case final parent?) {
            if (!componentIds.contains(parent)) {
              throw const FormatException(
                'Vyberte také nadřazený kus zahrnuté komponenty.',
              );
            }
          }
          return c.copyWith(note: '');
        }).toList();
    final articleIds = components.map((c) => c.articleId).toSet();
    final stripIds = components.map((c) => c.terminal?.stripId).toSet();
    final linkIds = markers.map((m) => m.linkId).toSet();
    final positions = [
      for (final d in devices) d.position,
      for (final m in markers) m.position,
      for (final c in corners) c.position,
      for (final g in graphics) g.position,
    ];
    final fragment = SchematicFragment._(
      sessionId,
      generation,
      instanceId,
      EcadProject(
        id: newId('clipboard'),
        name: 'Clipboard',
        components: components,
        articles:
            project.articles
                .where((a) => articleIds.contains(a.id))
                .map(_cleanArticle)
                .toList(),
        terminalStrips:
            project.terminalStrips
                .where((s) => stripIds.contains(s.id))
                .toList(),
        continuationLinks:
            project.continuationLinks
                .where((l) => linkIds.contains(l.id))
                .toList(),
        pages: [
          Sheet(
            id: newId('clipboard-sheet'),
            name: 'Clipboard',
            number: '1',
            devices: devices,
            continuations: markers,
            corners: corners,
            graphics: graphics,
            wires:
                sheet.wires
                    .where(
                      (w) =>
                          ids.contains(w.from.ownerId) &&
                          ids.contains(w.to.ownerId),
                    )
                    .toList(),
          ),
        ],
      ),
      Vec2(
        positions.map((p) => p.x).reduce(math.min),
        positions.map((p) => p.y).reduce(math.min),
      ),
    );
    fragment._validate();
    return decode(fragment.encode());
  }

  String encode() {
    final payload = {
      'instance': instanceId,
      'session': sessionId,
      'generation': generation,
      'anchor': anchor.toJson(),
      'devices': sheet.devices.map((v) => v.toJson()).toList(),
      'markers': sheet.continuations.map((v) => v.toJson()).toList(),
      'corners': sheet.corners.map((v) => v.toJson()).toList(),
      'graphics': sheet.graphics.map((v) => v.toJson()).toList(),
      'wires': sheet.wires.map((v) => v.toJson()).toList(),
      'components': data.components.map((v) => v.toJson()).toList(),
      'articles': data.articles.map((v) => v.toJson()).toList(),
      'strips': data.terminalStrips.map((v) => v.toJson()).toList(),
      'links': data.continuationLinks.map((v) => v.toJson()).toList(),
    };
    return '$begin${jsonEncode(payload)}$end';
  }

  static SchematicFragment decode(String text) {
    if (text.length > maxBytes || utf8.encode(text).length > maxBytes) {
      throw const FormatException('Výběr překračuje limit schránky 2 MiB.');
    }
    if (!text.startsWith(begin) || !text.endsWith(end)) {
      throw const FormatException(
        'Schránka neobsahuje podporovaný výběr Open ECAD (verze 1).',
      );
    }
    final json = text.substring(begin.length, text.length - end.length);
    var depth = 0, nodes = 0;
    var quoted = false, escaped = false;
    for (final char in json.codeUnits) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (char == 92) {
          escaped = true;
        } else if (char == 34) {
          quoted = false;
        }
      } else if (char == 34) {
        quoted = true;
      } else if (char == 123 || char == 91) {
        if (++depth > 32 || ++nodes > 50000) {
          throw const FormatException('Data schránky jsou příliš složitá.');
        }
      } else if (char == 125 || char == 93) {
        depth--;
      }
    }
    final map = jsonObject(
      jsonDecode(json),
      'clipboard',
      allowed: const {
        'instance',
        'session',
        'generation',
        'anchor',
        'devices',
        'markers',
        'corners',
        'graphics',
        'wires',
        'components',
        'articles',
        'strips',
        'links',
      },
    );
    List<T> read<T>(String key, T Function(Object?) parse) =>
        jsonList(map, key, max: maxObjects).map(parse).toList();
    final generation = map['generation'];
    if (generation is! int ||
        generation < 0 ||
        generation > ProjectLimits.maxRevision) {
      throw const FormatException('Neplatná generace dokumentu ve schránce.');
    }
    final data = EcadProject(
      id: newId('clipboard'),
      name: 'Clipboard',
      articles: read('articles', Article.fromJson),
      components: read('components', Component.fromJson),
      terminalStrips: read('strips', TerminalStrip.fromJson),
      continuationLinks: read('links', ContinuationLink.fromJson),
      pages: [
        Sheet(
          id: newId('clipboard-sheet'),
          name: 'Clipboard',
          number: '1',
          devices: read('devices', Device.fromJson),
          continuations: read('markers', ContinuationMarker.fromJson),
          corners: read('corners', ConnectionCorner.fromJson),
          graphics: read('graphics', DrawingElement.fromJson),
          wires: read('wires', Wire.fromJson),
        ),
      ],
    );
    final fragment = SchematicFragment._(
      jsonString(map, 'session', max: 128),
      generation,
      jsonString(map, 'instance', max: 128),
      data,
      Vec2.fromJson(map['anchor']),
    );
    fragment._validate();
    return fragment;
  }

  void _validate() {
    final total =
        sheet.devices.length +
        sheet.continuations.length +
        sheet.corners.length +
        sheet.graphics.length +
        sheet.wires.length;
    if (total == 0 || total > maxObjects) {
      throw const FormatException(
        'Schránka podporuje 1 až 500 objektů včetně vnitřních vodičů.',
      );
    }
    if (!anchor.x.isFinite ||
        !anchor.y.isFinite ||
        anchor.x.abs() > ProjectLimits.maxCoordinate ||
        anchor.y.abs() > ProjectLimits.maxCoordinate) {
      throw const FormatException('Neplatná poloha ve schránce.');
    }
    final payloadChars = sheet.graphics.fold<int>(
      0,
      (sum, g) => sum + g.imageData.length + g.text.length,
    );
    final pathSegments = sheet.graphics.fold<int>(
      0,
      (sum, g) => sum + g.path.length,
    );
    if (payloadChars > maxBytes || pathSegments > 10000) {
      throw const FormatException(
        'Grafika překračuje limit schránky (2 MiB nebo 10000 segmentů).',
      );
    }
    requireValidProject(data);
    var imagePixels = 0;
    for (final graphic in sheet.graphics.where(
      (g) => g.kind == DrawingKind.image,
    )) {
      final header = ByteData.sublistView(base64Decode(graphic.imageData));
      imagePixels += header.getUint32(16) * header.getUint32(20);
      if (imagePixels > 16 * 1024 * 1024) {
        throw const FormatException(
          'Obrázky ve výběru překračují celkový limit 16 megapixelů.',
        );
      }
    }
    bool exact(Iterable<String> ids, Iterable<String?> used) {
      final available = ids.toSet();
      final referenced = used.whereType<String>().toSet();
      return available.length == referenced.length &&
          available.containsAll(referenced);
    }

    if (!exact(
          data.components.map((v) => v.id),
          sheet.devices.map((v) => v.componentId),
        ) ||
        !exact(
          data.articles.map((v) => v.id),
          data.components.map((v) => v.articleId),
        ) ||
        !exact(
          data.terminalStrips.map((v) => v.id),
          data.components.map((v) => v.terminal?.stripId),
        ) ||
        !exact(
          data.continuationLinks.map((v) => v.id),
          sheet.continuations.map((v) => v.linkId),
        ) ||
        data.components.any((v) => v.note.isNotEmpty) ||
        data.articles.any((v) => v.note.isNotEmpty || v.sourceUrl != null)) {
      throw const FormatException(
        'Schránka obsahuje nesouvisející závislosti nebo soukromé poznámky.',
      );
    }
  }

  ClipboardPlacement prepare({
    required EcadProject project,
    required Sheet target,
    required String sessionId,
    required String instanceId,
    required int generation,
  }) {
    if (target.type == SheetType.cabinetLayout ||
        target.type == SheetType.billOfMaterials ||
        (target.type == SheetType.form &&
            (sheet.devices.isNotEmpty ||
                sheet.continuations.isNotEmpty ||
                sheet.corners.isNotEmpty))) {
      throw const FormatException(
        'Tento typ listu nepodporuje vložení vybraných objektů.',
      );
    }
    final sameDocument =
        sessionId == this.sessionId &&
        generation == this.generation &&
        instanceId == this.instanceId;
    final commands = <EcadCommand>[];
    final articles = <Article>[];
    final articleIds = <String, String>{};
    for (final a in data.articles) {
      final existing = project.articleById(a.id);
      if (sameDocument &&
          existing != null &&
          jsonEncode(_cleanArticle(existing).toJson()) ==
              jsonEncode(a.toJson())) {
        articleIds[a.id] = a.id;
      } else {
        final copy = a.copyWith(id: newId('article'));
        articles.add(copy);
        commands.add(AddArticle(copy));
        articleIds[a.id] = copy.id;
      }
    }
    final components = <Component>[];
    final strips = <TerminalStrip>[];
    EcadProject allocation() => project.copyWith(
      components: [...project.components, ...components],
      terminalStrips: [...project.terminalStrips, ...strips],
    );
    final componentIds = {
      for (final c in data.components) c.id: newId('component'),
    };
    final terminals = {
      for (final c in data.components)
        for (final t in c.electrical?.terminals ?? <ComponentTerminal>[])
          t.id: newId('terminal'),
    };
    final functions = {
      for (final c in data.components)
        for (final f in c.electrical?.functions ?? <ComponentFunction>[])
          f.id: newId('function'),
    };
    for (final c in data.components) {
      TerminalAssignment? terminal;
      if (c.terminal != null) {
        var strip =
            [
              ...project.terminalStrips,
              ...strips,
            ].where((s) => s.reference.context == target.structure).firstOrNull;
        if (strip == null) {
          strip = TerminalStrip(
            id: newId('strip'),
            reference: ComponentReference(
              context: target.structure,
              localDesignation: nextLocalDesignation(
                allocation(),
                target.structure,
                'X',
              ),
            ),
          );
          strips.add(strip);
          commands.add(AddTerminalStrip(strip));
        }
        terminal = c.terminal!.copyWith(
          stripId: strip.id,
          number: nextTerminalNumber(allocation(), strip),
        );
      }
      final device = sheet.devices.firstWhere((d) => d.componentId == c.id);
      final prefix =
          device.kind == null
              ? 'A'
              : SymbolCatalog.definitionFor(device.kind!).prefix;
      final copy = c.copyWith(
        id: componentIds[c.id],
        designation: null,
        reference:
            terminal == null
                ? ComponentReference(
                  context: target.structure,
                  localDesignation: nextLocalDesignation(
                    allocation(),
                    target.structure,
                    prefix,
                  ),
                )
                : null,
        terminal: terminal,
        articleId: articleIds[c.articleId],
        procurement: Procurement(
          source: c.procurement.source,
          includedInComponentId:
              componentIds[c.procurement.includedInComponentId],
        ),
        electrical:
            c.electrical == null
                ? null
                : ElectricalModel(
                  terminals: [
                    for (final t in c.electrical!.terminals)
                      t.copyWith(id: terminals[t.id]),
                  ],
                  functions: [
                    for (final f in c.electrical!.functions)
                      f.copyWith(
                        id: functions[f.id],
                        terminalIds:
                            f.terminalIds.map((id) => terminals[id]!).toList(),
                      ),
                  ],
                ),
      );
      components.add(copy);
      commands.add(AddComponent(copy));
    }
    final links = <ContinuationLink>[];
    final linkIds = <String, String>{};
    final labels =
        project.continuationLinks
            .map((l) => l.label.trim().toLowerCase())
            .toSet();
    for (final link in data.continuationLinks) {
      if (sameDocument && project.continuationLinkById(link.id) != null) {
        linkIds[link.id] = link.id;
      } else {
        var label = link.label;
        for (var n = 2; labels.contains(label.trim().toLowerCase()); n++) {
          label =
              '${link.label.substring(0, math.min(link.label.length, 180))} ($n)';
        }
        labels.add(label.trim().toLowerCase());
        final copy = link.copyWith(id: newId('link'), label: label);
        links.add(copy);
        commands.add(AddContinuationLink(copy));
        linkIds[link.id] = copy.id;
      }
    }
    final ids = {
      for (final d in sheet.devices) d.id: newId('device'),
      for (final m in sheet.continuations) m.id: newId('marker'),
      for (final c in sheet.corners) c.id: newId('corner'),
      for (final g in sheet.graphics) g.id: newId('graphic'),
    };
    WireEndpoint endpoint(WireEndpoint e) => switch (e) {
      TerminalRef e => TerminalRef(
        deviceId: ids[e.deviceId]!,
        portId: e.portId,
      ),
      ContinuationRef e => ContinuationRef(markerId: ids[e.markerId]!),
      CornerRef e => CornerRef(cornerId: ids[e.cornerId]!, portId: e.portId),
    };
    final cloned = Sheet(
      id: target.id,
      name: target.name,
      number: target.number,
      devices: [
        for (final d in sheet.devices)
          d.copyWith(
            id: ids[d.id],
            componentId: componentIds[d.componentId],
            functionId: functions[d.functionId],
            symbol: switch (d.symbol) {
              BuiltinSymbolSpec s => BuiltinSymbolSpec(
                kind: s.kind,
                bindings: s.bindings.map((k, v) => MapEntry(k, terminals[v]!)),
              ),
              TerminalSymbolSpec s => s.copyWith(
                terminalId: terminals[s.terminalId]!,
              ),
              PortBlockSpec s => s.copyWith(
                ports: [
                  for (final p in s.ports)
                    p.copyWith(terminalId: terminals[p.terminalId]),
                ],
              ),
            },
          ),
      ],
      continuations: [
        for (final m in sheet.continuations)
          m.copyWith(id: ids[m.id], linkId: linkIds[m.linkId]),
      ],
      corners: [
        for (final c in sheet.corners)
          ConnectionCorner(
            id: ids[c.id]!,
            position: c.position,
            orientation: c.orientation,
          ),
      ],
      graphics: [for (final g in sheet.graphics) g.copyWith(id: ids[g.id])],
      wires: [
        for (final w in sheet.wires)
          w.copyWith(
            id: newId('wire'),
            from: endpoint(w.from),
            to: endpoint(w.to),
          ),
      ],
    );
    final preview = EcadProject(
      id: 'clipboard-preview',
      name: 'Clipboard',
      components: components,
      articles: [
        for (final id in articleIds.values.toSet())
          project.articleById(id) ?? articles.firstWhere((a) => a.id == id),
      ],
      terminalStrips: [
        for (final id
            in components
                .map((c) => c.terminal?.stripId)
                .whereType<String>()
                .toSet())
          project.terminalStripById(id) ?? strips.firstWhere((s) => s.id == id),
      ],
      continuationLinks: [
        for (final id in linkIds.values.toSet())
          project.continuationLinkById(id) ??
              links.firstWhere((l) => l.id == id),
      ],
      pages: [cloned],
    );
    final placement = ClipboardPlacement._(
      preview,
      anchor,
      commands,
      ids.values.toSet(),
    );
    // Validate the exact combined graph before a preview can reach the canvas.
    ProjectEngine(project).execute(placement.commandsAt(anchor));
    return placement;
  }
}

Article _cleanArticle(Article a) => a.copyWith(note: '', sourceUrl: null);

class ClipboardPlacement {
  ClipboardPlacement._(
    this.preview,
    this.anchor,
    List<EcadCommand> dependencies,
    Set<String> selectedIds,
  ) : dependencies = List.unmodifiable(dependencies),
      selectedIds = Set.unmodifiable(selectedIds);
  final EcadProject preview;
  final Vec2 anchor;
  final List<EcadCommand> dependencies;
  final Set<String> selectedIds;

  List<EcadCommand> commandsAt(Vec2 position) {
    final sheet = preview.pages.single;
    final delta = position - anchor;
    final commands = <EcadCommand>[
      ...dependencies,
      for (final d in sheet.devices)
        AddDevice(sheet.id, d.copyWith(position: d.position + delta)),
      for (final m in sheet.continuations)
        AddContinuationMarker(
          sheet.id,
          m.copyWith(position: m.position + delta),
        ),
      for (final c in sheet.corners)
        AddConnectionCorner(sheet.id, c.copyWith(position: c.position + delta)),
      if (sheet.graphics.isNotEmpty)
        AddGraphics(sheet.id, [
          for (final g in sheet.graphics)
            g.copyWith(position: g.position + delta),
        ]),
      for (final w in sheet.wires)
        AddWire(
          sheet.id,
          w.copyWith(waypoints: w.waypoints.map((p) => p + delta).toList()),
        ),
    ];
    if (commands.length > ProjectLimits.maxCommands) {
      throw const FormatException(
        'Vložení překračuje limit 1000 změn. Zmenšete výběr.',
      );
    }
    return commands;
  }
}
