import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app/controller.dart';
import '../app/theme.dart';
import 'components.dart';

class AssistantPanel extends StatefulWidget {
  const AssistantPanel({
    super.key,
    required this.controller,
    required this.onSettings,
    required this.inputFocus,
  });
  final EditorController controller;
  final VoidCallback onSettings;
  final FocusNode inputFocus;
  @override
  State<AssistantPanel> createState() => _AssistantPanelState();
}

class _AssistantPanelState extends State<AssistantPanel> {
  final input = TextEditingController();
  final scroll = ScrollController();
  int messageCount = 0;
  @override
  void dispose() {
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  void send() {
    final text = input.text.trim();
    if (text.isEmpty || widget.controller.busy) return;
    input.clear();
    widget.controller.sendPrompt(text);
  }

  @override
  Widget build(BuildContext context) {
    final c = EcadColors.of(context);
    final app = widget.controller;
    if (messageCount != app.conversation.length) {
      messageCount = app.conversation.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          scroll.jumpTo(scroll.position.maxScrollExtent);
        }
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
          child: Row(
            children: [
              Icon(
                app.useOllama ? Icons.hub_outlined : Icons.terminal_outlined,
                size: 14,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  app.assistantLabel,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              EcadIconButton(
                icon: Icons.tune,
                label: 'Nastavení AI připojení',
                onPressed: widget.onSettings,
                size: 26,
                iconSize: 16,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            children: [
              if (app.conversation.isEmpty) ...[
                const SizedBox(height: 17),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      border: Border.all(color: c.border),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.auto_awesome_outlined, size: 22),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Od záměru\nk výkresu.',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                    height: 1.18,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  app.useOllama
                      ? 'Popište změnu. Nastavený model připraví návrh, který si prohlédnete přímo ve výkresu.'
                      : 'Začněte příkazem. Návrh změny můžete zkontrolovat, použít a kdykoli vrátit.',
                  style: TextStyle(fontSize: 12, color: c.muted, height: 1.65),
                ),
                const SizedBox(height: 22),
                _suggestion(
                  context,
                  'Přidej motorový vývod',
                  'Jistič, stykač a motor',
                  Icons.account_tree_outlined,
                ),
                _suggestion(
                  context,
                  'Vlož svorku',
                  'Přístroj do aktuálního listu',
                  Icons.add_box_outlined,
                ),
                _suggestion(
                  context,
                  'Zkontroluj projekt',
                  'Značení a elektrické vazby',
                  Icons.fact_check_outlined,
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: c.border),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    app.useOllama
                        ? 'Zadání a aktuální projekt se odešlou na vámi nastavený endpoint.'
                        : 'Místní režim rozumí vybraným příkazům. Pro volné zadání připojte vlastní model v nastavení.',
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.65,
                      color: c.muted,
                    ),
                  ),
                ),
              ],
              for (final entry in app.conversation)
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            entry.isUser
                                ? Icons.person_outline
                                : Icons.auto_awesome_outlined,
                            size: 13,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              entry.isUser
                                  ? 'VY'
                                  : (entry.detail ?? 'ASISTENT').toUpperCase(),
                              style: const TextStyle(
                                fontSize: 9,
                                letterSpacing: 0.8,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        entry.text,
                        style: const TextStyle(fontSize: 12, height: 1.65),
                      ),
                    ],
                  ),
                ),
              if (app.busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.hourglass_top, size: 16),
                      SizedBox(width: 9),
                      Expanded(child: Text('Připravuji návrh…')),
                    ],
                  ),
                ),
              if (app.proposal != null) _proposal(context),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: c.foreground),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  children: [
                    Focus(
                      onKeyEvent: (node, event) {
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.enter &&
                            !HardwareKeyboard.instance.isShiftPressed) {
                          send();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: input,
                        focusNode: widget.inputFocus,
                        minLines: 2,
                        maxLines: 5,
                        cursorOpacityAnimates: false,
                        style: const TextStyle(fontSize: 12, height: 1.6),
                        decoration: const InputDecoration(
                          hintText: 'Co chcete ve schématu změnit?',
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.all(12),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 6, 6),
                      child: Row(
                        children: [
                          Text(
                            'List ${app.sheet.number}',
                            style: TextStyle(fontSize: 10, color: c.muted),
                          ),
                          if (app.selectedIds.isNotEmpty)
                            Text(
                              ' · ${app.selectedIds.length} ve výběru',
                              style: TextStyle(fontSize: 10, color: c.muted),
                            ),
                          const Spacer(),
                          EcadIconButton(
                            icon: Icons.arrow_upward,
                            label: 'Odeslat příkaz',
                            onPressed: app.busy ? null : send,
                            selected: true,
                            size: 30,
                            iconSize: 18,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Enter odeslat  ·  Shift + Enter nový řádek',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 9, color: c.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _suggestion(
    BuildContext context,
    String title,
    String detail,
    IconData icon,
  ) {
    final c = EcadColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OutlinedButton(
        onPressed: () => widget.controller.sendPrompt(title),
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(12)),
        child: Row(
          children: [
            Icon(icon, size: 17),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(detail, style: TextStyle(fontSize: 9, color: c.muted)),
                ],
              ),
            ),
            const Icon(Icons.north_east, size: 13),
          ],
        ),
      ),
    );
  }

  Widget _proposal(BuildContext context) {
    final app = widget.controller;
    final pending = app.proposal!;
    final c = EcadColors.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: c.foreground),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.difference_outlined, size: 17),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  pending.label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '${pending.commands.length} změn · jeden krok v historii',
            style: const TextStyle(fontSize: 10),
          ),
          const SizedBox(height: 10),
          for (final command in pending.commands.take(8))
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                '• ${_commandLabel(command)}',
                style: const TextStyle(fontSize: 10, height: 1.5),
              ),
            ),
          if (pending.commands.length > 8)
            Text(
              'a ${pending.commands.length - 8} dalších…',
              style: const TextStyle(fontSize: 10),
            ),
          const SizedBox(height: 12),
          if (!app.proposalIsCurrent)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text(
                'Projekt se mezitím změnil. Zadejte požadavek znovu.',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
          if (app.proposalIsCurrent)
            OutlinedButton.icon(
              onPressed: app.toggleProposalPreview,
              icon: Icon(
                app.showingProposal
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 15,
              ),
              label: Text(
                app.showingProposal
                    ? 'Zobrazit původní schéma'
                    : 'Náhled ve výkresu',
              ),
            ),
          const SizedBox(height: 6),
          FilledButton.icon(
            onPressed: app.proposalIsCurrent ? app.applyProposal : null,
            icon: const Icon(Icons.check, size: 16),
            label: const Text('Použít změny'),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: app.discardProposal,
            child: const Text('Odložit návrh'),
          ),
        ],
      ),
    );
  }

  String _commandLabel(EcadCommand command) => switch (command) {
    AddDevice(:final device) =>
      'Vložit ${device.designation} · ${SymbolCatalog.definitionFor(device.kind).label}',
    UpdateDevice(:final device) => 'Upravit ${device.designation}',
    UpdateDevices() => 'Upravit přístroje',
    AddWire() => 'Propojit připojovací body',
    DeleteWire() => 'Odstranit vodič',
    AddSheet(:final sheet) => 'Přidat list ${sheet.name}',
    DeleteDevices() => 'Odstranit vybrané přístroje',
    MoveDevices() => 'Přesunout přístroje',
    AddGraphics() => 'Vložit grafiku',
    UpdateGraphic() => 'Upravit grafiku',
    UpdateGraphics() => 'Upravit grafiku',
    MoveGraphics() => 'Přesunout grafiku',
    DeleteGraphics() => 'Odstranit grafiku',
    RenameSheet(:final name) => 'Přejmenovat list na $name',
    SetSheetType(:final sheetType) => 'Změnit typ listu: ${sheetType.label}',
    RenameProject(:final name) => 'Přejmenovat projekt na $name',
  };
}
