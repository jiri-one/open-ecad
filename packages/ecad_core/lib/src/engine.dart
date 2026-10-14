// SPDX-License-Identifier: GPL-3.0-or-later
import 'commands.dart';
import 'graphics.dart';
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
    final draft = _Draft(_project);
    for (final command in commands) {
      draft.apply(command);
    }
    final candidate = draft.build(revision);
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
}

/// The working copy of one transaction. Commands edit it in place, so a batch
/// of small edits copies each touched collection once rather than per command.
class _Draft {
  _Draft(this._project) : _name = _project.name, _pages = [..._project.pages] {
    for (final (index, sheet) in _pages.indexed) {
      _pageIndex.putIfAbsent(sheet.id, () => index);
    }
  }

  final EcadProject _project;
  String _name;
  final List<Sheet> _pages;

  // A repeated sheet ID addresses its first sheet until validation rejects it.
  final _pageIndex = <String, int>{};
  final _edited = <int, _SheetDraft>{};

  EcadProject build(int revision) => _project.copyWith(
    name: _name,
    revision: revision,
    pages: [
      for (final (index, sheet) in _pages.indexed)
        _edited[index]?.build() ?? sheet,
    ],
  );

  _SheetDraft _sheet(String id) {
    final index = _pageIndex[id];
    if (index == null) {
      throw EcadException('Sheet $id does not exist.', code: 'missing_sheet');
    }
    return _edited[index] ??= _SheetDraft(_pages[index]);
  }

  void apply(EcadCommand command) {
    switch (command) {
      case RenameProject():
        _name = command.name;
      case AddSheet():
        if (_pages.length >= ProjectLimits.maxPages) {
          throw const EcadException(
            'Sheet limit reached.',
            code: 'limit_exceeded',
          );
        }
        _pageIndex.putIfAbsent(command.sheet.id, () => _pages.length);
        _pages.add(command.sheet);
      case AddDevice():
        final devices = _sheet(command.sheetId).devices;
        if (devices.contains(command.device.id)) {
          throw EcadException(
            'Device ${command.device.id} already exists.',
            code: 'duplicate_id',
          );
        }
        devices.add(command.device);
      case MoveDevices():
        final sheet = _sheet(command.sheetId);
        final positions = command.positions;
        _requireDevices(sheet.devices, positions.keys);
        sheet.changeDevices(
          positions.keys,
          (device) => device.copyWith(position: positions[device.id]),
        );
      case UpdateDevice():
        final sheet = _sheet(command.sheetId);
        _requireDevices(sheet.devices, [command.device.id]);
        sheet.changeDevices([command.device.id], (_) => command.device);
      case UpdateDevices():
        final sheet = _sheet(command.sheetId);
        final replacements = {
          for (final device in command.devices) device.id: device,
        };
        if (replacements.length != command.devices.length) {
          throw const EcadException(
            'Update requires distinct device IDs.',
            code: 'invalid_command',
          );
        }
        _requireDevices(sheet.devices, replacements.keys);
        sheet.changeDevices(
          replacements.keys,
          (device) => replacements[device.id]!,
        );
      case DeleteDevices():
        final sheet = _sheet(command.sheetId);
        _requireDevices(sheet.devices, command.ids);
        sheet.deleteDevices(command.ids);
      case AddWire():
        _sheet(command.sheetId).addWire(command.wire);
      case DeleteWire():
        final wires = _sheet(command.sheetId).wires;
        if (!wires.contains(command.wireId)) {
          throw EcadException(
            'Wire ${command.wireId} does not exist on this sheet.',
            code: 'missing_wire',
          );
        }
        wires.removeAll([command.wireId]);
      case AddGraphics():
        final graphics = _sheet(command.sheetId).graphics;
        if (command.graphics.isEmpty ||
            command.graphics.length > ProjectLimits.maxGraphics ||
            graphics.length + command.graphics.length >
                ProjectLimits.maxGraphics) {
          throw const EcadException(
            'Add requires drawing elements within the project limit.',
            code: 'invalid_command',
          );
        }
        final added = <String>{};
        for (final graphic in command.graphics) {
          if (graphics.contains(graphic.id) || !added.add(graphic.id)) {
            throw EcadException(
              'Drawing element ${graphic.id} already exists.',
              code: 'duplicate_id',
            );
          }
        }
        command.graphics.forEach(graphics.add);
      case UpdateGraphic():
        final graphics = _sheet(command.sheetId).graphics;
        _requireGraphics(graphics, [command.graphic.id]);
        graphics.update([command.graphic.id], (_) => command.graphic);
      case UpdateGraphics():
        final graphics = _sheet(command.sheetId).graphics;
        final replacements = {
          for (final graphic in command.graphics) graphic.id: graphic,
        };
        if (replacements.length != command.graphics.length) {
          throw const EcadException(
            'Update requires distinct drawing element IDs.',
            code: 'invalid_command',
          );
        }
        _requireGraphics(graphics, replacements.keys);
        graphics.update(
          replacements.keys,
          (graphic) => replacements[graphic.id]!,
        );
      case MoveGraphics():
        final graphics = _sheet(command.sheetId).graphics;
        final positions = command.positions;
        _requireGraphics(graphics, positions.keys);
        graphics.update(
          positions.keys,
          (graphic) => graphic.copyWith(position: positions[graphic.id]),
        );
      case DeleteGraphics():
        final graphics = _sheet(command.sheetId).graphics;
        _requireGraphics(graphics, command.ids);
        graphics.removeAll(command.ids);
      case RenameSheet():
        _sheet(command.sheetId).name = command.name;
      case SetSheetType():
        _sheet(command.sheetId).type = command.sheetType;
    }
  }

