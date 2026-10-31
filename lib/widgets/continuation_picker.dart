import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'occurrence_dialog.dart' show electricalSheet;

Future<ContinuationTarget?> showContinuationTargetPicker(
  BuildContext context, {
  required List<ContinuationTarget> targets,
  required bool Function() isCurrent,
  Map<String, String> linkLabels = const {},
}) {
  final pages = <String, _PageMetadata>{};
  final choices = <_Choice<ContinuationTarget>>[];
  for (final target in targets) {
    final page = pages.putIfAbsent(
      target.sheet.id,
      () => _PageMetadata(target.sheet),
    );
    final marker = target.marker;
    final label = linkLabels[marker.linkId] ?? marker.linkId;
    choices.add(
      _Choice(
        value: target,
        identity: (page.id, marker.id),
        key: ValueKey(('continuation-target', page.id, marker.id)),
        title: page.title,
        detail:
            '$label · X ${_coordinate(marker.position.x)} · Y ${_coordinate(marker.position.y)} · ${marker.id} · list ${page.id}',
        search: '${page.search} $label ${marker.linkId} ${marker.id}',
        page: page,
      ),
    );
  }
  return _showPicker(
    context,
    title: 'Vybrat protějšek',
    choices: choices,
    isCurrent: isCurrent,
  );
}

Future<String?> showContinuationSheetPicker(
  BuildContext context, {
  required EcadProject project,
  required bool Function() isCurrent,
}) => _showPicker(
  context,
  title: 'Vybrat cílový list',
  choices: [
    for (final sheet in project.pages)
      if (electricalSheet(sheet)) _sheetChoice(sheet),
  ],
  isCurrent: isCurrent,
);

Future<String?> showContinuationLinkPicker(
  BuildContext context, {
  required EcadProject project,
  String? currentLinkId,
  required bool Function() isCurrent,
}) {
  final links = {for (final link in project.continuationLinks) link.id: link};
  final seen = <String>{};
  final choices = <_Choice<String>>[];
  for (final sheet in project.pages) {
    if (sheet.continuations.isEmpty) continue;
    final page = _PageMetadata(sheet);
    final occurrences = <String, List<String>>{};
    for (final marker in sheet.continuations) {
      if (!links.containsKey(marker.linkId)) continue;
      (occurrences[marker.linkId] ??= []).add(marker.id);
    }
    for (final entry in occurrences.entries) {
      final link = links[entry.key]!;
      seen.add(link.id);
      choices.add(
        _Choice(
          value: link.id,
          identity: link.id,
          key: ValueKey<(String, String, String?)>((
            'continuation-picker-link',
            link.id,
            sheet.id,
          )),
          title: '${link.label} · ${link.id}',
          detail:
              '${page.title} · list ${page.id} · markerů: ${entry.value.length}',
          search:
              '${link.label} ${link.id} ${page.search} ${entry.value.join(' ')}',
          page: page,
        ),
      );
    }
  }
  for (final link in links.values) {
    if (seen.contains(link.id)) continue;
    choices.add(
      _Choice(
        value: link.id,
        identity: link.id,
        key: ValueKey<(String, String, String?)>((
          'continuation-picker-link',
          link.id,
          null,
        )),
        title: '${link.label} · ${link.id}',
        detail: 'Bez výskytu',
        search: '${link.label} ${link.id} Bez výskytu',
      ),
    );
  }
  final current = links[currentLinkId];
  return _showPicker(
    context,
    title: 'Vybrat síť pokračování',
    choices: choices,
    currentIdentity: currentLinkId,
    currentLabel:
        current == null
            ? 'Nová samostatná síť'
            : '${current.label} · ${current.id}',
    isCurrent: isCurrent,
    newChoice: '',
  );
}

_Choice<String> _sheetChoice(Sheet sheet) {
  final page = _PageMetadata(sheet);
  return _Choice(
    value: sheet.id,
    identity: sheet.id,
    key: ValueKey(('continuation-picker-sheet', sheet.id)),
    title: page.title,
    detail: 'List ${sheet.id}',
    search: page.search,
    page: page,
    groupBySheet: false,
  );
}

String _coordinate(double value) =>
    value.toStringAsFixed(1).replaceAll('.', ',');

String _fold(String value) {
  const accents = 'áčďéěíňóřšťúůýž';
  const plain = 'acdeeinorstuuyz';
  var result = value.toLowerCase();
  for (var i = 0; i < accents.length; i++) {
    result = result.replaceAll(accents[i], plain[i]);
  }
  return result;
}

