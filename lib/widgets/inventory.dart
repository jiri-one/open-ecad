import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import '../app/controller.dart';
import 'sheet_types.dart';
import 'occurrence_dialog.dart';
import 'structure_fields.dart';
import 'structure_tree.dart';
import 'terminal_editor.dart';

String unitLabel(QuantityUnit unit) => unit == QuantityUnit.piece ? 'ks' : 'm';
String decimal(Object? value) => value?.toString().replaceAll('.', ',') ?? '';
String? optionalText(String value) =>
    value.trim().isEmpty ? null : value.trim();
double? dimension(String value) {
  if (value.trim().isEmpty) return null;
  final number = double.tryParse(value.replaceAll(',', '.'));
  if (number == null || !number.isFinite || number <= 0) {
    throw const FormatException(
      'Rozměry musí být kladná čísla v mm, nebo prázdné.',
    );
  }
  return number;
}

class InventoryPanel extends StatefulWidget {
  const InventoryPanel({super.key, required this.app, this.articles = false});
  final EditorController app;
  final bool articles;
  @override
  State<InventoryPanel> createState() => _InventoryPanelState();
}

class _InventoryPanelState extends State<InventoryPanel> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final bom = app.bom;
    bool matches(String text) =>
        foldForSearch(text).contains(foldForSearch(query));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Hledat…',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (v) => setState(() => query = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: FilledButton.icon(
            onPressed:
                () =>
                    widget.articles
                        ? editArticle(context, app)
                        : editComponent(context, app),
            icon: const Icon(Icons.add, size: 16),
            label: Text(
              widget.articles ? 'Nový artikl' : 'Nový kus / materiál',
            ),
          ),
        ),
        Expanded(
          child: ListView(
            children:
                widget.articles
                    ? [
                      for (final article in app.project.articles.where(
                        (a) => matches(
                          '${a.name} ${a.manufacturer} ${a.partNumber}',
                        ),
                      ))
                        ListTile(
                          dense: true,
                          title: Text(article.name),
                          subtitle: Text(
                            '${article.manufacturer ?? 'Výrobce neuveden'} · ${article.partNumber ?? 'Kód neuveden'} · ${unitLabel(article.unit)}',
                          ),
                          onTap:
                              () => editArticle(context, app, article: article),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) {
                              if (v == 'copy') {
                                editArticle(
                                  context,
                                  app,
                                  article: article.copyWith(
                                    id: newId('article'),
                                    name: '${article.name} — kopie',
                                  ),
                                );
                              }
                              if (v == 'assign') {
                                assignArticle(context, app, article);
                              }
                              if (v == 'delete') {
                                if (app.project.components.any(
                                  (c) => c.articleId == article.id,
                                )) {
                                  app.reportStatus(
                                    'Artikl je přiřazený komponentě. Před odstraněním zrušte jeho přiřazení.',
                                  );
                                  return;
                                }
                                app.execute([
                                  DeleteArticle(article.id),
                                ], 'Artikl odstraněn');
                              }
                            },
                            itemBuilder:
                                (_) => const [
                                  PopupMenuItem(
                                    value: 'copy',
                                    child: Text('Kopírovat artikl'),
                                  ),
                                  PopupMenuItem(
                                    value: 'assign',
                                    child: Text('Přiřadit komponentě…'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Odstranit nepoužitý artikl'),
                                  ),
                                ],
                          ),
                        ),
                      if (app.project.articles.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Artikly jsou katalog výrobků. Přiřazují se fyzickým komponentám a materiálu.',
                          ),
                        ),
                    ]
                    : [
                      StructureTree<ComponentRow>(
                        items:
                            bom.components
                                .where(
                                  (r) => matches(
                                    '${app.resolver.fullDesignation(r.component)} ${r.component.description} ${r.article?.name ?? ''}',
                                  ),
                                )
                                .toList(),
                        contextFor: (r) => app.resolver.contextFor(r.component),
                        compare: (a, b) {
                          final left = app.resolver.fullDesignation(
                                a.component,
                              ),
                              right = app.resolver.fullDesignation(b.component);
                          final n = naturalCompare(left, right);
                          return n != 0
                              ? n
                              : left != right
                              ? left.compareTo(right)
                              : a.component.id.compareTo(b.component.id);
                        },
                        onRename:
                            (aspect, path) => renameStructureBranchDialog(
                              context,
                              app,
                              aspect,
                              path,
                            ),
                        leaf:
                            (row) => ExpansionTile(
                              key: PageStorageKey(
                                '${app.documentSessionId}-${row.component.id}',
                              ),
                              dense: true,
                              title: ListTile(
                                dense: true,
                                title: Text(
                                  app.resolver
                                          .fullDesignation(row.component)
                                          .isEmpty
                                      ? row.article?.name ??
                                          'Materiál bez označení'
                                      : app.resolver.fullDesignation(
                                        row.component,
                                      ),
                                ),
                                subtitle: Text(
                                  '${row.article?.name ?? '⚠ Chybí artikl'}\n${decimal(row.component.quantity.amount ?? 'neurčeno')} ${unitLabel(row.component.quantity.unit)} · ${row.component.usage == ComponentUsage.spare ? 'rezerva' : 'instalace'} · ${row.hasRepresentation ? '${row.occurrences.length} zobrazení' : 'bez zobrazení'}${row.article != null && (row.article!.manufacturer == null || row.article!.partNumber == null) ? '\n⚠ Neúplný artikl' : ''}',
                                ),
                                onTap:
                                    () => editComponent(
                                      context,
                                      app,
                                      component: row.component,
                                    ),
                                trailing: PopupMenuButton<String>(
                                  onSelected: (v) {
                                    if (v == 'show') {
                                      showOccurrenceDialog(
                                        context,
                                        app,
                                        component: row.component,
                                      );
                                    }
                                    if (v == 'mount') {
                                      showMountPlacementDialog(
                                        context,
                                        app,
                                        component: row.component,
                                      );
                                    }
                                    if (v == 'copy') {
                                      final copy = app
                                          .duplicateInventoryComponent(
                                            row.component,
                                          );
                                      if (copy == null) return;
                                      editComponent(
                                        context,
                                        app,
                                        component: copy,
                                      );
                                    }
                                    if (v == 'delete') {
                                      if (app.bom.components.any(
                                            (r) =>
                                                r.component.id ==
                                                    row.component.id &&
                                                r.hasRepresentation,
                                          ) ||
                                          app.project.components.any(
                                            (c) =>
                                                c
                                                    .procurement
                                                    .includedInComponentId ==
                                                row.component.id,
                                          )) {
                                        app.reportStatus(
                                          'Komponenta je stále používána ve výkresu, montáži nebo dodávce jiného kusu. Nejprve zrušte tyto vazby.',
                                        );
                                        return;
                                      }
                                      app.execute([
                                        DeleteComponent(row.component.id),
                                      ], 'Komponenta odstraněna');
                                    }
                                    if (v.startsWith('goto:')) {
                                      final id = v.substring(5);
                                      app.setSheet(id);
                                    }
                                  },
                                  itemBuilder:
                                      (_) => [
                                        if (row.component.kind ==
                                                ComponentKind.physical &&
                                            row.component.usage !=
                                                ComponentUsage.spare) ...[
                                          const PopupMenuItem(
                                            value: 'show',
                                            child: Text(
                                              'Další elektrické zobrazení…',
                                            ),
                                          ),
                                          const PopupMenuItem(
                                            value: 'mount',
                                            child: Text('Umístit v montáži…'),
                                          ),
                                        ],
                                        for (final id in {
                                          ...row.occurrences.map(
                                            (o) => o.sheetId,
                                          ),
                                          ...row.mountingSheetIds,
                                        })
                                          PopupMenuItem(
                                            value: 'goto:$id',
                                            child: Text(
                                              'Přejít na list ${fullPageDesignation(app.project.sheetById(id)!)}',
                                            ),
                                          ),
                                        const PopupMenuItem(
                                          value: 'copy',
                                          child: Text(
                                            'Nový skutečný kus podle tohoto…',
                                          ),
                                        ),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Text(
                                            'Odstranit nepoužitou komponentu',
                                          ),
                                        ),
                                      ],
                                ),
                              ),
                              children: [
                                for (final occurrence in row.occurrences)
                                  ListTile(
                                    dense: true,
                                    title: Text(
                                      fullPageDesignation(
                                        app.project.sheetById(
                                          occurrence.sheetId,
                                        )!,
                                      ),
                                    ),
                                    subtitle: Text(
                                      app.project
                                          .sheetById(occurrence.sheetId)!
                                          .name,
                                    ),
                                    onTap: () {
                                      app.setSheet(occurrence.sheetId);
                                      app.select({occurrence.deviceId});
                                      app.setPanel(SidePanel.properties);
                                    },
                                  ),
                              ],
                            ),
                      ),
                      if (app.project.components.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Založte skutečný přístroj nebo materiál. Elektrická značka ani montážní pohled nejsou další kus.',
                          ),
                        ),
                    ],
          ),
        ),
        if (app.status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              app.status,
              maxLines: 3,
              style: const TextStyle(fontSize: 10),
            ),
          ),
      ],
    );
  }
}

