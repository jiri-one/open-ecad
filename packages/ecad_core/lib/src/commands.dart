// SPDX-License-Identifier: GPL-3.0-or-later
import 'model.dart';
import 'graphics.dart';

sealed class EcadCommand {
  const EcadCommand();
  Map<String, Object?> toJson();

  static EcadCommand fromJson(Object? value) {
    final map = jsonObject(value, 'command');
    final type = jsonString(map, 'type', max: 40);
    String sheetId() => jsonString(map, 'sheetId', max: 128);
    void fields(Set<String> names) =>
        jsonObject(value, 'command', allowed: {'type', ...names});
    switch (type) {
      case 'addDevice':
        fields({'sheetId', 'device'});
        return AddDevice(sheetId(), Device.fromJson(map['device']));
      case 'moveDevices':
        fields({'sheetId', 'positions'});
        final positions = jsonObject(map['positions'], 'positions');
        if (positions.isEmpty || positions.length > ProjectLimits.maxDevices) {
          throw const EcadException(
            'Move requires 1–20000 device positions.',
            code: 'limit_exceeded',
          );
        }
        return MoveDevices(
          sheetId(),
          positions.map(
            (id, point) => MapEntry(
              jsonString({'id': id}, 'id', max: 128),
              Vec2.fromJson(point),
            ),
          ),
        );
      case 'updateDevice':
        fields({'sheetId', 'device'});
        return UpdateDevice(sheetId(), Device.fromJson(map['device']));
      case 'updateDevices':
        fields({'sheetId', 'devices'});
        final devices =
            jsonList(
              map,
              'devices',
              max: ProjectLimits.maxDevices,
            ).map(Device.fromJson).toList();
        if (devices.isEmpty ||
            devices.map((device) => device.id).toSet().length !=
                devices.length) {
          throw const EcadException(
            'Update requires distinct device IDs.',
            code: 'invalid_command',
          );
        }
        return UpdateDevices(sheetId(), devices);
      case 'deleteDevices':
        fields({'sheetId', 'ids'});
        final rawIds = jsonList(map, 'ids', max: ProjectLimits.maxDevices);
        final ids =
            rawIds.map((id) => jsonString({'id': id}, 'id', max: 128)).toSet();
        if (ids.isEmpty || ids.length != rawIds.length) {
          throw const EcadException(
            'Delete requires distinct device IDs.',
            code: 'invalid_command',
          );
        }
        return DeleteDevices(sheetId(), ids);
      case 'addGraphics':
        fields({'sheetId', 'graphics'});
        final graphics = jsonList(
          map,
          'graphics',
          max: ProjectLimits.maxGraphics,
        );
        if (graphics.isEmpty) {
          throw const EcadException(
            'Add requires at least one drawing element.',
            code: 'invalid_command',
          );
        }
        return AddGraphics(
          sheetId(),
          graphics.map(DrawingElement.fromJson).toList(),
        );
      case 'updateGraphic':
        fields({'sheetId', 'graphic'});
        return UpdateGraphic(
          sheetId(),
          DrawingElement.fromJson(map['graphic']),
        );
      case 'updateGraphics':
        fields({'sheetId', 'graphics'});
        final graphics =
            jsonList(
              map,
              'graphics',
              max: ProjectLimits.maxGraphics,
            ).map(DrawingElement.fromJson).toList();
        if (graphics.isEmpty ||
            graphics.map((graphic) => graphic.id).toSet().length !=
                graphics.length) {
          throw const EcadException(
            'Update requires distinct drawing element IDs.',
            code: 'invalid_command',
          );
        }
        return UpdateGraphics(sheetId(), graphics);
      case 'moveGraphics':
        fields({'sheetId', 'positions'});
        final positions = jsonObject(map['positions'], 'positions');
        if (positions.isEmpty || positions.length > ProjectLimits.maxGraphics) {
          throw const EcadException(
            'Move requires a bounded nonempty set of drawing positions.',
            code: 'limit_exceeded',
          );
        }
        return MoveGraphics(
          sheetId(),
          positions.map(
            (id, point) => MapEntry(
              jsonString({'id': id}, 'id', max: 128),
              Vec2.fromJson(point),
            ),
          ),
        );
      case 'deleteGraphics':
        fields({'sheetId', 'ids'});
        final rawIds = jsonList(map, 'ids', max: ProjectLimits.maxGraphics);
        final ids =
            rawIds.map((id) => jsonString({'id': id}, 'id', max: 128)).toSet();
        if (ids.isEmpty || ids.length != rawIds.length) {
          throw const EcadException(
            'Delete requires distinct drawing element IDs.',
            code: 'invalid_command',
          );
        }
        return DeleteGraphics(sheetId(), ids);
      case 'addWire':
        fields({'sheetId', 'wire'});
        return AddWire(sheetId(), Wire.fromJson(map['wire']));
      case 'deleteWire':
        fields({'sheetId', 'wireId'});
        return DeleteWire(sheetId(), jsonString(map, 'wireId', max: 128));
      case 'addSheet':
        fields({'sheet'});
        return AddSheet(Sheet.fromJson(map['sheet']));
      case 'renameSheet':
        fields({'sheetId', 'name'});
        return RenameSheet(sheetId(), jsonString(map, 'name', max: 200));
      case 'setSheetType':
        fields({'sheetId', 'sheetType'});
        return SetSheetType(sheetId(), jsonSheetType(map, 'sheetType'));
      case 'renameProject':
        fields({'name'});
        return RenameProject(jsonString(map, 'name', max: 200));
      default:
        throw EcadException(
          'Unknown command type "$type".',
          code: 'invalid_command',
        );
    }
  }
}

