import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import '../app/controller.dart';
import 'inventory.dart';
import 'structure_fields.dart';
import 'terminal_symbol_dialog.dart';

Future<bool?> editTerminalDirections(
  BuildContext context,
  EditorController owner,
  Device device,
  String sheetId,
) async {
  final generation = owner.documentGeneration;
  final spec = device.symbol as TerminalSymbolSpec;
  final sides = await showTerminalSymbolDialog(
    context,
    initialSides: spec.sides,
    quarterTurns: device.rotation ~/ 90,
  );
  if (sides == null || !owner.isDocumentCurrent(generation)) return null;
  final sheet = owner.project.sheetById(sheetId);
  if (sheet?.deviceById(device.id) != device) return false;
  final removed = spec.sides.difference(sides).map((s) => s.name).toSet();
  if (owner.resolver
      .wires(sheet!)
      .any(
        (w) => [w.from, w.to].any(
          (p) =>
              p is TerminalRef &&
              p.deviceId == device.id &&
              removed.contains(p.portId),
        ),
      )) {
    owner.status =
        'Připojený směr nelze odstranit. Nejprve odpojte jeho vodič.';
    return false;
  }
  return owner.updateDevice(
    device.copyWith(symbol: spec.copyWith(sides: sides)),
    sheetId: sheetId,
  );
}

Future<String?> editTerminalStrip(
  BuildContext context,
  EditorController owner, {
  TerminalStrip? strip,
}) async {
  final generation = owner.documentGeneration;
  final id = strip?.id ?? newId('strip');
  final structure = StructureFieldsController(
    strip?.reference.context ?? owner.sheet.structure,
  );
  final local = TextEditingController(
    text:
        strip?.reference.localDesignation ??
        nextLocalDesignation(owner.project, owner.sheet.structure, 'X'),
  );
  String? error;
  final result = await showDialog<String>(
    context: context,
    builder:
        (context) => StatefulBuilder(
          builder:
              (context, refresh) => editorDialog(
                context,
                title: 'Svorkovnice',
                error: error,
                children: [
                  StructureFields(controller: structure),
                  formField('Produktové označení (-)', local),
                  ListenableBuilder(
                    listenable: Listenable.merge([structure, local]),
                    builder:
                        (_, _) => Text(
                          ComponentReference(
                            context: structure.value,
                            localDesignation: local.text,
                          ).full,
                        ),
                  ),
                  const Text(
                    'Logická skupina svorek. Do kusovníku nepřidává další kus.',
                  ),
                ],
                save: () {
                  if (!owner.isDocumentCurrent(generation)) {
                    refresh(() => error = 'Původní projekt již není otevřen.');
                    return;
                  }
                  final next = TerminalStrip(
                    id: id,
                    reference: ComponentReference(
                      context: structure.value,
                      localDesignation: local.text,
                    ),
                  );
                  if (owner.execute([
                    strip == null
                        ? AddTerminalStrip(next)
                        : UpdateTerminalStrip(next),
                  ], 'Svorkovnice uložena')) {
                    Navigator.pop(context, id);
                  } else {
                    refresh(() => error = owner.status);
                  }
                },
              ),
        ),
  );
  Future<void>.delayed(const Duration(milliseconds: 400), () {
    structure.dispose();
    local.dispose();
  });
  return result;
}
