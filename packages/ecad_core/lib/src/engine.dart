// SPDX-License-Identifier: GPL-3.0-or-later
import 'commands.dart';
import 'corner_wiring.dart';
import 'autoconnect.dart';
import 'catalog.dart';
import 'edit_history.dart';
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
  List<EditHistoryEntry> get undoHistory => _history(_undo);
  List<EditHistoryEntry> get redoHistory => _history(_redo);

  List<EditHistoryEntry> _history(List<_HistoryEntry> entries) =>
      List.unmodifiable([
        for (final (index, entry) in entries.reversed.indexed)
          EditHistoryEntry(label: entry.label, steps: index + 1),
      ]);

  void execute(
    List<EcadCommand> commands, {
    String label = '',
    int? expectedRevision,
  }) {
    _checkRevision(expectedRevision);
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
    final editedWireIds = {
      for (final command in commands)
        if (command is AddWire)
          command.wire.id
        else if (command is UpdateWire)
          command.wire.id,
    };
    for (final sheet in candidate.pages) {
      final pairs = <(WireEndpoint, WireEndpoint), Wire>{};
      for (final wire in sheet.wires) {
        final previous =
            pairs[(wire.from, wire.to)] ?? pairs[(wire.to, wire.from)];
        if (previous != null &&
            (editedWireIds.contains(wire.id) ||
                editedWireIds.contains(previous.id))) {
          throw const EcadException(
            'These endpoints are already connected.',
            code: 'duplicate_connection',
          );
        }
        pairs[(wire.from, wire.to)] = wire;
      }
    }
    // Nothing observable changes until every command and the final graph pass.
    _undo.add(_HistoryEntry(_project, label));
    if (_undo.length > historyLimit) _undo.removeAt(0);
    _redo.clear();
    _project = candidate;
  }

  bool undo() {
    if (!canUndo) return false;
    return undoSteps(1);
  }

  bool redo() {
    if (!canRedo) return false;
    return redoSteps(1);
  }

  bool undoSteps(int count, {int? expectedRevision}) =>
      _moveHistory(_undo, _redo, count, expectedRevision);

  bool redoSteps(int count, {int? expectedRevision}) =>
      _moveHistory(_redo, _undo, count, expectedRevision);

  bool _moveHistory(
    List<_HistoryEntry> source,
    List<_HistoryEntry> destination,
    int count,
    int? expectedRevision,
  ) {
    _checkRevision(expectedRevision);
    if (count < 1 || count > source.length) {
      throw const EcadException(
        'History step count must be positive and within available history.',
        code: 'invalid_history_count',
      );
    }
    final revision = _nextRevision(count);
    final boundary = source.length - count;
    final candidate = source[boundary].project.copyWith(revision: revision);
    final moved = <_HistoryEntry>[];
    var previous = _project;
    for (var index = source.length - 1; index >= boundary; index--) {
      final entry = source[index];
      moved.add(_HistoryEntry(previous, entry.label));
      previous = entry.project;
    }
    // A rejected jump must leave both stacks intact.
    source.removeRange(boundary, source.length);
    destination.addAll(moved);
    _project = candidate;
    return true;
  }

  void _checkRevision(int? expectedRevision) {
    if (expectedRevision != null && expectedRevision != _project.revision) {
      throw EcadException(
        'This edit targets revision $expectedRevision; the project is at revision ${_project.revision}.',
        code: 'stale_revision',
      );
    }
  }

  int _nextRevision([int count = 1]) {
    if (count > ProjectLimits.maxRevision - _project.revision) {
      throw const EcadException(
        'Project revision limit reached.',
        code: 'limit_exceeded',
      );
    }
    return _project.revision + count;
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
  String? _description;
  late final _articles = _Items(_project.articles, (v) => v.id);
  late final _components = _Items(_project.components, (v) => v.id);
  late final _links = _Items(_project.continuationLinks, (v) => v.id);
  late final _strips = _Items(_project.terminalStrips, (v) => v.id);
  late final _layouts = _Items(_project.mountingLayouts, (v) => v.id);
  final List<Sheet> _pages;

  // A repeated sheet ID addresses its first sheet until validation rejects it.
  final _pageIndex = <String, int>{};
  final _edited = <int, _SheetDraft>{};

  EcadProject build(int revision) => _project.copyWith(
    name: _name,
    description: _description,
    articles: _articles.toList(),
    components: _components.toList(),
    continuationLinks: _links.toList(),
    terminalStrips: _strips.toList(),
    mountingLayouts: _layouts.toList(),
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
      case RenameStructureBranch():
        _renameStructureBranch(command);
      case AddTerminalStrip():
        _add(_strips, command.strip, command.strip.id);
      case UpdateTerminalStrip():
        _replace(_strips, command.strip, command.strip.id);
      case AddArticle():
        _add(_articles, command.article, command.article.id);
      case UpdateArticle():
        final previous = _articles.last(command.article.id);
        if (previous != null &&
            previous.unit != command.article.unit &&
            _components.toList().any((c) => c.articleId == previous.id)) {
          throw const EcadException(
            'The unit of a used article cannot change; assign another article.',
            code: 'article_unit_in_use',
          );
        }
        _replace(_articles, command.article, command.article.id);
      case DeleteArticle():
        _remove(_articles, command.articleId);
      case AddComponent():
        _add(_components, command.component, command.component.id);
      case UpdateComponent():
        _replace(_components, command.component, command.component.id);
      case DeleteComponent():
        _remove(_components, command.componentId);
      case AddContinuationLink():
        _add(_links, command.link, command.link.id);
      case UpdateContinuationLink():
        _replace(_links, command.link, command.link.id);
      case DeleteContinuationLink():
        _remove(_links, command.linkId);
      case AddMountingLayout():
        _add(_layouts, command.layout, command.layout.id);
      case UpdateMountingLayout():
        _replace(_layouts, command.layout, command.layout.id);
      case DeleteMountingLayout():
        _remove(_layouts, command.layoutId);
      case AddConnectionCorner():
        _add(
          _sheet(command.sheetId).corners,
          command.corner,
          command.corner.id,
        );
        _sheet(command.sheetId).insertCorner(command.corner);
      case UpdateConnectionCorner():
        _sheet(command.sheetId).changeCorner(command.corner);
      case DeleteConnectionCorner():
        _remove(_sheet(command.sheetId).corners, command.cornerId);
        _sheet(command.sheetId).deleteAttached(command.cornerId);
      case AddContinuationMarker():
        _add(
          _sheet(command.sheetId).markers,
          command.marker,
          command.marker.id,
        );
      case UpdateContinuationMarker():
        _sheet(command.sheetId).changeMarker(command.marker);
      case DeleteContinuationMarker():
        _remove(_sheet(command.sheetId).markers, command.markerId);
        _sheet(command.sheetId).deleteAttached(command.markerId);
      case SetProjectDescription():
        _description = command.description;
      case UpdateWire():
        _sheet(command.sheetId).updateWire(command.wire);
      case UpdateSheet():
        final before = {
          for (final corner in _sheet(command.sheet.id).corners.toList())
            corner.id: corner,
        };
        var replacement = command.sheet;
        for (final corner in command.sheet.corners) {
          final previous = before[corner.id];
          if (previous == null ||
              previous.position != corner.position ||
              previous.orientation != corner.orientation) {
            replacement = replacement.copyWith(
              wires: insertCornerIntoWires(replacement, corner),
            );
          }
        }
        _pages[_pageIndex[command.sheet.id]!] = replacement;
        _edited.remove(_pageIndex[command.sheet.id]);
      case DeleteSheet():
        _sheet(command.sheetId);
        _flushSheets();
        _pages.removeAt(_pageIndex[command.sheetId]!);
        _reindexSheets();
      case ReorderSheets():
        if (command.ids.length != _pages.length ||
            command.ids.toSet().length != _pages.length ||
            command.ids.any((id) => !_pageIndex.containsKey(id))) {
          throw const EcadException(
            'Reorder requires each sheet ID exactly once.',
            code: 'invalid_command',
          );
        }
        _flushSheets();
        final ordered = [for (final id in command.ids) _pages[_pageIndex[id]!]];
        _pages.clear();
        _pages.addAll(ordered);
        _reindexSheets();

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
        sheet.requireDisconnectedTerminalPorts([command.device]);
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
        sheet.requireDisconnectedTerminalPorts(command.devices);
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

  void _renameStructureBranch(RenameStructureBranch command) {
    if ([
      command.prefix,
      command.replacement,
    ].any((path) => path.length > 16 || !path.every(validReferenceSegment))) {
      throw const EcadException(
        'Invalid structure path.',
        code: 'invalid_structure',
      );
    }
    StructureContext replace(StructureContext value) => replaceStructurePrefix(
      value,
      command.aspect,
      command.prefix,
      command.replacement,
    );
    _flushSheets();
    for (var i = 0; i < _pages.length; i++) {
      final page = _pages[i];
      final context = replace(page.structure);
      if (context != page.structure)
        _pages[i] = page.copyWith(structure: context);
    }
    for (final component in _components.toList()) {
      final reference = component.reference;
      if (reference == null) continue;
      final context = replace(reference.context);
      if (context != reference.context) {
        _replace(
          _components,
          component.copyWith(
            reference: ComponentReference(
              context: context,
              localDesignation: reference.localDesignation,
            ),
          ),
          component.id,
        );
      }
    }
    for (final strip in _strips.toList()) {
      final context = replace(strip.reference.context);
      if (context != strip.reference.context) {
        _replace(
          _strips,
          strip.copyWith(
            reference: ComponentReference(
              context: context,
              localDesignation: strip.reference.localDesignation,
            ),
          ),
          strip.id,
        );
      }
    }
  }

  void _flushSheets() {
    for (final entry in _edited.entries) {
      _pages[entry.key] = entry.value.build();
    }
    _edited.clear();
  }

  void _reindexSheets() {
    _pageIndex.clear();
    for (final (index, sheet) in _pages.indexed) {
      _pageIndex[sheet.id] = index;
    }
  }

  static void _add<T extends Object>(_Items<T> items, T value, String id) {
    if (items.contains(id))
      throw EcadException(
        'Identifier $id already exists.',
        code: 'duplicate_id',
      );
    items.add(value);
  }

  static void _replace<T extends Object>(_Items<T> items, T value, String id) {
    if (!items.contains(id))
      throw EcadException(
        'Identifier $id does not exist.',
        code: 'missing_reference',
      );
    items.update([id], (_) => value);
  }

  static void _remove<T extends Object>(_Items<T> items, String id) {
    if (!items.contains(id))
      throw EcadException(
        'Identifier $id does not exist.',
        code: 'missing_reference',
      );
    items.removeAll([id]);
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
  _Items<ConnectionCorner>? _corners;
  _Items<ConnectionCorner> get corners =>
      _corners ??= _Items(_sheet.corners, (v) => v.id);
  _Items<ContinuationMarker>? _markers;
  _Items<ContinuationMarker> get markers =>
      _markers ??= _Items(_sheet.continuations, (v) => v.id);
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
    continuations: _markers?.toList(),
    corners: _corners?.toList(),
    wires: _wires?.toList(),
    graphics: _graphics?.toList(),
  );

  void addWire(Wire wire) {
    final position = wires.add(wire);
    if (_wiresByDevice case final index?) _attach(index, wire, position);
  }

  void updateWire(Wire wire) {
    _Draft._replace(wires, wire, wire.id);
    _wiresByDevice = null;
  }

  void requireDisconnectedTerminalPorts(Iterable<Device> replacements) {
    final removed = <TerminalRef>{};
    for (final next in replacements) {
      final previous = devices.last(next.id)!;
      if (previous.symbol case TerminalSymbolSpec(:final sides)) {
        final retained = geometryFor(next).ports.map((p) => p.id).toSet();
        removed.addAll(
          sides
              .where((s) => !retained.contains(s.name))
              .map((s) => TerminalRef(deviceId: next.id, portId: s.name)),
        );
      }
    }
    if (removed.isNotEmpty &&
        AutoConnect.wires(
          build(),
        ).any((w) => removed.contains(w.from) || removed.contains(w.to))) {
      throw const EcadException(
        'Disconnect a terminal port before removing its direction.',
        code: 'connected_terminal_port',
      );
    }
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
      for (final id in [wire.from.ownerId, wire.to.ownerId])
        if (lookup(id) case final device?) id: device,
    };
    for (final position in attached) {
      final wire = wires.at(position);
      if (wire == null) continue;
      final markerEnds = {
        for (final id in [wire.from.ownerId, wire.to.ownerId])
          if (markers.last(id) case final marker?) id: marker,
      };
      wires.replace(
        position,
        WireRouter.follow(
          wire,
          ends(wire, (id) => before[id] ?? devices.last(id)),
          ends(wire, devices.last),
          beforeCorners: {for (final c in corners.toList()) c.id: c},
          afterCorners: {for (final c in corners.toList()) c.id: c},
          beforeMarkers: markerEnds,
          afterMarkers: markerEnds,
        ),
      );
    }
  }

  void deleteAttached(String id) => _attachedTo(id).forEach(wires.removeAt);

  void changeMarker(ContinuationMarker marker) {
    final old = markers.last(marker.id);
    if (old == null)
      throw const EcadException(
        'Unknown continuation marker.',
        code: 'missing_reference',
      );
    final before = {for (final m in markers.toList()) m.id: m};
    markers.update([marker.id], (_) => marker);
    final after = {...before, marker.id: marker};
    final deviceMap = {for (final d in devices.toList()) d.id: d};
    for (final position in _attachedTo(marker.id)) {
      final wire = wires.at(position);
      if (wire != null)
        wires.replace(
          position,
          WireRouter.follow(
            wire,
            deviceMap,
            deviceMap,
            beforeCorners: {for (final c in corners.toList()) c.id: c},
            afterCorners: {for (final c in corners.toList()) c.id: c},
            beforeMarkers: before,
            afterMarkers: after,
          ),
        );
    }
  }

  void changeCorner(ConnectionCorner corner) {
    final before = {for (final c in corners.toList()) c.id: c};
    _Draft._replace(corners, corner, corner.id);
    final after = {...before, corner.id: corner};
    final deviceMap = {for (final d in devices.toList()) d.id: d};
    final markerMap = {for (final m in markers.toList()) m.id: m};
    for (final position in _attachedTo(corner.id)) {
      final wire = wires.at(position);
      if (wire == null) continue;
      wires.replace(
        position,
        WireRouter.follow(
          wire,
          deviceMap,
          deviceMap,
          beforeMarkers: markerMap,
          afterMarkers: markerMap,
          beforeCorners: before,
          afterCorners: after,
        ),
      );
    }
    insertCorner(corner);
  }

  void insertCorner(ConnectionCorner corner) {
    final previous = wires.toList();
    final next = insertCornerIntoWires(build(), corner);
    if (previous.length == next.length &&
        previous.indexed.every(
          (entry) => identical(entry.$2, next[entry.$1]),
        )) {
      return;
    }
    _wires = _Items(next, (wire) => wire.id);
    _wiresByDevice = null;
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
    index.putIfAbsent(wire.from.ownerId, () => []).add(position);
    if (wire.to.ownerId != wire.from.ownerId) {
      index.putIfAbsent(wire.to.ownerId, () => []).add(position);
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