class AddDevice extends EcadCommand {
  const AddDevice(this.sheetId, this.device);
  final String sheetId;
  final Device device;
  @override
  Map<String, Object?> toJson() => {
    'type': 'addDevice',
    'sheetId': sheetId,
    'device': device.toJson(),
  };
}

class MoveDevices extends EcadCommand {
  MoveDevices(this.sheetId, Map<String, Vec2> positions)
    : positions = Map.unmodifiable(positions);
  final String sheetId;
  final Map<String, Vec2> positions;
  @override
  Map<String, Object?> toJson() => {
    'type': 'moveDevices',
    'sheetId': sheetId,
    'positions': positions.map((id, point) => MapEntry(id, point.toJson())),
  };
}

class UpdateDevice extends EcadCommand {
  const UpdateDevice(this.sheetId, this.device);
  final String sheetId;
  final Device device;
  @override
  Map<String, Object?> toJson() => {
    'type': 'updateDevice',
    'sheetId': sheetId,
    'device': device.toJson(),
  };
}

/// Replaces many existing devices in one step, such as a rotated selection.
class UpdateDevices extends EcadCommand {
  UpdateDevices(this.sheetId, List<Device> devices)
    : devices = List.unmodifiable(devices);
  final String sheetId;
  final List<Device> devices;
  @override
  Map<String, Object?> toJson() => {
    'type': 'updateDevices',
    'sheetId': sheetId,
    'devices': devices.map((device) => device.toJson()).toList(),
  };
}

class DeleteDevices extends EcadCommand {
  DeleteDevices(this.sheetId, Set<String> ids) : ids = Set.unmodifiable(ids);
  final String sheetId;
  final Set<String> ids;
  @override
  Map<String, Object?> toJson() => {
    'type': 'deleteDevices',
    'sheetId': sheetId,
    'ids': ids.toList(),
  };
}

class AddWire extends EcadCommand {
  const AddWire(this.sheetId, this.wire);
  final String sheetId;
  final Wire wire;
  @override
  Map<String, Object?> toJson() => {
    'type': 'addWire',
    'sheetId': sheetId,
    'wire': wire.toJson(),
  };
}

