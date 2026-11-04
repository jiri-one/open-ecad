import 'package:flutter/widgets.dart';

import 'controller.dart';

class NavigationPress {
  NavigationPress(this.owner, BuildContext context, {this.isActive})
    : _generation = owner.documentGeneration,
      _project = owner.project,
      _state = _stateFor(owner),
      _route = ModalRoute.of(context) {
    owner.addListener(_changed);
    FocusManager.instance.addListener(_changed);
  }

  final EditorController owner;
  final bool Function()? isActive;
  final int _generation;
  final Object _project, _state;
  final ModalRoute<dynamic>? _route;
  bool _valid = true;

  static Object _stateFor(EditorController owner) => (
    owner.documentSessionId,
    owner.activeSheetId,
    owner.mode,
    owner.showingProposal,
    owner.pastePreview,
    owner.ioBusy,
    FocusManager.instance.primaryFocus,
  );

  bool get current =>
      _valid &&
      owner.isDocumentCurrent(_generation) &&
      identical(owner.project, _project) &&
      _stateFor(owner) == _state &&
      _route?.isCurrent != false &&
      (isActive?.call() ?? true);

  void _changed() {
    if (!current) _valid = false;
  }

  void dispose() {
    _valid = false;
    owner.removeListener(_changed);
    FocusManager.instance.removeListener(_changed);
  }
}
