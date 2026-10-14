import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import '../editor/schematic_canvas.dart';
import '../services/ecad_services.dart';
import '../widgets/components.dart';
import '../widgets/sheet_types.dart';
import 'controller.dart';
import 'theme.dart';

Future<String?> editNameDialog(
  BuildContext context, {
  required String title,
  required String value,
}) async {
  final input = TextEditingController(text: value);
  final result = await showDialog<String>(
    context: context,
    builder:
        (context) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 360,
            child: TextField(
              controller: input,
              autofocus: true,
              cursorOpacityAnimates: false,
              decoration: const InputDecoration(labelText: 'Název'),
              onSubmitted: (value) {
                if (value.trim().isNotEmpty) {
                  Navigator.pop(context, value.trim());
                }
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: () {
                if (input.text.trim().isNotEmpty) {
                  Navigator.pop(context, input.text.trim());
                }
              },
              child: const Text('Uložit název'),
            ),
          ],
        ),
  );
  // Text fields may stay mounted until the dialog route transition completes.
  Future<void>.delayed(const Duration(milliseconds: 400), input.dispose);
  return result;
}

class NewSheetRequest {
  const NewSheetRequest(this.type, this.name, {this.formStarter = false});
  final SheetType type;
  final String name;
  final bool formStarter;
}

Future<NewSheetRequest?> showNewSheetDialog(
  BuildContext context, {
  SheetType initialType = SheetType.multiLine,
}) => showDialog<NewSheetRequest>(
  context: context,
  builder: (context) => _NewSheetDialog(initialType),
);

class _NewSheetDialog extends StatefulWidget {
  const _NewSheetDialog(this.initialType);
  final SheetType initialType;
  @override
  State<_NewSheetDialog> createState() => _NewSheetDialogState();
}

class _NewSheetDialogState extends State<_NewSheetDialog> {
  late SheetType type = widget.initialType;
  late final name = TextEditingController(text: defaultSheetName(type))
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: defaultSheetName(type).length,
    );
  bool formStarter = true;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void selectType(SheetType value) {
    setState(() {
      // A name the user typed is kept; only the suggested name follows type.
      if (name.text.trim().isEmpty || name.text == defaultSheetName(type)) {
        name.value = TextEditingValue(
          text: defaultSheetName(value),
          selection: TextSelection(
            baseOffset: 0,
            extentOffset: defaultSheetName(value).length,
          ),
        );
      }
      type = value;
    });
  }

  void submit() {
    if (name.text.trim().isEmpty) return;
    Navigator.pop(
      context,
      NewSheetRequest(
        type,
        name.text.trim(),
        formStarter: type == SheetType.form && formStarter,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Nový list'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'TYP LISTU',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            SheetTypeSelector(value: type, onChanged: selectType),
            const SizedBox(height: 14),
            TextField(
              controller: name,
              autofocus: true,
              cursorOpacityAnimates: false,
              decoration: const InputDecoration(labelText: 'Název listu'),
              onSubmitted: (_) => submit(),
            ),
            if (type == SheetType.form)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: formStarter,
                onChanged:
                    (value) => setState(() => formStarter = value ?? false),
                title: const Text(
                  'Vložit prázdnou tabulku',
                  style: TextStyle(fontSize: 12),
                ),
                subtitle: const Text(
                  'Obecné záhlaví a řádky k ručnímu vyplnění, bez údajů z projektu.',
                  style: TextStyle(fontSize: 10),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Zrušit'),
      ),
      FilledButton(onPressed: submit, child: const Text('Vytvořit list')),
    ],
  );
}

Future<bool> confirmReplaceProject(
  BuildContext context,
  EditorController controller,
) async {
  if (!controller.dirty) return true;
  return await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Otevřít jiný projekt?'),
              content: const SizedBox(
                width: 380,
                child: Text(
                  'Aktuální změny nejsou uložené do souboru. Otevřením jiného projektu nahradíte i jeho automatickou pracovní kopii.',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Zůstat v projektu'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Pokračovat'),
                ),
              ],
            ),
      ) ??
      false;
}

Future<void> showAiSettings(
  BuildContext context,
  EditorController controller,
) async {
  await showDialog<void>(
    context: context,
    builder: (context) => _AiSettingsDialog(controller),
  );
}

