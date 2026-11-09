import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import '../app/controller.dart';
import 'inventory.dart';

bool electricalSheet(Sheet s) =>
    s.type == SheetType.multiLine || s.type == SheetType.singleLine;
Future<void> showOccurrenceDialog(
  BuildContext context,
  EditorController app, {
  Component? component,
  Device? replace,
  String? sheetId,
}) {
  final targetSheetId =
      replace == null
          ? (sheetId ?? app.sheet.id)
          : app.project.pages
              .firstWhere((s) => s.deviceById(replace.id) != null)
              .id;
  return showDocumentEditorDialog(
    context,
    app,
    (generation) =>
        _OccurrenceDialog(app, component, replace, targetSheetId, generation),
  );
}

class _OccurrenceDialog extends StatefulWidget {
  const _OccurrenceDialog(
    this.app,
    this.component,
    this.replace,
    this.sheetId,
    this.generation,
  );
  final EditorController app;
  final Component? component;
  final Device? replace;
  final String sheetId;
  final int generation;
  @override
  State<_OccurrenceDialog> createState() => _OccurrenceDialogState();
}

class _OccurrenceDialogState extends State<_OccurrenceDialog> {
  late String? componentId =
      widget.component?.id ?? widget.replace?.componentId;
  late String? functionId = widget.replace?.functionId;
  DeviceKind? kind;
  late OccurrenceMode mode = widget.replace?.mode ?? OccurrenceMode.wiring;
  String? error;
  final bindings = <String, String>{};
  @override
  void initState() {
    super.initState();
    if (widget.replace == null) _selectTerminal();
  }