  static void _requireDevices(_Items<Device> devices, Iterable<String> ids) {
    if (ids.isEmpty || ids.length > ProjectLimits.maxDevices) {
      throw const EcadException(
        'At least one device ID is required.',
        code: 'invalid_command',
      );
    }
    final missing = devices.missing(ids);
    if (missing.isNotEmpty) {
      throw EcadException(
        'Unknown devices: ${missing.join(', ')}.',
        code: 'missing_device',
      );
    }
  }

  static void _requireGraphics(
    _Items<DrawingElement> graphics,
    Iterable<String> ids,
  ) {
    if (ids.isEmpty || ids.length > ProjectLimits.maxGraphics) {
      throw const EcadException(
        'A bounded nonempty set of drawing element IDs is required.',
        code: 'invalid_command',
      );
    }
    final missing = graphics.missing(ids);
    if (missing.isNotEmpty) {
      throw EcadException(
        'Unknown drawing elements: ${missing.join(', ')}.',
        code: 'missing_graphic',
      );
    }
  }
}

/// A sheet whose collections are copied on first use and then edited in place.
class _SheetDraft {
  _SheetDraft(this._sheet);

  final Sheet _sheet;
  String? name;
  SheetType? type;
  _Items<Device>? _devices;
  _Items<Wire>? _wires;
  _Items<DrawingElement>? _graphics;
  Map<String, List<int>>? _wiresByDevice;

  _Items<Device> get devices =>
      _devices ??= _Items(_sheet.devices, (device) => device.id);
  _Items<Wire> get wires => _wires ??= _Items(_sheet.wires, (wire) => wire.id);
  _Items<DrawingElement> get graphics =>
      _graphics ??= _Items(_sheet.graphics, (graphic) => graphic.id);

  Sheet build() => _sheet.copyWith(
    name: name,
    type: type,
    devices: _devices?.toList(),
    wires: _wires?.toList(),
    graphics: _graphics?.toList(),
  );

  void addWire(Wire wire) {
    final position = wires.add(wire);
    if (_wiresByDevice case final index?) _attach(index, wire, position);
  }

  /// Manual bends of attached wires follow the devices in the same revision,
  /// so the editor preview, undo and exports all see one geometry.
  void changeDevices(Iterable<String> ids, Device Function(Device) change) {
    final devices = this.devices;
    // Repeated IDs are visited in list order, so the last copy is kept.
    final before = <String, Device>{};
    devices.update(ids, (device) {
      before[device.id] = device;
      return change(device);
    });
    final attached = <int>{};
    for (final MapEntry(key: id, value: device) in before.entries) {
      if (!identical(device, devices.last(id))) {
        attached.addAll(_attachedTo(id));
      }
    }
    // Following reads only the two ends of a wire.
    Map<String, Device> ends(Wire wire, Device? Function(String) lookup) => {
      for (final id in [wire.from.deviceId, wire.to.deviceId])
        if (lookup(id) case final device?) id: device,
    };
    for (final position in attached) {
      final wire = wires.at(position);
      if (wire == null) continue;
      wires.replace(
        position,
        WireRouter.follow(
          wire,
          ends(wire, (id) => before[id] ?? devices.last(id)),
          ends(wire, devices.last),
        ),
      );
    }
  }

