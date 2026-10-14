// SPDX-License-Identifier: GPL-3.0-or-later
import 'commands.dart';
import 'model.dart';
import 'routing.dart';
import 'validation.dart';

class _HistoryEntry {
  const _HistoryEntry(this.project, this.label);
  final EcadProject project;
  final String label;
}

/// An all-or-nothing, UI-independent document editor.
///
/// Revisions count state changes, including undo/redo. This means a proposal
/// based on revision N cannot silently apply after undo restores similar data.
class ProjectEngine {
  ProjectEngine(EcadProject project, {this.historyLimit = 100})
    : _project = project {
    if (historyLimit < 1 || historyLimit > 1000) {
      throw const EcadException('History limit must be between 1 and 1000.');
    }
    requireValidProject(project);
  }

  EcadProject _project;
  final int historyLimit;
  final _undo = <_HistoryEntry>[];
  final _redo = <_HistoryEntry>[];

  EcadProject get project => _project;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  String? get undoLabel => canUndo ? _undo.last.label : null;
  String? get redoLabel => canRedo ? _redo.last.label : null;

  void execute(
    List<EcadCommand> commands, {
    String label = '',
    int? expectedRevision,
  }) {
    if (expectedRevision != null && expectedRevision != _project.revision) {
      throw EcadException(
        'This edit targets revision $expectedRevision; the project is at revision ${_project.revision}.',
        code: 'stale_revision',
      );
    }
    if (commands.isEmpty || commands.length > ProjectLimits.maxCommands) {
      throw const EcadException(
        'A transaction requires 1–1000 commands.',
        code: 'invalid_command',
      );
    }
    if (label.length > 200 || label.contains('\u0000')) {
      throw const EcadException(
        'Transaction label exceeds the format limits.',
        code: 'invalid_command',
      );
    }
    final revision = _nextRevision();
    var candidate = _project;
    for (final command in commands) {
      candidate = _apply(candidate, command);
    }
    candidate = candidate.copyWith(revision: revision);
    requireValidProject(candidate);
    // Nothing observable changes until every command and the final graph pass.
    _undo.add(_HistoryEntry(_project, label));
    if (_undo.length > historyLimit) _undo.removeAt(0);
    _redo.clear();
    _project = candidate;
  }

  bool undo() {
    if (!canUndo) return false;
    final revision = _nextRevision();
    final entry = _undo.removeLast();
    _redo.add(_HistoryEntry(_project, entry.label));
    _project = entry.project.copyWith(revision: revision);
    return true;
  }

  bool redo() {
    if (!canRedo) return false;
    final revision = _nextRevision();
    final entry = _redo.removeLast();
    _undo.add(_HistoryEntry(_project, entry.label));
    _project = entry.project.copyWith(revision: revision);
    return true;
  }

  int _nextRevision() {
    if (_project.revision >= ProjectLimits.maxRevision) {
      throw const EcadException(
        'Project revision limit reached.',
        code: 'limit_exceeded',
      );
    }
    return _project.revision + 1;
  }

