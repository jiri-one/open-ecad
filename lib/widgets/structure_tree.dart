import 'dart:convert';
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import '../app/controller.dart';
import '../app/typography.dart';
import 'inventory.dart';

const structureTreeIndent = 16.0;
const _aspectLabels = [
  'Označení funkce (=)',
  'Označení umístění (+)',
  'Označení produktu (-)',
];

class StructureTree<T> extends StatefulWidget {
  const StructureTree({
    super.key,
    required this.items,
    required this.contextFor,
    required this.leaf,
    required this.compare,
    required this.onRename,
    this.onFirstChanged,
    this.initialFirst = StructureAspect.function,
    this.sliver = false,
    this.controlsWidth,
    this.keyFor,
  });
  final List<T> items;
  final StructureContext Function(T) contextFor;
  final Widget Function(T) leaf;
  final Comparator<T> compare;
  final void Function(StructureAspect, List<String>) onRename;
  final ValueChanged<StructureAspect>? onFirstChanged;
  final StructureAspect initialFirst;
  final bool sliver;
  final double? controlsWidth;
  final Object Function(T)? keyFor;
  @override
  State<StructureTree<T>> createState() => _StructureTreeState<T>();
}

sealed class _TreeNode<T> {
  const _TreeNode(this.depth, this.key);
  final int depth;
  final Key key;
}

class _TreeLeaf<T> extends _TreeNode<T> {
  const _TreeLeaf(this.item, super.depth, super.key);
  final T item;
}

class _TreeBranch<T> extends _TreeNode<T> {
  const _TreeBranch(
    this.aspect,
    this.path,
    this.children,
    super.depth,
    super.key,
  );
  final StructureAspect aspect;
  final List<String> path;
  final List<_TreeNode<T>> children;
  String get label => '${['=', '+', '-'][aspect.index]}${path.last}';
}