Future<void> editArticle(
  BuildContext context,
  EditorController app, {
  Article? article,
}) => showDocumentEditorDialog(
  context,
  app,
  (generation) => _ArticleDialog(
    app,
    article,
    generation,
    article != null && app.project.articleById(article.id) != null,
  ),
);

Future<void> showDocumentEditorDialog(
  BuildContext context,
  EditorController owner,
  Widget Function(int generation) builder,
) {
  final generation = owner.documentGeneration;
  return showDialog<void>(
    context: context,
    builder:
        (context) =>
            owner.isDocumentCurrent(generation)
                ? builder(generation)
                : AlertDialog(
                  content: const Text('Původní projekt již není otevřen.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Zavřít'),
                    ),
                  ],
                ),
  );
}

class _ArticleDialog extends StatefulWidget {
  const _ArticleDialog(
    this.app,
    this.article,
    this.generation,
    this.wasExisting,
  );
  final EditorController app;
  final Article? article;
  final int generation;
  final bool wasExisting;
  @override
  State<_ArticleDialog> createState() => _ArticleDialogState();
}

class _ArticleDialogState extends State<_ArticleDialog> {
  late final fields = {
    for (final e
        in <String, String>{
          'Název artiklu': widget.article?.name ?? '',
          'Výrobce': widget.article?.manufacturer ?? '',
          'Objednací kód': widget.article?.partNumber ?? '',
          'Specifikace': widget.article?.specification ?? '',
          'Šířka mm': decimal(widget.article?.dimensionsMm?.width),
          'Výška mm': decimal(widget.article?.dimensionsMm?.height),
          'Hloubka mm': decimal(widget.article?.dimensionsMm?.depth),
          'Poznámka': widget.article?.note ?? '',
          'Zdroj URL': widget.article?.sourceUrl ?? '',
        }.entries)
      e.key: TextEditingController(text: e.value),
  };
  late QuantityUnit unit = widget.article?.unit ?? QuantityUnit.piece;
  String? error;
  String value(String key) => fields[key]!.text.trim();
  @override
  void dispose() {
    for (final f in fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  void save() {
    try {
      if (value('Název artiklu').isEmpty) {
        throw const FormatException('Vyplňte název artiklu.');
      }
      if (!widget.app.isDocumentCurrent(widget.generation)) {
        throw const FormatException('Původní projekt již není otevřen.');
      }
      if (widget.wasExisting &&
          widget.app.project.articleById(widget.article!.id) == null) {
        throw const FormatException('Původní artikl již neexistuje.');
      }
      final article = Article(
        id: widget.article?.id ?? newId('article'),
        name: value('Název artiklu'),
        unit: unit,
        manufacturer: optionalText(value('Výrobce')),
        partNumber: optionalText(value('Objednací kód')),
        specification: value('Specifikace'),
        dimensionsMm: DimensionsMm(
          width: dimension(value('Šířka mm')),
          height: dimension(value('Výška mm')),
          depth: dimension(value('Hloubka mm')),
        ),
        note: value('Poznámka'),
        sourceUrl: optionalText(value('Zdroj URL')),
      );
      if (widget.app.saveArticle(article)) {
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
    title: 'Artikl',
    error: error,
    save: save,
    children: [
      for (final entry in fields.entries) formField(entry.key, entry.value),
      DropdownButtonFormField<QuantityUnit>(
        initialValue: unit,
        decoration: const InputDecoration(labelText: 'Jednotka'),
        items: [
          for (final u in QuantityUnit.values)
            DropdownMenuItem(value: u, child: Text(unitLabel(u))),
        ],
        onChanged: (v) => setState(() => unit = v!),
      ),
      const Text(
        'Prázdné rozměry zůstávají neznámé. Změna artiklu se projeví u všech přiřazených komponent.',
      ),
    ],
  );
}

Future<void> editComponent(
  BuildContext context,
  EditorController app, {
  Component? component,
}) {
  final initialContext =
      component == null ? app.sheet.structure : const StructureContext.empty();
  final wasExisting =
      component != null && app.project.componentById(component.id) != null;
  return showDocumentEditorDialog(
    context,
    app,
    (generation) => _ComponentDialog(
      app,
      component,
      generation,
      initialContext,
      wasExisting,
    ),
  );
}

class _ComponentDialog extends StatefulWidget {
  const _ComponentDialog(
    this.app,
    this.component,
    this.generation,
    this.initialContext,
    this.wasExisting,
  );
  final EditorController app;
  final Component? component;
  final int generation;
  final StructureContext initialContext;
  final bool wasExisting;
  @override
  State<_ComponentDialog> createState() => _ComponentDialogState();
}

class _ComponentDialogState extends State<_ComponentDialog> {
  late final structure = StructureFieldsController(
    widget.component?.reference?.context ?? widget.initialContext,
  );
  late bool structured =
      widget.component == null || widget.component?.reference != null;
  late String? stripId = widget.component?.terminal?.stripId;
  late final fields = {
    for (final e
        in <String, String>{
          'Označení':
              widget.component?.reference?.localDesignation ??
              widget.component?.terminal?.number ??
              widget.component?.designation ??
              '',
          'Popis': widget.component?.description ?? '',
          'Množství': decimal(
            widget.component?.quantity.amount ??
                (widget.component == null ? '1' : ''),
          ),
          'Umístění': widget.component?.location ?? '',
          'Poznámka': widget.component?.note ?? '',
          'Šířka mm (override)': decimal(
            widget.component?.mountingSizeOverrideMm?.width,
          ),
          'Výška mm (override)': decimal(
            widget.component?.mountingSizeOverrideMm?.height,
          ),
          'Hloubka mm (override)': decimal(
            widget.component?.mountingSizeOverrideMm?.depth,
          ),
        }.entries)
      e.key: TextEditingController(text: e.value),
  };
  late ComponentKind kind = widget.component?.kind ?? ComponentKind.physical;
  late QuantityUnit unit =
      widget.component?.quantity.unit ?? QuantityUnit.piece;
  late ComponentUsage usage =
      widget.component?.usage ?? ComponentUsage.installed;
  late ProcurementSource source =
      widget.component?.procurement.source ?? ProcurementSource.purchase;
  late String? included = widget.component?.procurement.includedInComponentId;
  late String? articleId = widget.component?.articleId;
  String? error;
  String value(String key) => fields[key]!.text.trim();
  @override
  void dispose() {
    structure.dispose();
    for (final f in fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  void save() {
    try {
      if (!widget.app.isDocumentCurrent(widget.generation)) {
        throw const FormatException('Původní projekt již není otevřen.');
      }
      final current =
          widget.component == null
              ? null
              : widget.app.project.componentById(widget.component!.id);
      if (widget.wasExisting && current == null) {
        throw const FormatException('Původní komponenta již neexistuje.');
      }
      if (kind == ComponentKind.physical && value('Označení').isEmpty) {
        throw const FormatException('Vyplňte označení fyzického přístroje.');
      }
      final component = Component(
        id: widget.component?.id ?? newId('component'),
        kind: kind,
        designation:
            structured || stripId != null
                ? widget.component?.legacyDesignation
                : optionalText(value('Označení')),
        reference:
            structured && stripId == null && value('Označení').isNotEmpty
                ? ComponentReference(
                  context: structure.value,
                  localDesignation: value('Označení'),
                )
                : null,
        terminal: (current?.terminal ?? widget.component?.terminal)?.copyWith(
          stripId: stripId,
          number: value('Označení'),
        ),
        description: value('Popis'),
        articleId: articleId,
        quantity:
            kind == ComponentKind.physical
                ? const Quantity.pieces(1)
                : Quantity.parse(
                  unit,
                  optionalText(value('Množství').replaceAll(',', '.')),
                ),
        usage: usage,
        procurement: Procurement(
          source: source,
          includedInComponentId:
              source == ProcurementSource.included ? included : null,
        ),
        location: kind == ComponentKind.physical ? value('Umístění') : '',
        note: value('Poznámka'),
        electrical: current?.electrical,
        mountingSizeOverrideMm:
            kind == ComponentKind.physical
                ? DimensionsMm(
                  width: dimension(value('Šířka mm (override)')),
                  height: dimension(value('Výška mm (override)')),
                  depth: dimension(value('Hloubka mm (override)')),
                )
                : null,
      );
      if (widget.app.saveComponent(component)) {
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
    title: 'Komponenta / materiál',
    error: error,
    save: save,
    children: [
      DropdownButtonFormField<ComponentKind>(
        initialValue: kind,
        decoration: const InputDecoration(labelText: 'Druh'),
        items: const [
          DropdownMenuItem(
            value: ComponentKind.physical,
            child: Text('Fyzický přístroj — 1 ks'),
          ),
          DropdownMenuItem(
            value: ComponentKind.material,
            child: Text('Materiál — množství / metráž'),
          ),
        ],
        onChanged:
            widget.component?.electrical != null
                ? null
                : (v) => setState(() {
                  kind = v!;
                  articleId = null;
                }),
      ),
      if (stripId != null) ...[
        DropdownButtonFormField<String>(
          key: ValueKey('strip-$stripId'),
          initialValue: stripId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Svorkovnice'),
          items: [
            for (final strip in widget.app.project.terminalStrips)
              DropdownMenuItem(
                value: strip.id,
                child: Text(strip.reference.full),
              ),
          ],
          onChanged: (v) => setState(() => stripId = v),
        ),
        TextButton(
          onPressed: () async {
            final id = await editTerminalStrip(context, widget.app);
            if (mounted && id != null) setState(() => stripId = id);
          },
          child: const Text('Nová svorkovnice…'),
        ),
        TextButton(
          onPressed: () async {
            await editTerminalStrip(
              context,
              widget.app,
              strip: widget.app.project.terminalStripById(stripId!),
            );
            if (mounted) setState(() {});
          },
          child: const Text('Upravit označení svorkovnice…'),
        ),
      ] else if (structured)
        StructureFields(controller: structure)
      else
        TextButton(
          onPressed: () => setState(() => structured = true),
          child: const Text('Převést na strukturované označení…'),
        ),
      formField(
        stripId == null ? 'Označení' : 'Číslo svorky',
        fields['Označení']!,
      ),
      ListenableBuilder(
        listenable: Listenable.merge([structure, fields['Označení']!]),
        builder:
            (_, _) => Text(
              stripId != null
                  ? '${widget.app.project.terminalStripById(stripId!)?.reference.full}:${value('Označení')}'
                  : structured
                  ? ComponentReference(
                    context: structure.value,
                    localDesignation: value('Označení'),
                  ).full
                  : value('Označení'),
              key: const ValueKey('full-designation-preview'),
            ),
      ),
      formField('Popis', fields['Popis']!),
      DropdownButtonFormField<String>(
        key: ValueKey('article-$articleId-$kind'),
        initialValue: articleId ?? '',
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Artikl'),
        items: [
          const DropdownMenuItem(value: '', child: Text('Nepřiřazený artikl')),
          for (final a in widget.app.project.articles.where(
            (a) =>
                kind == ComponentKind.material || a.unit == QuantityUnit.piece,
          ))
            DropdownMenuItem(
              value: a.id,
              child: Text(
                '${a.name} · ${a.partNumber ?? 'bez kódu'}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged:
            (v) => setState(() {
              articleId = optionalText(v!);
              if (articleId != null) {
                unit = widget.app.project.articleById(articleId!)!.unit;
              }
            }),
      ),
      if (kind == ComponentKind.material) ...[
        formField(
          'Množství',
          fields['Množství']!,
          hint: 'Prázdné = neurčeno, např. 2,75',
        ),
        DropdownButtonFormField<QuantityUnit>(
          key: ValueKey(unit),
          initialValue: unit,
          decoration: const InputDecoration(labelText: 'Jednotka'),
          items: [
            for (final u in QuantityUnit.values)
              DropdownMenuItem(value: u, child: Text(unitLabel(u))),
          ],
          onChanged:
              articleId != null ? null : (v) => setState(() => unit = v!),
        ),
      ],
      DropdownButtonFormField<ComponentUsage>(
        initialValue: usage,
        decoration: const InputDecoration(labelText: 'Použití'),
        items: const [
          DropdownMenuItem(
            value: ComponentUsage.installed,
            child: Text('Instalace'),
          ),
          DropdownMenuItem(value: ComponentUsage.spare, child: Text('Rezerva')),
        ],
        onChanged: (v) => setState(() => usage = v!),
      ),
      DropdownButtonFormField<ProcurementSource>(
        initialValue: source,
        decoration: const InputDecoration(labelText: 'Dostupnost'),
        items: const [
          DropdownMenuItem(
            value: ProcurementSource.purchase,
            child: Text('K nákupu'),
          ),
          DropdownMenuItem(
            value: ProcurementSource.available,
            child: Text('K dispozici'),
          ),
          DropdownMenuItem(
            value: ProcurementSource.included,
            child: Text('Součást jiného kusu'),
          ),
        ],
        onChanged: (v) => setState(() => source = v!),
      ),
      if (source == ProcurementSource.included)
        DropdownButtonFormField<String>(
          initialValue: included,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Zahrnuto v komponentě'),
          items: [
            for (final c in widget.app.project.components.where(
              (c) => c.id != widget.component?.id,
            ))
              DropdownMenuItem(
                value: c.id,
                child: Text(
                  widget.app.resolver.fullDesignation(c).isEmpty
                      ? c.description
                      : widget.app.resolver.fullDesignation(c),
                ),
              ),
          ],
          onChanged: (v) => included = v,
        ),
      if (kind == ComponentKind.physical)
        for (final name in [
          'Umístění',
          'Šířka mm (override)',
          'Výška mm (override)',
          'Hloubka mm (override)',
        ])
          formField(name, fields[name]!),
      formField('Poznámka', fields['Poznámka']!),
      const Text(
        'Označení a artikl jsou společné všem zobrazením. Prázdný override přebírá rozměr artiklu; jinak zůstává neznámý.',
      ),
    ],
  );
}

Widget formField(
  String label,
  TextEditingController controller, {
  String? hint,
}) => TextField(
  controller: controller,
  cursorOpacityAnimates: false,
  decoration: InputDecoration(labelText: label, hintText: hint),
);
Widget editorDialog(
  BuildContext context, {
  required String title,
  required List<Widget> children,
  String? error,
  required VoidCallback save,
  String saveLabel = 'Uložit',
}) => AlertDialog(
  title: Text(title),
  content: SizedBox(
    width: 540,
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final child in children)
            Padding(padding: const EdgeInsets.only(bottom: 14), child: child),
          if (error != null)
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
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
    FilledButton(onPressed: save, child: Text(saveLabel)),
  ],
);

Future<void> assignArticle(
  BuildContext context,
  EditorController app,
  Article article,
) async {
  final generation = app.documentGeneration;
  String? id;
  String? error;
  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, refresh) => editorDialog(
                ctx,
                title: 'Přiřadit ${article.name}',
                children: [
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Komponenta'),
                    items: [
                      for (final c in app.project.components.where(
                        (c) => c.quantity.unit == article.unit,
                      ))
                        DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            app.resolver.fullDesignation(c).isEmpty
                                ? c.description
                                : app.resolver.fullDesignation(c),
                          ),
                        ),
                    ],
                    onChanged: (v) => id = v,
                  ),
                ],
                error: error,
                save: () {
                  if (!app.isDocumentCurrent(generation)) {
                    refresh(() => error = 'Původní projekt již není otevřen.');
                    return;
                  }
                  final component = app.project.componentById(id ?? '');
                  if (component == null ||
                      app.project.articleById(article.id) == null) {
                    refresh(
                      () => error = 'Vyberte existující komponentu a artikl.',
                    );
                    return;
                  }
                  if (app.saveComponent(
                    component.copyWith(articleId: article.id),
                  )) {
                    Navigator.pop(ctx);
                  } else {
                    refresh(() => error = app.status);
                  }
                },
              ),
        ),
  );
}