  static EcadProject _apply(EcadProject project, EcadCommand command) {
    switch (command) {
      case RenameProject():
        return project.copyWith(name: command.name);
      case AddSheet():
        if (project.pages.length >= ProjectLimits.maxPages) {
          throw const EcadException(
            'Sheet limit reached.',
            code: 'limit_exceeded',
          );
        }
        return project.copyWith(pages: [...project.pages, command.sheet]);
      case AddDevice():
        return _editSheet(project, command.sheetId, (sheet) {
          if (sheet.deviceById(command.device.id) != null) {
            throw EcadException(
              'Device ${command.device.id} already exists.',
              code: 'duplicate_id',
            );
          }
          return sheet.copyWith(devices: [...sheet.devices, command.device]);
        });
      case MoveDevices():
        return _editSheet(project, command.sheetId, (sheet) {
          _requireDevices(sheet, command.positions.keys.toSet());
          return _withDevices(
            sheet,
            sheet.devices
                .map(
                  (device) =>
                      command.positions.containsKey(device.id)
                          ? device.copyWith(
                            position: command.positions[device.id],
                          )
                          : device,
                )
                .toList(),
          );
        });
      case UpdateDevice():
        return _editSheet(project, command.sheetId, (sheet) {
          _requireDevices(sheet, {command.device.id});
          return _withDevices(
            sheet,
            sheet.devices
                .map(
                  (device) =>
                      device.id == command.device.id ? command.device : device,
                )
                .toList(),
          );
        });
      case DeleteDevices():
        return _editSheet(project, command.sheetId, (sheet) {
          _requireDevices(sheet, command.ids);
          return sheet.copyWith(
            devices:
                sheet.devices
                    .where((device) => !command.ids.contains(device.id))
                    .toList(),
            wires:
                sheet.wires
                    .where(
                      (wire) =>
                          !command.ids.contains(wire.from.deviceId) &&
                          !command.ids.contains(wire.to.deviceId),
                    )
                    .toList(),
          );
        });
      case AddWire():
        return _editSheet(
          project,
          command.sheetId,
          (sheet) => sheet.copyWith(wires: [...sheet.wires, command.wire]),
        );
      case AddGraphics():
        return _editSheet(project, command.sheetId, (sheet) {
          if (command.graphics.isEmpty ||
              command.graphics.length > ProjectLimits.maxGraphics ||
              sheet.graphics.length + command.graphics.length >
                  ProjectLimits.maxGraphics) {
            throw const EcadException(
              'Add requires drawing elements within the project limit.',
              code: 'invalid_command',
            );
          }
          final ids = sheet.graphics.map((graphic) => graphic.id).toSet();
          for (final graphic in command.graphics) {
            if (!ids.add(graphic.id)) {
              throw EcadException(
                'Drawing element ${graphic.id} already exists.',
                code: 'duplicate_id',
              );
            }
          }
          return sheet.copyWith(
            graphics: [...sheet.graphics, ...command.graphics],
          );
        });
      case UpdateGraphic():
        return _editSheet(project, command.sheetId, (sheet) {
          _requireGraphics(sheet, {command.graphic.id});
          return sheet.copyWith(
            graphics:
                sheet.graphics
                    .map(
                      (graphic) =>
                          graphic.id == command.graphic.id
                              ? command.graphic
                              : graphic,
                    )
                    .toList(),
          );
        });
      case UpdateGraphics():
        return _editSheet(project, command.sheetId, (sheet) {
          final replacements = {
            for (final graphic in command.graphics) graphic.id: graphic,
          };
          if (replacements.length != command.graphics.length) {
            throw const EcadException(
              'Update requires distinct drawing element IDs.',
              code: 'invalid_command',
            );
          }
          _requireGraphics(sheet, replacements.keys.toSet());
          return sheet.copyWith(
            graphics:
                sheet.graphics
                    .map((graphic) => replacements[graphic.id] ?? graphic)
                    .toList(),
          );
        });
      case MoveGraphics():
        return _editSheet(project, command.sheetId, (sheet) {
          _requireGraphics(sheet, command.positions.keys.toSet());
          return sheet.copyWith(
            graphics:
                sheet.graphics
                    .map(
                      (graphic) =>
                          command.positions.containsKey(graphic.id)
                              ? graphic.copyWith(
                                position: command.positions[graphic.id],
                              )
                              : graphic,
                    )
                    .toList(),
          );
        });
      case DeleteGraphics():
        return _editSheet(project, command.sheetId, (sheet) {
          _requireGraphics(sheet, command.ids);
          return sheet.copyWith(
            graphics:
                sheet.graphics
                    .where((graphic) => !command.ids.contains(graphic.id))
                    .toList(),
          );
        });
      case DeleteWire():
        return _editSheet(project, command.sheetId, (sheet) {
          if (!sheet.wires.any((wire) => wire.id == command.wireId)) {
            throw EcadException(
              'Wire ${command.wireId} does not exist on this sheet.',
              code: 'missing_wire',
            );
          }
          return sheet.copyWith(
            wires:
                sheet.wires.where((wire) => wire.id != command.wireId).toList(),
          );
        });
      case RenameSheet():
        return _editSheet(
          project,
          command.sheetId,
          (sheet) => sheet.copyWith(name: command.name),
        );
      case SetSheetType():
        return _editSheet(
          project,
          command.sheetId,
          (sheet) => sheet.copyWith(type: command.sheetType),
        );
    }
  }

  static EcadProject _editSheet(
    EcadProject project,
    String sheetId,
    Sheet Function(Sheet) edit,
  ) {
    final index = project.pages.indexWhere((sheet) => sheet.id == sheetId);
    if (index < 0) {
      throw EcadException(
        'Sheet $sheetId does not exist.',
        code: 'missing_sheet',
      );
    }
    final pages = [...project.pages];
    pages[index] = edit(pages[index]);
    return project.copyWith(pages: pages);
  }

  /// Manual bends of attached wires follow the devices in the same revision,
  /// so the editor preview, undo and exports all see one geometry.
  static Sheet _withDevices(Sheet sheet, List<Device> devices) {
    final before = {for (final device in sheet.devices) device.id: device};
    final after = {for (final device in devices) device.id: device};
    final changed = {
      for (final device in devices)
        if (!identical(before[device.id], device)) device.id,
    };
    return sheet.copyWith(
      devices: devices,
      wires: [
        for (final wire in sheet.wires)
          changed.contains(wire.from.deviceId) ||
                  changed.contains(wire.to.deviceId)
              ? WireRouter.follow(wire, before, after)
              : wire,
      ],
    );
  }

  static void _requireDevices(Sheet sheet, Set<String> ids) {
    if (ids.isEmpty || ids.length > ProjectLimits.maxDevices) {
      throw const EcadException(
        'At least one device ID is required.',
        code: 'invalid_command',
      );
    }
    final available = sheet.devices.map((device) => device.id).toSet();
    final missing = ids.difference(available);
    if (missing.isNotEmpty) {
      throw EcadException(
        'Unknown devices: ${missing.take(6).join(', ')}.',
        code: 'missing_device',
      );
    }
  }

  static void _requireGraphics(Sheet sheet, Set<String> ids) {
    if (ids.isEmpty || ids.length > ProjectLimits.maxGraphics) {
      throw const EcadException(
        'A bounded nonempty set of drawing element IDs is required.',
        code: 'invalid_command',
      );
    }
    final available = sheet.graphics.map((graphic) => graphic.id).toSet();
    final missing = ids.difference(available);
    if (missing.isNotEmpty) {
      throw EcadException(
        'Unknown drawing elements: ${missing.take(6).join(', ')}.',
        code: 'missing_graphic',
      );
    }
  }
}