class _StructureTreeState<T> extends State<StructureTree<T>> {
  late StructureAspect first = widget.initialFirst;
  List<_TreeNode<T>>? _nodes;
  final _collapsed = <Key>{};
  bool _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.sliver && !_restored) {
      final saved = PageStorage.maybeOf(context)?.readState(context);
      if (saved is Set<Key>) _collapsed.addAll(saved);
      _restored = true;
    }
  }

  @override
  void didUpdateWidget(covariant StructureTree<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialFirst != widget.initialFirst) {
      first = widget.initialFirst;
      _nodes = null;
    }
    if (!identical(oldWidget.items, widget.items) ||
        oldWidget.contextFor != widget.contextFor ||
        oldWidget.compare != widget.compare ||
        oldWidget.keyFor != widget.keyFor) {
      _nodes = null;
    }
  }

  List<_TreeNode<T>> _structure() {
    final order = [first, ...StructureAspect.values.where((a) => a != first)];
    List<_TreeNode<T>> level(
      List<T> items,
      int aspectIndex,
      List<String> prefix,
      int depth,
      List<Object> ancestry,
    ) {
      if (aspectIndex == order.length) {
        return (items..sort(widget.compare))
            .map(
              (item) => _TreeLeaf<T>(
                item,
                depth,
                ValueKey(('item', widget.keyFor?.call(item) ?? item)),
              ),
            )
            .toList();
      }
      final aspect = order[aspectIndex];
      final groups = <String, List<T>>{};
      final unassigned = <T>[];
      for (final item in items) {
        final path = widget.contextFor(item).paths[aspect.index];
        if (path.length <= prefix.length) {
          unassigned.add(item);
        } else {
          groups.putIfAbsent(path[prefix.length], () => []).add(item);
        }
      }
      final names =
          groups.keys.toList()..sort((a, b) {
            final c = naturalCompare(a, b);
            return c == 0 ? a.compareTo(b) : c;
          });
      return [
        ...level(unassigned, aspectIndex + 1, [], depth, ancestry),
        for (final name in names)
          _TreeBranch<T>(
            aspect,
            [...prefix, name],
            level(
              groups[name]!,
              aspectIndex,
              [...prefix, name],
              depth + 1,
              [
                ...ancestry,
                [aspect.name, name],
              ],
            ),
            depth,
            ValueKey((
              'branch',
              jsonEncode([
                ...ancestry,
                [aspect.name, name],
              ]),
            )),
          ),
      ];
    }

    return level([...widget.items], 0, [], 0, []);
  }

  Widget _controls() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Seskupit podle…', style: Theme.of(context).textTheme.bodySmall),
        DropdownButton<StructureAspect>(
          itemHeight: null,
          isExpanded: true,
          style: Theme.of(context).textTheme.bodyMedium,
          value: first,
          selectedItemBuilder:
              (context) => [
                for (final label in _aspectLabels)
                  Tooltip(
                    message: label,
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
          items: [
            for (final aspect in StructureAspect.values)
              DropdownMenuItem(
                value: aspect,
                child: Text(_aspectLabels[aspect.index]),
              ),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() {
              first = v;
              _nodes = null;
            });
            widget.onFirstChanged?.call(v);
          },
        ),
      ],
    ),
  );

  Widget _legacyNode(_TreeNode<T> node) => switch (node) {
    _TreeLeaf<T>() => widget.leaf(node.item),
    _TreeBranch<T>() => ExpansionTile(
      key: PageStorageKey(node.key),
      initiallyExpanded: true,
      dense: true,
      title: Text(node.label, style: const TextStyle(fontSize: 13)),
      trailing: IconButton(
        tooltip: 'Přejmenovat větev',
        icon: const Icon(Icons.edit_outlined, size: 14),
        onPressed: () => widget.onRename(node.aspect, node.path),
      ),
      children: node.children.map(_legacyNode).toList(),
    ),
  };

  void _toggle(_TreeBranch<T> branch) {
    setState(() {
      if (!_collapsed.remove(branch.key)) _collapsed.add(branch.key);
    });
    PageStorage.maybeOf(context)?.writeState(context, Set<Key>.of(_collapsed));
  }

  @override
  Widget build(BuildContext context) {
    final nodes = _nodes ??= _structure();
    if (!widget.sliver) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_controls(), ...nodes.map(_legacyNode)],
      );
    }
    final rows = <_TreeNode<T>>[];
    void flatten(List<_TreeNode<T>> nodes) {
      for (final node in nodes) {
        rows.add(node);
        if (node is _TreeBranch<T> && !_collapsed.contains(node.key)) {
          flatten(node.children);
        }
      }
    }

    flatten(nodes);
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].key: i};
    final rowHeight = interfaceRowHeight(context, minimum: 36, fontSize: 13);
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: SizedBox(width: widget.controlsWidth, child: _controls()),
          ),
        ),
        SliverFixedExtentList.builder(
          itemExtent: rowHeight,
          itemCount: rows.length,
          findChildIndexCallback: (key) => indices[key],
          itemBuilder: (context, index) {
            final node = rows[index];
            return Padding(
              key: node.key,
              padding: EdgeInsets.only(left: node.depth * structureTreeIndent),
              child: switch (node) {
                _TreeLeaf<T>() => widget.leaf(node.item),
                _TreeBranch<T>() => ListTile(
                  dense: true,
                  minTileHeight: rowHeight,
                  minVerticalPadding: 0,
                  minLeadingWidth: 20,
                  horizontalTitleGap: 8,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  leading: Icon(
                    _collapsed.contains(node.key)
                        ? Icons.chevron_right
                        : Icons.expand_more,
                    size: 18,
                  ),
                  title: Tooltip(
                    message:
                        '${['=', '+', '-'][node.aspect.index]}${node.path.join(' → ')}',
                    child: Text(
                      node.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium!.copyWith(fontSize: 13),
                    ),
                  ),
                  trailing: IconButton(
                    tooltip: 'Přejmenovat větev',
                    icon: const Icon(Icons.edit_outlined, size: 14),
                    onPressed: () => widget.onRename(node.aspect, node.path),
                  ),
                  onTap: () => _toggle(node),
                ),
              },
            );
          },
        ),
      ],
    );
  }
}

Future<void> renameStructureBranchDialog(
  BuildContext context,
  EditorController owner,
  StructureAspect aspect,
  List<String> prefix,
) async {
  final name = TextEditingController(text: prefix.last);
  String? error;
  await showDocumentEditorDialog(
    context,
    owner,
    (generation) => StatefulBuilder(
      builder:
          (context, refresh) => editorDialog(
            context,
            title: 'Přejmenovat větev',
            error: error,
            children: [
              Text('${['=', '+', '-'][aspect.index]}${prefix.join(' → ')}'),
              formField('Nový kód úrovně', name),
              const Text(
                'Změní všechny listy a komponenty s touto cestou. Identita a propojení zůstanou zachovány.',
              ),
            ],
            save: () {
              if (!owner.isDocumentCurrent(generation)) {
                refresh(() => error = 'Původní projekt již není otevřen.');
                return;
              }
              if (owner.renameStructureBranch(aspect, prefix, [
                ...prefix.take(prefix.length - 1),
                name.text.trim(),
              ])) {
                Navigator.pop(context);
              } else {
                refresh(() => error = owner.status);
              }
            },
          ),
    ),
  );
  Future<void>.delayed(const Duration(milliseconds: 400), name.dispose);
}
