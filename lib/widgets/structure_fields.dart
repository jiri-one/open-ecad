import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';

class StructureFieldsController extends ChangeNotifier {
  StructureFieldsController(StructureContext value) {
    for (final path in value.paths) {
      final controller = TextEditingController(text: path.join('\n'));
      controller.addListener(notifyListeners);
      fields.add(controller);
    }
  }
  final fields = <TextEditingController>[];
  StructureContext get value {
    List<String> path(int index) =>
        fields[index].text
            .split('\n')
            .map((v) => v.trim())
            .where((v) => v.isNotEmpty)
            .toList();
    return StructureContext(
      functionPath: path(0),
      locationPath: path(1),
      productPath: path(2),
    );
  }

  @override
  void dispose() {
    for (final field in fields) {
      field.dispose();
    }
    super.dispose();
  }
}

class StructureFields extends StatelessWidget {
  const StructureFields({super.key, required this.controller});
  final StructureFieldsController controller;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (index, label)
          in const [
            'Funkční označení (=)',
            'Umístění (+)',
            'Nadřazené produkty (-)',
          ].indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: controller.fields[index],
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(labelText: label),
          ),
        ),
      const Text(
        'Jedna úroveň na řádek. Lomítko a tečka jsou součástí kódu. Prázdné pole = nezařazeno.',
        style: TextStyle(fontSize: 13),
      ),
    ],
  );
}