class _PageMetadata {
  _PageMetadata(Sheet sheet)
    : id = sheet.id,
      structure = sheet.structure,
      title = '${fullPageDesignation(sheet)} · ${sheet.name}',
      search = _fold(
        '${fullPageDesignation(sheet)} ${sheet.number} ${sheet.name} ${sheet.id} '
        '${sheet.structure.paths.expand((path) => path).join(' ')}',
      );

  final String id, title, search;
  final StructureContext structure;
}

class _Choice<T> {
  _Choice({
    required this.value,
    required this.identity,
    required this.key,
    required this.title,
    required this.detail,
    required String search,
    this.page,
    this.groupBySheet = true,
  }) : search = _fold(search);

  final T value;
  final Object identity;
  final Key key;
  final String title, detail, search;
  final _PageMetadata? page;
  final bool groupBySheet;
}

Future<T?> _showPicker<T>(
  BuildContext context, {
  required String title,
  required List<_Choice<T>> choices,
  required bool Function() isCurrent,
  Object? currentIdentity,
  String? currentLabel,
  T? newChoice,
}) {
  choices.sort((a, b) {
    final title = naturalCompare(a.title, b.title);
    if (title != 0) return title;
    final detail = naturalCompare(a.detail, b.detail);
    return detail != 0 ? detail : a.key.toString().compareTo(b.key.toString());
  });
  return showDialog<T>(
    context: context,
    builder:
        (_) => _PickerDialog<T>(
          title: title,
          choices: choices,
          isCurrent: isCurrent,
          currentIdentity: currentIdentity,
          currentLabel: currentLabel,
          newChoice: newChoice,
        ),
  );
}

class _Branch<T> {
  _Branch(this.label, {this.parent, this.choice});
  final String label;
  final _Branch<T>? parent;
  final _Choice<T>? choice;
  final children = <Object, _Branch<T>>{};
  int count = 0;
}

class _Row<T> {
  const _Row(this.branch, this.depth);
  final _Branch<T> branch;
  final int depth;
}

class _PickerDialog<T> extends StatefulWidget {
  const _PickerDialog({
    required this.title,
    required this.choices,
    required this.isCurrent,
    this.currentIdentity,
    this.currentLabel,
    this.newChoice,
  });
  final String title;
  final List<_Choice<T>> choices;
  final bool Function() isCurrent;
  final Object? currentIdentity;
  final String? currentLabel;
  final T? newChoice;

  @override
  State<_PickerDialog<T>> createState() => _PickerDialogState<T>();
}

class _PickerDialogState<T> extends State<_PickerDialog<T>> {
  final _query = TextEditingController();
  final _searchFocus = FocusNode();
  final _listFocus = FocusNode();
  final _scroll = ScrollController();
  final _trees = <StructureAspect, _Branch<T>>{};
  final _expanded = <_Branch<T>>{};
  late final int _total;
  late List<_Choice<T>> _matches;
  List<_Row<T>> _rows = [];
  StructureAspect _first = StructureAspect.function;
  int _cursor = 0;
  late int _count;
  bool _searching = false;
  String? _error;
  static const _rowHeight = 68.0;

  @override
  void initState() {
    super.initState();
    _total = widget.choices.map((c) => c.identity).toSet().length;
    _count = _total;
    _matches = widget.choices;
    _rebuildRows(revealCurrent: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCursor());
  }

