import 'package:ecad_core/ecad_core.dart';

import 'controller.dart';

/// Pending dialogs must not write to a replaced document or a changed scene.
class ContinuationContext {
  ContinuationContext(this.owner, {this.markerId, this.isActive})
    : sessionId = owner.documentSessionId,
      generation = owner.documentGeneration,
      sheetId = owner.sheet.id,
      revision = owner.project.revision;

  final EditorController owner;
  final String sessionId, sheetId;
  final int generation, revision;
  final String? markerId;
  final bool Function()? isActive;

  bool get current =>
      owner.isDocumentCurrent(generation) &&
      owner.documentSessionId == sessionId &&
      owner.activeSheetId == sheetId &&
      owner.project.revision == revision &&
      owner.project.sheetById(sheetId) != null &&
      (isActive?.call() ?? true) &&
      (markerId == null || occurrence != null);

  ContinuationTarget? get occurrence =>
      markerId == null
          ? null
          : ContinuationIndex(
            owner.project,
          ).occurrence(sheetId: sheetId, markerId: markerId!);
}