  void deleteDevices(Iterable<String> ids) {
    devices.removeAll(ids);
    for (final id in ids) {
      _attachedTo(id).forEach(wires.removeAt);
    }
  }

  /// Positions of wires with an end on [deviceId]. Positions of wires removed
  /// later in the transaction stay listed and read as null.
  List<int> _attachedTo(String deviceId) {
    final index = _wiresByDevice ??= _indexWires();
    return index[deviceId] ?? const [];
  }

  Map<String, List<int>> _indexWires() {
    final index = <String, List<int>>{};
    wires.forEach((position, wire) => _attach(index, wire, position));
    return index;
  }

  static void _attach(Map<String, List<int>> index, Wire wire, int position) {
    index.putIfAbsent(wire.from.deviceId, () => []).add(position);
    if (wire.to.deviceId != wire.from.deviceId) {
      index.putIfAbsent(wire.to.deviceId, () => []).add(position);
    }
  }
}

/// A sheet collection edited in place. Removed items stay as null until the
/// transaction ends, so recorded positions remain valid.
class _Items<T extends Object> {
  _Items(List<T> items, this._idOf) : _items = List<T?>.of(items);

  final List<T?> _items;
  final String Function(T) _idOf;
  var _removed = 0;
  Map<String, int>? _lastPositions;

  // Validated sheets hold each ID once, but a batch may add a sheet or wire
  // that repeats one. Then every copy is found by a scan, as with a list.
  var _repeated = false;

  int get length => _items.length - _removed;

  T? at(int position) => _items[position];

  void forEach(void Function(int position, T item) action) {
    for (var position = 0; position < _items.length; position++) {
      if (_items[position] case final item?) action(position, item);
    }
  }

  bool contains(String id) => _positions.containsKey(id);

  /// The last copy, as a map built from the list would hold.
  T? last(String id) {
    final position = _positions[id];
    return position == null ? null : _items[position];
  }

  /// Up to six absent IDs, in the order given, for an error message.
  List<String> missing(Iterable<String> ids) =>
      ids.where((id) => !contains(id)).take(6).toList();

  int add(T item) {
    final position = _items.length;
    _items.add(item);
    if (_lastPositions case final positions?) {
      final id = _idOf(item);
      if (positions.containsKey(id)) _repeated = true;
      positions[id] = position;
    }
    return position;
  }

  void replace(int position, T item) => _items[position] = item;

  /// Replaces every copy of [ids], in list order when an ID repeats.
  void update(Iterable<String> ids, T Function(T) change) {
    for (final position in _positionsOf(ids)) {
      _items[position] = change(_items[position]!);
    }
  }

  void removeAll(Iterable<String> ids) => _positionsOf(ids).forEach(removeAt);

  void removeAt(int position) {
    final item = _items[position];
    if (item == null) return;
    _items[position] = null;
    _removed++;
    if (_repeated) {
      _lastPositions = null;
    } else {
      _lastPositions?.remove(_idOf(item));
    }
  }

  /// The remaining items. Without removals this is a view, which the sheet
  /// constructor copies anyway.
  List<T> toList() =>
      _removed == 0
          ? _items.cast<T>()
          : [
            for (final item in _items)
              if (item != null) item,
          ];

  Map<String, int> get _positions {
    var positions = _lastPositions;
    if (positions == null) {
      positions = _lastPositions = {};
      for (var position = 0; position < _items.length; position++) {
        final item = _items[position];
        if (item != null) positions[_idOf(item)] = position;
      }
      _repeated = positions.length != length;
    }
    return positions;
  }

  List<int> _positionsOf(Iterable<String> ids) {
    final positions = _positions;
    if (!_repeated) {
      return [
        for (final id in ids)
          if (positions[id] case final position?) position,
      ];
    }
    final wanted = ids.toSet();
    return [
      for (var position = 0; position < _items.length; position++)
        if (_items[position] case final item? when wanted.contains(_idOf(item)))
          position,
    ];
  }
}
