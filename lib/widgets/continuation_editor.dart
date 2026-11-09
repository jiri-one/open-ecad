import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';

import '../app/continuation_context.dart';
import '../app/controller.dart';
import 'continuation_picker.dart';
import 'inventory.dart';
import 'occurrence_dialog.dart';

String continuationLocation(ContinuationTarget target) =>
    'X ${decimal(target.marker.position.x)} · Y ${decimal(target.marker.position.y)} · ${target.marker.id}';

class ContinuationTargetTile extends StatelessWidget {
  const ContinuationTargetTile({super.key, required this.target, this.onTap});
  final ContinuationTarget target;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey(('continuation-target', target.sheet.id, target.marker.id)),
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.subdirectory_arrow_right),
    title: Text('${fullPageDesignation(target.sheet)} · ${target.sheet.name}'),
    subtitle: Text(continuationLocation(target)),
    onTap: onTap,
  );
}

Future<void> editContinuation(
  BuildContext context,
  EditorController app, {
  ContinuationMarker? marker,
  Vec2? position,
  String? initialLinkId,
  ContinuationGlyph initialGlyph = ContinuationGlyph.arrow,
  String initialLabel = '',
  bool Function()? isActive,
  ValueChanged<ContinuationTarget>? onNavigate,
}) async {
  if (marker == null && position == null) {
    app.setContinuationTool(
      linkId: initialLinkId,
      glyph: initialGlyph,
      label: initialLabel,
    );
    return;
  }
  final owner = ContinuationContext(
    app,
    markerId: marker?.id,
    isActive: isActive,
  );
  final snapshot = app.project;
  final index = ContinuationIndex(snapshot);
  var linkId = marker?.linkId ?? initialLinkId;
  var side = marker?.direction ?? PortSide.left;
  var glyph = marker?.glyph ?? initialGlyph;
  var renameLink = false;
  final label = TextEditingController(
    text: snapshot.continuationLinkById(linkId ?? '')?.label ?? initialLabel,
  );
  final x = TextEditingController(
    text: decimal((marker?.position ?? position!).x),
  );
  final y = TextEditingController(
    text: decimal((marker?.position ?? position!).y),
  );
  String? error;
  final target = await showDialog<ContinuationTarget>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder: (ctx, refresh) {
            final peers =
                linkId == null
                    ? <ContinuationTarget>[]
                    : index
                        .occurrences(linkId!)
                        .where(
                          (t) =>
                              t.sheet.id != owner.sheetId ||
                              t.marker.id != marker?.id,
                        )
                        .toList();
            return editorDialog(
              ctx,
              title:
                  marker == null
                      ? 'Vložit pokračovací odkaz'
                      : 'Upravit pokračovací odkaz',
              error: error,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('continuation-link-picker'),
                  icon: const Icon(Icons.search),
                  label: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Síť pokračování: ${linkId == null ? 'Nová samostatná síť' : '${snapshot.continuationLinkById(linkId!)!.label} · $linkId'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  onPressed: () async {
                    final value = await showContinuationLinkPicker(
                      ctx,
                      project: snapshot,
                      currentLinkId: linkId,
                      isCurrent: () => owner.current,
                    );
                    if (!ctx.mounted) return;
                    if (!owner.current) {
                      refresh(
                        () =>
                            error =
                                'Původní projekt, list nebo odkaz se změnil. Otevřete editor znovu.',
                      );
                      return;
                    }
                    if (value == null || value == (linkId ?? '')) return;
                    refresh(() {
                      linkId = value.isEmpty ? null : value;
                      renameLink = false;
                      label.text =
                          snapshot.continuationLinkById(linkId ?? '')?.label ??
                          '';
                    });
                  },
                ),
                if (marker != null && linkId != marker.linkId)
                  const Text(
                    'Přepojení změní elektrickou síť tohoto markeru i vodičů, které jsou k němu připojené. Ostatní markery původní sítě zůstanou beze změny.',
                  ),
                if (linkId != null)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: renameLink,
                    title: const Text('Přejmenovat společnou síť'),
                    subtitle: Text(
                      'Změna názvu platí pro všech ${index.occurrences(linkId!).length} stávajících markerů této sítě.',
                    ),
                    onChanged:
                        (value) => refresh(() {
                          renameLink = value!;
                          if (!renameLink) {
                            label.text =
                                snapshot.continuationLinkById(linkId!)!.label;
                          }
                        }),
                  ),
                TextField(
                  controller: label,
                  enabled: linkId == null || renameLink,
                  decoration: const InputDecoration(labelText: 'Označení sítě'),
                ),
                const Text(
                  'Síť se vybírá výslovně. Pro novou síť zadejte vlastní označení; samotný text nevytváří propojení.',
                ),
                Row(
                  children: [
                    Expanded(child: formField('Poloha X', x)),
                    const SizedBox(width: 12),
                    Expanded(child: formField('Poloha Y', y)),
                  ],
                ),
                DropdownButtonFormField<PortSide>(
                  itemHeight: null,
                  initialValue: side,
                  decoration: const InputDecoration(labelText: 'Směr portu'),
                  items: [
                    for (final s in PortSide.values)
                      DropdownMenuItem(value: s, child: Text(sideLabel(s))),
                  ],
                  onChanged: (value) => side = value!,
                ),
                DropdownButtonFormField<ContinuationGlyph>(
                  itemHeight: null,
                  initialValue: glyph,
                  decoration: const InputDecoration(labelText: 'Značka'),
                  items: const [
                    DropdownMenuItem(
                      value: ContinuationGlyph.arrow,
                      child: Text('Šipka'),
                    ),
                    DropdownMenuItem(
                      value: ContinuationGlyph.earth,
                      child: Text('Ochranné pokračování PE'),
                    ),
                  ],
                  onChanged: (value) => glyph = value!,
                ),
                Text(
                  'Protějšky (${peers.length})',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (peers.isEmpty)
                  const Text(
                    'Síť zatím nemá protějšek. Na dalším místě vložte marker a vyberte tuto síť.',
                  ),
                for (final peer in peers.take(4))
                  ContinuationTargetTile(
                    target: peer,
                    onTap:
                        marker == null ||
                                onNavigate == null ||
                                linkId != marker.linkId
                            ? null
                            : () {
                              if (!owner.current) {
                                refresh(
                                  () =>
                                      error =
                                          'Původní projekt, list nebo odkaz se změnil. Otevřete editor znovu.',
                                );
                              } else {
                                Navigator.pop(ctx, peer);
                              }
                            },
                  ),
                if (peers.length > 4)
                  OutlinedButton.icon(
                    key: const ValueKey('continuation-editor-peers'),
                    icon: const Icon(Icons.search),
                    label: Text('Vyhledat mezi ${peers.length} protějšky…'),
                    onPressed:
                        marker == null ||
                                onNavigate == null ||
                                linkId != marker.linkId
                            ? null
                            : () async {
                              final peer = await showContinuationTargetPicker(
                                ctx,
                                targets: peers,
                                linkLabels: {
                                  for (final link in snapshot.continuationLinks)
                                    link.id: link.label,
                                },
                                isCurrent: () => owner.current,
                              );
                              if (!ctx.mounted) return;
                              if (!owner.current) {
                                refresh(
                                  () =>
                                      error =
                                          'Původní projekt, list nebo odkaz se změnil. Otevřete editor znovu.',
                                );
                                return;
                              }
                              if (peer != null) Navigator.pop(ctx, peer);
                            },
                  ),
                if (onNavigate != null && marker != null)
                  const Text(
                    'Kliknutí na protějšek přejde bez uložení rozepsaných změn. Souřadnice jsou v jednotkách výkresu.',
                  ),
              ],
              save: () {
                if (!owner.current) {
                  refresh(
                    () =>
                        error =
                            'Původní projekt, list nebo odkaz se změnil. Otevřete editor znovu.',
                  );
                  return;
                }
                try {
                  final point = Vec2(
                    double.parse(x.text.replaceAll(',', '.')),
                    double.parse(y.text.replaceAll(',', '.')),
                  );
                  if (!point.x.isFinite || !point.y.isFinite) {
                    throw const FormatException(
                      'Poloha musí být konečné číslo.',
                    );
                  }
                  final next = ContinuationMarker(
                    id: marker?.id ?? newId('marker'),
                    linkId: linkId ?? newId('link'),
                    position: point,
                    direction: side,
                    glyph: glyph,
                  );
                  final commands = continuationEditCommands(
                    app.project,
                    sheetId: owner.sheetId,
                    marker: next,
                    isNewMarker: marker == null,
                    label: label.text.trim(),
                    createLink: linkId == null,
                    renameLink: renameLink,
                  );
                  if (app.execute(
                    commands,
                    marker == null
                        ? 'Pokračování vloženo'
                        : 'Pokračování upraveno',
                    expectedRevision: owner.revision,
                  )) {
                    app.select({next.id});
                    app.cancelTool();
                    Navigator.pop(ctx);
                  } else {
                    refresh(() => error = app.status);
                  }
                } catch (e) {
                  refresh(() => error = '$e');
                }
              },
            );
          },
        ),
  );
  if (target != null && owner.current) onNavigate?.call(target);
  // Controllers stay alive through the route's closing animation.
  Future<void>.delayed(const Duration(milliseconds: 400), () {
    label.dispose();
    x.dispose();
    y.dispose();
  });
}
