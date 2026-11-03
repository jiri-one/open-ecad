import 'dart:convert';
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import '../app/controller.dart';
import 'inventory.dart';

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
  });
  final List<T> items;
  final StructureContext Function(T) contextFor;
  final Widget Function(T) leaf;
  final Comparator<T> compare;
  final void Function(StructureAspect, List<String>) onRename;
  final ValueChanged<StructureAspect>? onFirstChanged;
  final StructureAspect initialFirst;
  @override
  State<StructureTree<T>> createState() => _StructureTreeState<T>();
}

class _StructureTreeState<T> extends State<StructureTree<T>> {
  late StructureAspect first = widget.initialFirst;
  @override
  Widget build(BuildContext context) {
    final order = [first, ...StructureAspect.values.where((a) => a != first)];
    List<Widget> level(
      List<T> items,
      int aspectIndex,
      List<String> prefix,
      String ancestor,
    ) {
      if (aspectIndex == order.length) {
        return (items..sort(widget.compare)).map(widget.leaf).toList();
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
        ...level(unassigned, aspectIndex + 1, [], ancestor),
        for (final name in names)
          ExpansionTile(
            key: PageStorageKey(
              '$ancestor/${aspect.name}/${jsonEncode([...prefix, name])}',
            ),
            initiallyExpanded: true,
            dense: true,
            title: Text(
              '${['=', '+', '-'][aspect.index]}$name',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: IconButton(
              tooltip: 'Přejmenovat větev',
              icon: const Icon(Icons.edit_outlined, size: 14),
              onPressed: () => widget.onRename(aspect, [...prefix, name]),
            ),
            children: level(groups[name]!, aspectIndex, [
              ...prefix,
              name,
            ], '$ancestor/${aspect.name}/$name'),
          ),
      ];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: DropdownButton<StructureAspect>(
            isExpanded: true,
            value: first,
            items: const [
              DropdownMenuItem(
                value: StructureAspect.function,
                child: Text('Struktura: funkce'),
              ),
              DropdownMenuItem(
                value: StructureAspect.location,
                child: Text('Struktura: umístění'),
              ),
              DropdownMenuItem(
                value: StructureAspect.product,
                child: Text('Struktura: produkty'),
              ),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => first = v);
              widget.onFirstChanged?.call(v);
            },
          ),
        ),
        ...level([...widget.items], 0, [], ''),
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
