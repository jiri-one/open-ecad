// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart' show PortSide;
import 'package:ecad_core/terminal_symbol_geometry.dart';
import 'package:flutter/material.dart';

import '../editor/terminal_symbol_painter.dart';

Future<Set<PortSide>?> showTerminalSymbolDialog(
  BuildContext context, {
  Set<PortSide> initialSides = const {PortSide.top, PortSide.bottom},
  int quarterTurns = 0,
  double radius = TerminalSymbolGeometry.defaultRadius,
  double portDistance = TerminalSymbolGeometry.defaultPortDistance,
  String title = 'Svorková značka',
}) => showDialog<Set<PortSide>>(
  context: context,
  builder:
      (context) => TerminalSymbolDialog(
        initialSides: initialSides,
        quarterTurns: quarterTurns,
        radius: radius,
        portDistance: portDistance,
        title: title,
      ),
);

class TerminalSymbolDialog extends StatefulWidget {
  const TerminalSymbolDialog({
    super.key,
    this.initialSides = const {PortSide.top, PortSide.bottom},
    this.quarterTurns = 0,
    this.radius = TerminalSymbolGeometry.defaultRadius,
    this.portDistance = TerminalSymbolGeometry.defaultPortDistance,
    this.title = 'Svorková značka',
  });

  final Set<PortSide> initialSides;
  final int quarterTurns;
  final double radius;
  final double portDistance;
  final String title;

  @override
  State<TerminalSymbolDialog> createState() => _TerminalSymbolDialogState();
}

class _TerminalSymbolDialogState extends State<TerminalSymbolDialog> {
  late final Set<PortSide> _sides = {...widget.initialSides};

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final worldSides = TerminalSymbolGeometry.sideOrder.where(
      (side) => _sides.contains(
        TerminalSymbolGeometry.rotateSide(side, -widget.quarterTurns),
      ),
    );
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Vyberte jeden až čtyři směry vývodů.'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final worldSide in TerminalSymbolGeometry.sideOrder)
                    _directionChoice(worldSide),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 112,
                child: Center(
                  child:
                      _sides.isEmpty
                          ? const Text('Bez vývodů')
                          : TerminalSymbolPreview(
                            key: const ValueKey('terminal-symbol-preview'),
                            geometry: TerminalSymbolGeometry(
                              sides: _sides,
                              radius: widget.radius,
                              portDistance: widget.portDistance,
                              quarterTurns: widget.quarterTurns,
                            ),
                            size: const Size(100, 100),
                            semanticLabel:
                                'Náhled: ${worldSides.map(_sideLabel).join(', ')}',
                          ),
                ),
              ),
              if (_sides.isEmpty)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    'Vyberte alespoň jeden směr.',
                    style: TextStyle(color: colors.error),
                  ),
                )
              else
                const Text('Směry platí pro toto zobrazení svorky.'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed:
              _sides.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(
                    Set<PortSide>.unmodifiable(
                      TerminalSymbolGeometry.sideOrder.where(_sides.contains),
                    ),
                  ),
          child: const Text('Uložit'),
        ),
      ],
    );
  }

  Widget _directionChoice(PortSide worldSide) {
    final localSide = TerminalSymbolGeometry.rotateSide(
      worldSide,
      -widget.quarterTurns,
    );
    return FilterChip(
      key: ValueKey('terminal-symbol-side-${worldSide.name}'),
      label: Text(_sideLabel(worldSide)),
      avatar: ExcludeSemantics(
        child: TerminalSymbolPreview(
          geometry: TerminalSymbolGeometry(
            sides: {worldSide},
            radius: widget.radius,
            portDistance: widget.portDistance,
          ),
          size: const Size(24, 24),
          padding: 2,
        ),
      ),
      selected: _sides.contains(localSide),
      onSelected:
          (selected) => setState(() {
            if (selected) {
              _sides.add(localSide);
            } else {
              _sides.remove(localSide);
            }
          }),
    );
  }
}

String _sideLabel(PortSide side) => switch (side) {
  PortSide.top => 'Nahoru',
  PortSide.right => 'Doprava',
  PortSide.bottom => 'Dolů',
  PortSide.left => 'Doleva',
};