class _AiSettingsDialog extends StatefulWidget {
  const _AiSettingsDialog(this.controller);
  final EditorController controller;
  @override
  State<_AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<_AiSettingsDialog> {
  late final url = TextEditingController(
    text: widget.controller.aiSettings.baseUrl,
  );
  late final model = TextEditingController(
    text: widget.controller.aiSettings.model,
  );
  late bool enabled = widget.controller.useOllama;
  String? error;
  @override
  void dispose() {
    url.dispose();
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Připojení asistenta'),
    content: SizedBox(
      width: 450,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Bez modelu fungují místní příkazy. Pro volné zadání lze připojit vlastní server Ollama.',
              style: TextStyle(fontSize: 12, height: 1.7),
            ),
            const SizedBox(height: 18),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Používat model Ollama',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Připojení se použije až při odeslání zadání.',
                style: TextStyle(fontSize: 11),
              ),
              value: enabled,
              onChanged: (value) => setState(() => enabled = value),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: url,
              cursorOpacityAnimates: false,
              decoration: const InputDecoration(
                labelText: 'Adresa serveru',
                hintText: 'http://localhost:11434',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: model,
              cursorOpacityAnimates: false,
              decoration: const InputDecoration(
                labelText: 'Název nainstalovaného modelu',
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Model obdrží zadání, výběr a nejvýše 200 přístrojů z aktuálního listu. Návrhy se kontrolují stejnými pravidly jako ruční úpravy. Model se v této aplikaci automaticky nestahuje.',
              style: TextStyle(fontSize: 11, height: 1.65),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  error!,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Zrušit'),
      ),
      FilledButton(
        onPressed: () {
          final settings = AiProviderSettings(
            baseUrl: url.text.trim(),
            model: model.text.trim(),
          );
          try {
            settings.validate();
          } on FormatException catch (exception) {
            setState(() => error = exception.message);
            return;
          }
          widget.controller.configureAi(settings, enabled: enabled);
          Navigator.pop(context);
        },
        child: const Text('Použít nastavení'),
      ),
    ],
  );
}

class PaletteCommand {
  const PaletteCommand(this.title, this.icon, this.run, {this.shortcut = ''});
  final String title, shortcut;
  final IconData icon;
  final VoidCallback run;
}

