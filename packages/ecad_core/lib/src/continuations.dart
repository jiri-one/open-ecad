// SPDX-License-Identifier: GPL-3.0-or-later
import 'commands.dart';
import 'model.dart';

class ContinuationTarget {
  const ContinuationTarget({required this.sheet, required this.marker});

  final Sheet sheet;
  final ContinuationMarker marker;
}

class ContinuationIndex {
  ContinuationIndex(EcadProject project) {
    final links = {for (final link in project.continuationLinks) link.id};
    for (final sheet in project.pages) {
      for (final marker in sheet.continuations) {
        if (!links.contains(marker.linkId)) continue;
        final target = ContinuationTarget(sheet: sheet, marker: marker);
        _byOccurrence[(sheet.id, marker.id)] = target;
        (_byLink[marker.linkId] ??= []).add(target);
      }
    }
    _byLink.updateAll((_, targets) => List.unmodifiable(targets));
  }

  final _byOccurrence = <(String, String), ContinuationTarget>{};
  final _byLink = <String, List<ContinuationTarget>>{};

  ContinuationTarget? occurrence({
    required String sheetId,
    required String markerId,
  }) => _byOccurrence[(sheetId, markerId)];

  List<ContinuationTarget> occurrences(String linkId) =>
      _byLink[linkId] ?? const [];

  List<ContinuationTarget> targets({
    required String sheetId,
    required String markerId,
  }) {
    final source = occurrence(sheetId: sheetId, markerId: markerId);
    if (source == null) return const [];
    return List.unmodifiable([
      for (final target in occurrences(source.marker.linkId))
        if (!identical(target, source)) target,
    ]);
  }
}

List<EcadCommand> continuationEditCommands(
  EcadProject project, {
  required String sheetId,
  required ContinuationMarker marker,
  required bool isNewMarker,
  required String label,
  bool createLink = false,
  bool renameLink = false,
}) {
  for (final id in [sheetId, marker.id, marker.linkId]) {
    if (!_identifier.hasMatch(id)) {
      throw EcadException('Invalid identifier "$id".', code: 'invalid_id');
    }
  }
  final name = label.trim();
  if (name.isEmpty || label.length > 200 || label.contains('\u0000')) {
    throw const EcadException(
      'Continuation label must contain 1–200 characters and no NUL.',
      code: 'invalid_metadata',
    );
  }
  final position = marker.position;
  if (!position.x.isFinite ||
      !position.y.isFinite ||
      position.x.abs() > ProjectLimits.maxCoordinate ||
      position.y.abs() > ProjectLimits.maxCoordinate) {
    throw const EcadException(
      'Continuation position must be finite and within coordinate limits.',
      code: 'invalid_geometry',
    );
  }
  final sheet = project.sheetById(sheetId);
  if (sheet == null) {
    throw EcadException('Unknown sheet "$sheetId".', code: 'missing_reference');
  }
  if (sheet.type != SheetType.multiLine && sheet.type != SheetType.singleLine) {
    throw const EcadException(
      'Continuations require an electrical sheet.',
      code: 'incompatible_sheet_content',
    );
  }
  if (!isNewMarker && sheet.continuationById(marker.id) == null) {
    throw EcadException(
      'Continuation "${marker.id}" does not exist on sheet "$sheetId".',
      code: 'missing_reference',
    );
  }
  if (marker.id == marker.linkId) {
    throw const EcadException(
      'A continuation marker and its group require distinct identifiers.',
      code: 'duplicate_id',
    );
  }
  final link = project.continuationLinkById(marker.linkId);
  if (!createLink && link == null) {
    throw EcadException(
      'Unknown continuation group "${marker.linkId}".',
      code: 'missing_link',
    );
  }
  final newIds = {if (createLink) marker.linkId, if (isNewMarker) marker.id};
  if (newIds.isNotEmpty) {
    for (final id in _projectIds(project)) {
      if (newIds.contains(id)) {
        throw EcadException(
          'Identifier "$id" already exists.',
          code: 'duplicate_id',
        );
      }
    }
  }
  final labelKey = name.toLowerCase();
  if (!createLink &&
      !renameLink &&
      link!.label.trim().toLowerCase() != labelKey) {
    throw const EcadException(
      'Changing a shared continuation label requires explicit renaming.',
      code: 'rename_required',
    );
  }
  if (createLink || renameLink) {
    for (final other in project.continuationLinks) {
      if (other.id != marker.linkId &&
          other.label.trim().toLowerCase() == labelKey) {
        throw EcadException(
          'Continuation label "$name" already belongs to another group.',
          code: 'duplicate_link_label',
        );
      }
    }
  }
  return List.unmodifiable([
    if (createLink)
      AddContinuationLink(ContinuationLink(id: marker.linkId, label: name))
    else if (renameLink && link!.label != name)
      UpdateContinuationLink(link.copyWith(label: name)),
    if (isNewMarker)
      AddContinuationMarker(sheetId, marker)
    else
      UpdateContinuationMarker(sheetId, marker),
  ]);
}

final _identifier = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,127}$');

// Port IDs are local to their symbol; only document-wide identities collide.
Iterable<String> _projectIds(EcadProject project) sync* {
  yield project.id;
  yield* project.articles.map((item) => item.id);
  yield* project.terminalStrips.map((item) => item.id);
  yield* project.continuationLinks.map((item) => item.id);
  for (final component in project.components) {
    yield component.id;
    final electrical = component.electrical;
    if (electrical != null) {
      yield* electrical.terminals.map((item) => item.id);
      yield* electrical.functions.map((item) => item.id);
    }
  }
  for (final layout in project.mountingLayouts) {
    yield layout.id;
    yield* layout.placements.map((item) => item.id);
  }
  for (final sheet in project.pages) {
    yield sheet.id;
    yield* sheet.devices.map((item) => item.id);
    yield* sheet.corners.map((item) => item.id);
    yield* sheet.continuations.map((item) => item.id);
    yield* sheet.wires.map((item) => item.id);
    yield* sheet.graphics.map((item) => item.id);
  }
}