  void _selectTerminal() {
    final component = widget.app.project.componentById(componentId ?? '');
    if (component?.terminal == null) return;
    functionId = component!.electrical!.functions.first.id;
    kind = DeviceKind.terminal;
    mode =
        widget.app.project.pages.any(
              (s) => s.devices.any(
                (d) =>
                    d.componentId == componentId &&
                    d.functionId == functionId &&
                    d.mode == OccurrenceMode.wiring,
              ),
            )
            ? OccurrenceMode.reference
            : OccurrenceMode.wiring;
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final component = app.project.componentById(componentId ?? '');
    final function = component?.electrical?.functionById(functionId ?? '');
    return editorDialog(
      context,
      title:
          widget.replace == null
              ? 'Další zobrazení existujícího kusu'
              : 'Přiřadit výskyt komponentě',
      error: error,
      saveLabel: 'Použít',
      save: () {
        if (!app.isDocumentCurrent(widget.generation)) {
          setState(() => error = 'Původní projekt již není otevřen.');
          return;
        }
        final sheet = app.project.sheetById(widget.sheetId);
        if (sheet == null || !electricalSheet(sheet)) {
          setState(() => error = 'Nejprve otevřete elektrický list.');
          return;
        }
        if (component == null) {
          setState(() => error = 'Vyberte komponentu.');
          return;
        }
        bool success;
        if (widget.replace case final device?) {
          if (sheet.deviceById(device.id) != device) {
            setState(
              () =>
                  error =
                      'Původní zobrazení se změnilo. Otevřete editor znovu.',
            );
            return;
          }
          if (function == null ||
              geometryFor(
                device,
              ).ports.any((p) => !bindings.containsKey(p.id))) {
            setState(
              () =>
                  error =
                      'Vyberte existující funkci a přesný vývod pro každý port.',
            );
            return;
          }
          final symbol = switch (device.symbol) {
            TerminalSymbolSpec s => s.copyWith(
              terminalId:
                  bindings.values.toSet().length == 1
                      ? bindings.values.first
                      : '',
            ),
            BuiltinSymbolSpec s => s.copyWith(bindings: bindings),
            PortBlockSpec s => s.copyWith(
              ports: [
                for (final p in s.ports) p.copyWith(terminalId: bindings[p.id]),
              ],
            ),
          };
          success = app.updateDevice(
            device.copyWith(
              componentId: component.id,
              functionId: function.id,
              symbol: symbol,
              mode: mode,
              isMainFunction:
                  component.id == device.componentId && device.isMainFunction,
            ),
            sheetId: widget.sheetId,
          );
        } else {
          success = app.addOccurrence(
            component,
            functionId: functionId,
            kind: kind,
            mode: mode,
            sheetId: widget.sheetId,
          );
        }
        if (success) {
          Navigator.pop(context);
        } else {
          setState(() => error = app.status);
        }
      },
      children: [
        DropdownButtonFormField<String>(
          itemHeight: null,
          initialValue: componentId,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Existující fyzický kus',
          ),
          items: [
            for (final c in app.project.components.where(
              (c) =>
                  c.kind == ComponentKind.physical &&
                  c.usage == ComponentUsage.installed,
            ))
              DropdownMenuItem(
                value: c.id,
                child: Text(
                  '${app.resolver.fullDesignation(c)} · ${c.description}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged:
              (v) => setState(() {
                componentId = v;
                functionId = null;
                kind = null;
                bindings.clear();
                if (widget.replace == null) {
                  mode = OccurrenceMode.wiring;
                  _selectTerminal();
                }
              }),
        ),
        DropdownButtonFormField<String>(
          itemHeight: null,
          key: ValueKey('$componentId-$functionId'),
          initialValue: functionId ?? '',
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Elektrická funkce'),
          items: [
            if (component?.terminal == null || widget.replace != null)
              DropdownMenuItem(
                value: '',
                child: Text(
                  widget.replace == null
                      ? 'Nová funkce tohoto kusu'
                      : 'Vyberte funkci',
                ),
              ),
            for (final f
                in component?.electrical?.functions ?? <ComponentFunction>[])
              DropdownMenuItem(
                value: f.id,
                child: Text('${f.name} (${f.terminalIds.length} vývodů)'),
              ),
          ],
          onChanged:
              (v) => setState(() {
                functionId = optionalText(v!);
                bindings.clear();
                if (widget.replace == null) {
                  mode =
                      app.project.pages.any(
                            (s) => s.devices.any(
                              (d) =>
                                  d.componentId == componentId &&
                                  d.functionId == functionId &&
                                  d.mode == OccurrenceMode.wiring,
                            ),
                          )
                          ? OccurrenceMode.reference
                          : OccurrenceMode.wiring;
                }
              }),
        ),
        if (widget.replace == null && component?.terminal != null)
          const Text('Průchozí svorka · jedna vodivá funkce'),
        if (widget.replace == null && component?.terminal == null)
          DropdownButtonFormField<String>(
            itemHeight: null,
            key: ValueKey('symbol-$componentId'),
            initialValue: kind?.name ?? '',
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Zobrazení'),
            items: [
              const DropdownMenuItem(
                value: '',
                child: Text('Obecný blok s porty'),
              ),
              for (final k in DeviceKind.values.where(
                (k) => k != DeviceKind.earth && k != DeviceKind.terminal,
              ))
                DropdownMenuItem(
                  value: k.name,
                  child: Text(SymbolCatalog.definitionFor(k).label),
                ),
            ],
            onChanged:
                (v) => setState(
                  () => kind = v!.isEmpty ? null : DeviceKind.values.byName(v),
                ),
          ),
        if (widget.replace case final device?) ...[
          const Text(
            'Přiřazení mění elektrickou identitu připojených vodičů. Každý port přiřaďte výslovně.',
          ),
          for (final p in geometryFor(device).ports)
            DropdownButtonFormField<String>(
              itemHeight: null,
              key: ValueKey('$componentId-$functionId-${p.id}'),
              decoration: InputDecoration(labelText: 'Port ${p.id} → vývod'),
              items: [
                for (final id in function?.terminalIds ?? <String>[])
                  DropdownMenuItem(
                    value: id,
                    child: Text(
                      component!.electrical!.terminalById(id)!.designation,
                    ),
                  ),
              ],
              onChanged: (v) => bindings[p.id] = v!,
            ),
        ],
        DropdownButtonFormField<OccurrenceMode>(
          itemHeight: null,
          key: ValueKey(mode),
          initialValue: mode,
          decoration: const InputDecoration(labelText: 'Režim'),
          items: const [
            DropdownMenuItem(
              value: OccurrenceMode.wiring,
              child: Text('Zapojovací zobrazení'),
            ),
            DropdownMenuItem(
              value: OccurrenceMode.reference,
              child: Text('Referenční zobrazení (bez vodičů)'),
            ),
          ],
          onChanged: (v) => mode = v!,
        ),
        const Text(
          'Další zobrazení nezvyšuje kusovník. Nový skutečný kus založte v seznamu Přístroje.',
        ),
      ],
    );
  }
}

Future<void> editPorts(
  BuildContext context,
  EditorController app,
  Device device,
) {
  final sheetId =
      app.project.pages.firstWhere((s) => s.deviceById(device.id) != null).id;
  return showDocumentEditorDialog(
    context,
    app,
    (generation) => _PortsDialog(app, device, sheetId, generation),
  );
}

class _TerminalDraft {
  _TerminalDraft(String name, String signal)
    : name = TextEditingController(text: name),
      signal = TextEditingController(text: signal);
  final TextEditingController name, signal;
  void dispose() {
    name.dispose();
    signal.dispose();
  }
}

class _PortDraft {
  _PortDraft(
    this.portId,
    this.terminalId,
    this.terminal,
    this.side,
    double fraction, {
    String? pointName,
  }) : pointName =
           pointName == null ? null : TextEditingController(text: pointName),
       fraction = TextEditingController(text: decimal(fraction));
  final String portId;
  String terminalId;
  _TerminalDraft terminal;
  final TextEditingController? pointName;
  final TextEditingController fraction;
  TextEditingController get name => pointName ?? terminal.name;
  TextEditingController get signal => terminal.signal;
  PortSide side;
  void dispose() {
    pointName?.dispose();
    fraction.dispose();
  }
}

class _PortsDialog extends StatefulWidget {
  const _PortsDialog(this.app, this.device, this.sheetId, this.generation);
  final EditorController app;
  final Device device;
  final String sheetId;
  final int generation;
  @override
  State<_PortsDialog> createState() => _PortsDialogState();
}

class _PortsDialogState extends State<_PortsDialog> {
  late final component = widget.app.componentFor(widget.device);
  late final electrical = component.electrical!;
  late final function = electrical.functionById(widget.device.functionId)!;
  late final functionName = TextEditingController(text: function.name);
  late final nodeSignal = TextEditingController(
    text: electrical.terminals.firstOrNull?.signal ?? '',
  );
  late final width = TextEditingController(
    text: decimal(geometryFor(widget.device).width),
  );
  late final height = TextEditingController(
    text: decimal(geometryFor(widget.device).height),
  );
  late final rows = [
    for (final p in geometryFor(widget.device).ports) _draft(p.id),
  ];
  final removed = <_PortDraft>[];
  final terminalDrafts = <String, _TerminalDraft>{};
  String? error;
  _TerminalDraft _terminalDraft(String id) =>
      terminalDrafts.putIfAbsent(id, () {
        final terminal = electrical.terminalById(id);
        return _TerminalDraft(
          terminal?.designation ?? '',
          terminal?.signal ?? '',
        );
      });
  _PortDraft _draft(String portId) {
    final id = terminalIdFor(widget.device, portId)!;
    final blockPort =
        widget.device.symbol is PortBlockSpec
            ? (widget.device.symbol as PortBlockSpec).ports.firstWhere(
              (p) => p.id == portId,
            )
            : null;
    return _PortDraft(
      portId,
      id,
      _terminalDraft(id),
      blockPort?.side ?? PortSide.left,
      blockPort?.fraction ?? .5,
      pointName:
          widget.device.symbol is TerminalSymbolSpec
              ? component.terminal!.connectionPoints[portId]!
              : null,
    );
  }

  @override
  void dispose() {
    for (final row in [...rows, ...removed]) {
      row.dispose();
    }
    for (final draft in terminalDrafts.values) {
      draft.dispose();
    }
    functionName.dispose();
    nodeSignal.dispose();
    width.dispose();
    height.dispose();
    super.dispose();
  }

  void save() {
    try {
      if (!widget.app.isDocumentCurrent(widget.generation)) {
        throw const FormatException('Původní projekt již není otevřen.');
      }
      final current = widget.app.project.componentById(component.id);
      final currentDevice = widget.app.project
          .sheetById(widget.sheetId)
          ?.deviceById(widget.device.id);
      if (current == null ||
          currentDevice == null ||
          current.electrical != electrical ||
          currentDevice != widget.device) {
        throw const FormatException(
          'Funkce nebo zobrazení se změnily. Otevřete editor znovu.',
        );
      }
      final terminals = {for (final t in electrical.terminals) t.id: t};
      if (widget.device.symbol case TerminalSymbolSpec(:final terminalId)) {
        terminals[terminalId] = terminals[terminalId]!.copyWith(
          signal: nodeSignal.text.trim(),
        );
      } else {
        for (final id in rows.map((r) => r.terminalId).toSet()) {
          final draft = _terminalDraft(id);
          terminals[id] = ComponentTerminal(
            id: id,
            designation: draft.name.text.trim(),
            signal: draft.signal.text.trim(),
          );
        }
      }
      final pointNames = {...?current.terminal?.connectionPoints};
      final ports = <BlockPort>[];
      for (final row in rows) {
        if (widget.device.symbol is TerminalSymbolSpec) {
          pointNames[row.portId] = row.name.text.trim();
        }
        ports.add(
          BlockPort(
            id: row.portId,
            terminalId: row.terminalId,
            side: row.side,
            fraction: double.parse(row.fraction.text.replaceAll(',', '.')),
          ),
        );
      }
      final nextFunction = function.copyWith(
        name: functionName.text.trim(),
        terminalIds:
            {
              ...function.terminalIds,
              ...rows.map((r) => r.terminalId),
            }.toList(),
      );
      final updated = current.copyWith(
        terminal: current.terminal?.copyWith(connectionPoints: pointNames),
        electrical: ElectricalModel(
          terminals: terminals.values.toList(),
          functions: [
            for (final f in electrical.functions)
              f.id == function.id ? nextFunction : f,
          ],
        ),
      );
      final symbol =
          widget.device.symbol is PortBlockSpec
              ? PortBlockSpec(
                width: dimension(width.text)!,
                height: dimension(height.text)!,
                ports: ports,
              )
              : widget.device.symbol;
      final ok = widget.app.execute([
        UpdateComponent(updated),
        UpdateDevice(widget.sheetId, widget.device.copyWith(symbol: symbol)),
      ], 'Vývody a funkce upraveny');
      if (ok) {
        Navigator.pop(context);
      } else {
        setState(() => error = widget.app.status);
      }
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => editorDialog(
    context,
    title: 'Funkce a skutečné vývody',
    error: error,
    save: save,
    children: [
      formField('Název funkce', functionName),
      if (widget.device.symbol is TerminalSymbolSpec)
        formField('Signál uzlu', nodeSignal),
      if (widget.device.symbol is PortBlockSpec)
        Row(
          children: [
            Expanded(child: formField('Šířka bloku', width)),
            const SizedBox(width: 12),
            Expanded(child: formField('Výška bloku', height)),
          ],
        ),
      const Text(
        'Změna názvu zachovává identitu vývodu i připojený vodič. Připojený port lze odstranit až po odstranění vodiče.',
      ),
      for (final row in rows)
        Card(
          key: ValueKey(row.portId),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                if (widget.device.symbol is PortBlockSpec)
                  DropdownButtonFormField<String>(
                    itemHeight: null,
                    key: ValueKey('${row.portId}-${row.terminalId}'),
                    initialValue:
                        electrical.terminalById(row.terminalId) == null
                            ? ''
                            : row.terminalId,
                    decoration: const InputDecoration(
                      labelText: 'Identita vývodu',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Nový vývod'),
                      ),
                      for (final t in electrical.terminals)
                        DropdownMenuItem(
                          value: t.id,
                          child: Text(t.designation),
                        ),
                    ],
                    onChanged:
                        (id) => setState(() {
                          row.terminalId = id!.isEmpty ? newId('terminal') : id;
                          row.terminal = _terminalDraft(row.terminalId);
                        }),
                  ),
                Row(
                  children: [
                    Expanded(child: formField('Vývod', row.name)),
                    if (widget.device.symbol is! TerminalSymbolSpec) ...[
                      const SizedBox(width: 12),
                      Expanded(child: formField('Signál', row.signal)),
                    ],
                  ],
                ),
                if (widget.device.symbol is PortBlockSpec)
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<PortSide>(
                          itemHeight: null,
                          initialValue: row.side,
                          decoration: const InputDecoration(
                            labelText: 'Strana',
                          ),
                          items: [
                            for (final side in PortSide.values)
                              DropdownMenuItem(
                                value: side,
                                child: Text(sideLabel(side)),
                              ),
                          ],
                          onChanged: (v) => row.side = v!,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: formField('Podíl hrany (0–1)', row.fraction),
                      ),
                      IconButton(
                        tooltip: 'Odstranit port',
                        onPressed:
                            () => setState(() {
                              rows.remove(row);
                              removed.add(row);
                            }),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      if (widget.device.symbol is PortBlockSpec)
        OutlinedButton.icon(
          onPressed:
              () => setState(() {
                final terminalId = newId('terminal');
                final draft = _PortDraft(
                  newId('port'),
                  terminalId,
                  _terminalDraft(terminalId),
                  PortSide.left,
                  .5,
                );
                rows.add(draft);
                final left =
                    rows.where((r) => r.side == PortSide.left).toList();
                for (final (i, r) in left.indexed) {
                  r.fraction.text = decimal((i + 1) / (left.length + 1));
                }
                final minHeight = (left.length + 1) * 28;
                if ((double.tryParse(height.text.replaceAll(',', '.')) ?? 0) <
                    minHeight) {
                  height.text = '$minHeight';
                }
              }),
          icon: const Icon(Icons.add),
          label: const Text('Přidat vývod / port'),
        ),
    ],
  );
}

String sideLabel(PortSide side) => switch (side) {
  PortSide.left => 'Vlevo',
  PortSide.right => 'Vpravo',
  PortSide.top => 'Nahoře',
  PortSide.bottom => 'Dole',
};

Future<void> showMountPlacementDialog(
  BuildContext context,
  EditorController app, {
  Component? component,
}) async {
  final generation = app.documentGeneration;
  final sheetId = app.activeSheetId;
  final layoutId = app.activeLayout?.id;
  String? id = component?.id;
  final x = TextEditingController(text: '50'),
      y = TextEditingController(text: '50');
  String? error;
  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, refresh) => editorDialog(
                ctx,
                title: 'Umístit existující komponentu',
                error: error,
                children: [
                  const Text(
                    'Souřadnice středu v mm. Vyžaduje doloženou šířku a výšku. Komponenta má jednu fyzickou polohu sdílenou všemi pohledy.',
                  ),
                  DropdownButtonFormField<String>(
                    itemHeight: null,
                    initialValue: id,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Komponenta'),
                    items: [
                      for (final c in app.project.components.where(
                        (c) =>
                            c.kind == ComponentKind.physical &&
                            c.usage == ComponentUsage.installed,
                      ))
                        DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            '${app.resolver.fullDesignation(c)} · ${c.description}',
                          ),
                        ),
                    ],
                    onChanged: (v) => id = v,
                  ),
                  formField('Střed X mm', x),
                  formField('Střed Y mm', y),
                ],
                saveLabel: 'Umístit',
                save: () {
                  try {
                    if (!app.isDocumentCurrent(generation) ||
                        app.activeSheetId != sheetId ||
                        app.activeLayout?.id != layoutId) {
                      throw const FormatException(
                        'Původní montážní pohled již není otevřen.',
                      );
                    }
                    if (app.activeLayout == null) {
                      throw const FormatException(
                        'Nejprve nastavte montážní pohled na listu Výstavba.',
                      );
                    }
                    if (id == null) {
                      throw const FormatException('Vyberte komponentu.');
                    }
                    final px = double.parse(x.text.replaceAll(',', '.')),
                        py = double.parse(y.text.replaceAll(',', '.'));
                    if (app.placeComponent(id!, Vec2(px, py))) {
                      Navigator.pop(ctx);
                    } else {
                      refresh(() => error = app.status);
                    }
                  } catch (e) {
                    refresh(() => error = '$e');
                  }
                },
              ),
        ),
  );
  Future<void>.delayed(const Duration(milliseconds: 400), () {
    x.dispose();
    y.dispose();
  });
}