Future<void> showCommandPalette(
  BuildContext context,
  EditorController app, {
  required VoidCallback openProject,
  required VoidCallback focusAssistant,
  required ValueChanged<SheetType> addSheet,
}) async {
  final commands = <PaletteCommand>[
    PaletteCommand(
      'Uložit projekt',
      Icons.save_outlined,
      app.saveProject,
      shortcut: 'Ctrl S',
    ),
    PaletteCommand(
      'Otevřít projekt',
      Icons.folder_open_outlined,
      openProject,
      shortcut: 'Ctrl O',
    ),
    PaletteCommand(
      'Zadat příkaz asistentovi',
      Icons.terminal_outlined,
      focusAssistant,
      shortcut: 'Ctrl L',
    ),
    PaletteCommand(
      'Vybrat přístroje',
      Icons.near_me_outlined,
      () => app.setMode(CanvasMode.select),
      shortcut: 'V',
    ),
    PaletteCommand(
      'Propojit přístroje vodičem',
      Icons.polyline_outlined,
      () => app.setMode(CanvasMode.wire),
      shortcut: 'W',
    ),
    PaletteCommand(
      'Přizpůsobit list oknu',
      Icons.fit_screen,
      app.viewport.fit,
      shortcut: 'F',
    ),
    PaletteCommand(
      'Vrátit poslední změnu',
      Icons.undo,
      app.undo,
      shortcut: 'Ctrl Z',
    ),
    PaletteCommand('Obnovit změnu', Icons.redo, app.redo, shortcut: 'Ctrl Y'),
    PaletteCommand(
      'Přidat nový list…',
      Icons.note_add_outlined,
      () => addSheet(app.sheet.type),
    ),
    for (final type in SheetType.values) ...[
      PaletteCommand(
        'Nový list · ${type.label}…',
        sheetTypeIcon(type),
        () => addSheet(type),
      ),
      PaletteCommand(
        'Typ aktuálního listu: ${type.label}',
        sheetTypeIcon(type),
        () => app.setSheetType(type),
      ),
    ],
    PaletteCommand(
      'Zkontrolovat projekt',
      Icons.fact_check_outlined,
      app.validate,
    ),
    PaletteCommand(
      'Exportovat PDF',
      Icons.picture_as_pdf_outlined,
      () => app.exportProject(pdf: true),
    ),
    PaletteCommand(
      'Exportovat SVG aktuálního listu',
      Icons.image_outlined,
      () => app.exportProject(pdf: false),
    ),
    for (final kind in DeviceKind.values)
      PaletteCommand(
        'Vložit ${SymbolCatalog.definitionFor(kind).label.toLowerCase()}',
        Icons.add_box_outlined,
        () => app.setMode(CanvasMode.place, kind: kind),
      ),
    for (final theme in EcadAppearance.values)
      PaletteCommand(
        'Motiv: ${theme.label}',
        Icons.contrast,
        () => app.setAppearance(theme),
      ),
  ];
  await showDialog<void>(
    context: context,
    builder: (context) => _CommandPalette(commands),
  );
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette(this.commands);
  final List<PaletteCommand> commands;
  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  String query = '';

  void run(PaletteCommand command) {
    Navigator.pop(context);
    command.run();
  }

  @override
  Widget build(BuildContext context) {
    final results =
        widget.commands
            .where((c) => foldForSearch(c.title).contains(foldForSearch(query)))
            .toList();
    final c = EcadColors.of(context);
    return Dialog(
      child: SizedBox(
        width: 550,
        height: 460,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: TextField(
                autofocus: true,
                cursorOpacityAnimates: false,
                onChanged: (value) => setState(() => query = value),
                onSubmitted: (_) {
                  if (results.isNotEmpty) run(results.first);
                },
                decoration: const InputDecoration(
                  hintText: 'Hledat příkaz…',
                  prefixIcon: Icon(Icons.search, size: 20),
                ),
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: results.length,
                itemBuilder: (context, index) {
                  final command = results[index];
                  return ListTile(
                    dense: true,
                    leading: Icon(command.icon, size: 18),
                    title: Text(
                      command.title,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing:
                        command.shortcut.isEmpty
                            ? null
                            : Keycap(command.shortcut),
                    onTap: () => run(command),
                  );
                },
              ),
            ),
            Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.border)),
              ),
              child: const Text(
                'Enter spustí první výsledek · Esc zavře nabídku',
                style: TextStyle(fontSize: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showHelpDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder:
      (context) => AlertDialog(
        title: const Text('Ovládání Open ECAD'),
        content: const SizedBox(
          width: 470,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Výkres', style: TextStyle(fontWeight: FontWeight.w600)),
                SizedBox(height: 10),
                Text(
                  'V — výběr\nW — vodič mezi připojovacími body\nH nebo mezerník + tažení — posun\nKolečko — zoom pod kurzorem\nF — celý list do okna\nR — otočit výběr\nDelete — odstranit výběr\nShift + kliknutí — rozšířit výběr',
                  style: TextStyle(fontSize: 12, height: 1.9),
                ),
                SizedBox(height: 20),
                Text(
                  'Projekt a příkazy',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 10),
                Text(
                  'Ctrl + S — uložit .oecad\nCtrl + O — otevřít .oecad\nCtrl + Z / Y — vrátit / obnovit\nCtrl + D — duplikovat výběr\nCtrl + K — vyhledat příkaz\nCtrl + L — psát asistentovi',
                  style: TextStyle(fontSize: 12, height: 1.9),
                ),
                SizedBox(height: 20),
                Text(
                  'Místní příkazy',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 10),
                Text(
                  '„Přidej motorový vývod“\n„Vlož jistič QF2“\n„Duplikuj výběr 3×“\n„Přejmenuj výběr na KM2“\n„Zkontroluj projekt“',
                  style: TextStyle(fontSize: 12, height: 1.9),
                ),
                SizedBox(height: 20),
                Text(
                  'Prototyp 0.1 · Otevřený formát projektu · GPL-3.0-or-later',
                  style: TextStyle(fontSize: 10),
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Rozumím'),
          ),
        ],
      ),
);