  @override
  void dispose() {
    _query.dispose();
    _searchFocus.dispose();
    _listFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  _Branch<T> _tree() => _trees.putIfAbsent(_first, () {
    final root = _Branch<T>('');
    final order = [_first, ...StructureAspect.values.where((a) => a != _first)];
    for (final choice in widget.choices) {
      var parent = root;
      void descend(Object key, String label) {
        parent = parent.children.putIfAbsent(
          key,
          () => _Branch(label, parent: parent),
        );
        parent.count++;
      }

      final page = choice.page;
      if (page == null) {
        descend('orphan', 'Bez výskytu');
      } else {
        if (page.structure.isEmpty) descend('empty', 'Bez struktury');
        for (final aspect in order) {
          for (final code in page.structure.paths[aspect.index]) {
            descend((aspect, code), '${['=', '+', '-'][aspect.index]}$code');
          }
        }
        if (choice.groupBySheet) {
          descend(('sheet', page.id), '${page.title} · list ${page.id}');
        }
      }
      parent.children[choice.key] = _Branch(
        choice.title,
        parent: parent,
        choice: choice,
      );
    }
    void sort(_Branch<T> branch) {
      final entries =
          branch.children.entries.toList()..sort((a, b) {
            final label = naturalCompare(a.value.label, b.value.label);
            return label != 0
                ? label
                : a.key.toString().compareTo(b.key.toString());
          });
      branch.children
        ..clear()
        ..addEntries(entries);
      for (final child in branch.children.values) {
        sort(child);
      }
    }

    sort(root);
    return root;
  });

  void _rebuildRows({bool revealCurrent = false}) {
    _rows = [];
    if (_searching) {
      _rows = [
        for (final choice in _matches)
          _Row(_Branch(choice.title, choice: choice), 0),
      ];
      return;
    }
    final root = _tree();
    if (revealCurrent && widget.currentIdentity != null) {
      bool reveal(_Branch<T> branch) {
        if (branch.choice?.identity == widget.currentIdentity) return true;
        for (final child in branch.children.values) {
          if (reveal(child)) {
            _expanded.add(branch);
            return true;
          }
        }
        return false;
      }

      reveal(root);
    }
    void append(_Branch<T> branch, int depth) {
      for (final child in branch.children.values) {
        _rows.add(_Row(child, depth));
        if (_expanded.contains(child)) append(child, depth + 1);
      }
    }

    append(root, 0);
    if (revealCurrent) {
      _cursor = math.max(
        0,
        _rows.indexWhere(
          (r) => r.branch.choice?.identity == widget.currentIdentity,
        ),
      );
    }
  }

  void _filter(String value) {
    final tokens =
        _fold(
          value,
        ).trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    setState(() {
      _searching = tokens.isNotEmpty;
      _matches =
          _searching
              ? widget.choices
                  .where((choice) => tokens.every(choice.search.contains))
                  .toList()
              : widget.choices;
      _count = _matches.map((c) => c.identity).toSet().length;
      _cursor = 0;
      _rebuildRows();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _revealCursor() {
    if (!mounted || !_scroll.hasClients || _rows.isEmpty) return;
    final top = _cursor * _rowHeight;
    final bottom = top + _rowHeight;
    final viewport = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top.clamp(0, _scroll.position.maxScrollExtent));
    } else if (bottom > _scroll.offset + viewport) {
      _scroll.jumpTo(
        (bottom - viewport).clamp(0, _scroll.position.maxScrollExtent),
      );
    }
  }

  void _move(int delta) {
    if (_rows.isEmpty) return;
    setState(() => _cursor = (_cursor + delta).clamp(0, _rows.length - 1));
    _revealCursor();
  }

  void _toggle(_Branch<T> branch) {
    setState(() {
      if (!_expanded.remove(branch)) _expanded.add(branch);
      _rebuildRows();
      _cursor = _rows.indexWhere((r) => identical(r.branch, branch));
    });
    _revealCursor();
  }

  void _branchKey(bool expand) {
    if (_rows.isEmpty || _searching) return;
    final branch = _rows[_cursor].branch;
    if (branch.choice == null && _expanded.contains(branch) != expand) {
      _toggle(branch);
    } else if (!expand && branch.parent != null) {
      final index = _rows.indexWhere((r) => identical(r.branch, branch.parent));
      if (index >= 0) {
        setState(() => _cursor = index);
        _revealCursor();
      }
    } else if (expand && _expanded.contains(branch)) {
      _move(1);
    }
  }

  void _accept(T value) {
    if (!widget.isCurrent()) {
      setState(
        () =>
            _error =
                'Původní projekt, list nebo odkaz se změnil. Zavřete výběr a otevřete jej znovu.',
      );
      return;
    }
    Navigator.of(context).pop(value);
  }

  void _activate() {
    if (_rows.isEmpty) return;
    final branch = _rows[_cursor].branch;
    final choice = branch.choice;
    if (choice != null) {
      _accept(choice.value);
    } else {
      _toggle(branch);
    }
  }

  Map<ShortcutActivator, VoidCallback> get _navigationKeys => {
    const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
    const SingleActivator(LogicalKeyboardKey.enter): _activate,
    const SingleActivator(LogicalKeyboardKey.numpadEnter): _activate,
  };

  @override
  Widget build(BuildContext context) {
    final active = _rows.isEmpty ? null : _rows[_cursor].branch;
    final selected = active?.choice;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape):
            () => Navigator.of(context).pop(),
      },
      child: Dialog(
        child: SizedBox(
          width: 860,
          height: 660,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (widget.currentLabel != null)
                  Text(
                    'Aktuální síť: ${widget.currentLabel}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 12),
                CallbackShortcuts(
                  bindings: _navigationKeys,
                  child: TextField(
                    key: const ValueKey('continuation-picker-search'),
                    autofocus: true,
                    focusNode: _searchFocus,
                    controller: _query,
                    onChanged: _filter,
                    onSubmitted: (_) => _activate(),
                    decoration: InputDecoration(
                      labelText: 'Hledat síť, list, strukturu nebo ID',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon:
                          _query.text.isEmpty
                              ? null
                              : IconButton(
                                tooltip: 'Vymazat hledání',
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _query.clear();
                                  _filter('');
                                  _searchFocus.requestFocus();
                                },
                              ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Výsledky: $_count / $_total${_matches.length == _count ? '' : ' · míst: ${_matches.length}'}',
                        key: const ValueKey('continuation-picker-count'),
                      ),
                    ),
                    DropdownButton<StructureAspect>(
                      key: const ValueKey('continuation-picker-aspect'),
                      value: _first,
                      items: const [
                        DropdownMenuItem(
                          value: StructureAspect.function,
                          child: Text('Nejprve = funkce'),
                        ),
                        DropdownMenuItem(
                          value: StructureAspect.location,
                          child: Text('Nejprve + umístění'),
                        ),
                        DropdownMenuItem(
                          value: StructureAspect.product,
                          child: Text('Nejprve - produkt'),
                        ),
                      ],
                      onChanged:
                          _searching
                              ? null
                              : (value) {
                                setState(() {
                                  _first = value!;
                                  _cursor = 0;
                                  _rebuildRows(revealCurrent: true);
                                });
                                WidgetsBinding.instance.addPostFrameCallback(
                                  (_) => _revealCursor(),
                                );
                              },
                    ),
                  ],
                ),
                Expanded(
                  child:
                      _rows.isEmpty
                          ? Center(
                            child: Text(
                              _searching
                                  ? 'Nic neodpovídá hledání. Zkraťte text nebo hledejte podle označení listu či ID.'
                                  : 'Žádné položky k výběru.',
                            ),
                          )
                          : CallbackShortcuts(
                            bindings: {
                              ..._navigationKeys,
                              const SingleActivator(
                                    LogicalKeyboardKey.arrowLeft,
                                  ):
                                  () => _branchKey(false),
                              const SingleActivator(
                                    LogicalKeyboardKey.arrowRight,
                                  ):
                                  () => _branchKey(true),
                            },
                            child: Focus(
                              focusNode: _listFocus,
                              child: Scrollbar(
                                controller: _scroll,
                                thumbVisibility: true,
                                child: ListView.builder(
                                  key: const ValueKey(
                                    'continuation-picker-list',
                                  ),
                                  controller: _scroll,
                                  itemExtent: _rowHeight,
                                  itemCount: _rows.length,
                                  itemBuilder:
                                      (context, index) =>
                                          _buildRow(context, index),
                                ),
                              ),
                            ),
                          ),
                ),
                const SizedBox(height: 8),
                Text(
                  selected == null
                      ? (active == null ? 'Výběr: —' : 'Větev: ${active.label}')
                      : 'Výběr: ${selected.title}\n${selected.detail}',
                  key: const ValueKey('continuation-picker-selection'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const Text(
                  '↑ ↓ výběr · Enter potvrdit / rozbalit · Esc zrušit',
                  style: TextStyle(fontSize: 12),
                ),
                if (_error != null)
                  Text(
                    _error!,
                    key: const ValueKey('continuation-picker-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (widget.newChoice != null)
                      TextButton.icon(
                        key: const ValueKey('continuation-picker-new'),
                        onPressed: () => _accept(widget.newChoice as T),
                        icon: const Icon(Icons.add),
                        label: const Text('Nová samostatná síť'),
                      ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Zrušit'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: active == null ? null : _activate,
                      child: Text(
                        selected != null
                            ? 'Vybrat'
                            : active != null && _expanded.contains(active)
                            ? 'Sbalit'
                            : 'Rozbalit',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, int index) {
    final row = _rows[index];
    final branch = row.branch;
    final choice = branch.choice;
    return Material(
      color:
          index == _cursor
              ? Theme.of(context).colorScheme.secondaryContainer
              : Colors.transparent,
      // One list focus keeps Tab usable even with thousands of results.
      child: ExcludeFocus(
        child: Tooltip(
          message:
              choice == null
                  ? branch.label
                  : '${choice.title}\n${choice.detail}',
          child: ListTile(
            key: choice == null ? ValueKey(branch) : choice.key,
            contentPadding: EdgeInsets.only(
              left: 8 + math.min(row.depth, 8) * 16,
              right: 8,
            ),
            leading: Icon(
              choice == null
                  ? (_expanded.contains(branch)
                      ? Icons.expand_more
                      : Icons.chevron_right)
                  : choice.identity == widget.currentIdentity
                  ? Icons.check_circle_outline
                  : Icons.subdirectory_arrow_right,
            ),
            title: Text(
              branch.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              choice?.detail ?? '${branch.count} položek',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            selected: index == _cursor,
            onTap: () {
              if (choice != null) {
                _accept(choice.value);
              } else {
                _listFocus.requestFocus();
                _toggle(branch);
              }
            },
          ),
        ),
      ),
    );
  }
}