class AddGraphics extends EcadCommand {
  AddGraphics(this.sheetId, List<DrawingElement> graphics)
    : graphics = List.unmodifiable(graphics);
  final String sheetId;
  final List<DrawingElement> graphics;
  @override
  Map<String, Object?> toJson() => {
    'type': 'addGraphics',
    'sheetId': sheetId,
    'graphics': graphics.map((graphic) => graphic.toJson()).toList(),
  };
}

class UpdateGraphic extends EcadCommand {
  const UpdateGraphic(this.sheetId, this.graphic);
  final String sheetId;
  final DrawingElement graphic;
  @override
  Map<String, Object?> toJson() => {
    'type': 'updateGraphic',
    'sheetId': sheetId,
    'graphic': graphic.toJson(),
  };
}

class MoveGraphics extends EcadCommand {
  MoveGraphics(this.sheetId, Map<String, Vec2> positions)
    : positions = Map.unmodifiable(positions);
  final String sheetId;
  final Map<String, Vec2> positions;
  @override
  Map<String, Object?> toJson() => {
    'type': 'moveGraphics',
    'sheetId': sheetId,
    'positions': positions.map((id, point) => MapEntry(id, point.toJson())),
  };
}

/// Replaces many existing graphics without changing their drawing order.
class UpdateGraphics extends EcadCommand {
  UpdateGraphics(this.sheetId, List<DrawingElement> graphics)
    : graphics = List.unmodifiable(graphics);
  final String sheetId;
  final List<DrawingElement> graphics;
  @override
  Map<String, Object?> toJson() => {
    'type': 'updateGraphics',
    'sheetId': sheetId,
    'graphics': graphics.map((graphic) => graphic.toJson()).toList(),
  };
}

class DeleteGraphics extends EcadCommand {
  DeleteGraphics(this.sheetId, Set<String> ids) : ids = Set.unmodifiable(ids);
  final String sheetId;
  final Set<String> ids;
  @override
  Map<String, Object?> toJson() => {
    'type': 'deleteGraphics',
    'sheetId': sheetId,
    'ids': ids.toList(),
  };
}

class DeleteWire extends EcadCommand {
  const DeleteWire(this.sheetId, this.wireId);
  final String sheetId;
  final String wireId;
  @override
  Map<String, Object?> toJson() => {
    'type': 'deleteWire',
    'sheetId': sheetId,
    'wireId': wireId,
  };
}

class AddSheet extends EcadCommand {
  const AddSheet(this.sheet);
  final Sheet sheet;
  @override
  Map<String, Object?> toJson() => {
    'type': 'addSheet',
    'sheet': sheet.toJson(),
  };
}

class RenameSheet extends EcadCommand {
  const RenameSheet(this.sheetId, this.name);
  final String sheetId;
  final String name;
  @override
  Map<String, Object?> toJson() => {
    'type': 'renameSheet',
    'sheetId': sheetId,
    'name': name,
  };
}

class SetSheetType extends EcadCommand {
  const SetSheetType(this.sheetId, this.sheetType);
  final String sheetId;
  final SheetType sheetType;
  @override
  Map<String, Object?> toJson() => {
    'type': 'setSheetType',
    'sheetId': sheetId,
    'sheetType': sheetType.name,
  };
}

class RenameProject extends EcadCommand {
  const RenameProject(this.name);
  final String name;
  @override
  Map<String, Object?> toJson() => {'type': 'renameProject', 'name': name};
}

List<EcadCommand> decodeCommands(Object? value) {
  if (value is! List ||
      value.isEmpty ||
      value.length > ProjectLimits.maxCommands) {
    throw const EcadException(
      'Command batch must contain 1–1000 commands.',
      code: 'limit_exceeded',
    );
  }
  return List.unmodifiable(value.map(EcadCommand.fromJson));
}
