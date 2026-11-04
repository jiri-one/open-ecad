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
      case 'renameStructureBranch':
        fields({'aspect', 'prefix', 'replacement'});
        final aspects = StructureAspect.values.where(
          (aspect) => aspect.name == jsonString(map, 'aspect', max: 16),
        );
        if (aspects.isEmpty) {
          throw const EcadException(
            'Unknown structure aspect.',
            code: 'invalid_command',
          );
        }
        List<String> path(String key) =>
            jsonList(
              map,
              key,
              max: 16,
            ).map((v) => jsonString({'value': v}, 'value', max: 64)).toList();
        return RenameStructureBranch(
          aspects.single,
          path('prefix'),
          path('replacement'),
        );
      case 'addTerminalStrip':
        fields({'strip'});
        return AddTerminalStrip(TerminalStrip.fromJson(map['strip']));
      case 'updateTerminalStrip':
        fields({'strip'});
        return UpdateTerminalStrip(TerminalStrip.fromJson(map['strip']));
      case 'addArticle':
        fields({'article'});
        return AddArticle(Article.fromJson(map['article']));
      case 'updateArticle':
        fields({'article'});
        return UpdateArticle(Article.fromJson(map['article']));
      case 'deleteArticle':
        fields({'articleId'});
        return DeleteArticle(jsonString(map, 'articleId', max: 128));
      case 'addComponent':
        fields({'component'});
        return AddComponent(Component.fromJson(map['component']));
      case 'updateComponent':
        fields({'component'});
        return UpdateComponent(Component.fromJson(map['component']));
      case 'deleteComponent':
        fields({'componentId'});
        return DeleteComponent(jsonString(map, 'componentId', max: 128));
      case 'addContinuationLink':
        fields({'link'});
        return AddContinuationLink(ContinuationLink.fromJson(map['link']));
      case 'updateContinuationLink':
        fields({'link'});
        return UpdateContinuationLink(ContinuationLink.fromJson(map['link']));
      case 'deleteContinuationLink':
        fields({'linkId'});
        return DeleteContinuationLink(jsonString(map, 'linkId', max: 128));
      case 'addMountingLayout':
        fields({'layout'});
        return AddMountingLayout(MountingLayout.fromJson(map['layout']));
      case 'updateMountingLayout':
        fields({'layout'});
        return UpdateMountingLayout(MountingLayout.fromJson(map['layout']));
      case 'deleteMountingLayout':
        fields({'layoutId'});
        return DeleteMountingLayout(jsonString(map, 'layoutId', max: 128));
      case 'addContinuationMarker':
        fields({'marker', 'sheetId'});
        return AddContinuationMarker(
          sheetId(),
          ContinuationMarker.fromJson(map['marker']),
        );
      case 'updateContinuationMarker':
        fields({'marker', 'sheetId'});
        return UpdateContinuationMarker(
          sheetId(),
          ContinuationMarker.fromJson(map['marker']),
        );
      case 'deleteContinuationMarker':
        fields({'markerId', 'sheetId'});
        return DeleteContinuationMarker(
          sheetId(),
          jsonString(map, 'markerId', max: 128),
        );
      case 'updateSheet':
        fields({'sheet'});
        return UpdateSheet(Sheet.fromJson(map['sheet']));
      case 'updateWire':
        fields({'wire', 'sheetId'});
        return UpdateWire(sheetId(), Wire.fromJson(map['wire']));
      case 'deleteSheet':
        fields({'sheetId'});
        return DeleteSheet(sheetId());
      case 'reorderSheets':
        fields({'ids'});
        return ReorderSheets(
          jsonList(
            map,
            'ids',
            max: ProjectLimits.maxPages,
          ).map((v) => jsonString({'id': v}, 'id', max: 128)).toList(),
        );
      case 'setProjectDescription':
        fields({'description'});
        return SetProjectDescription(jsonString(map, 'description', max: 8192));

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
      case 'setMainFunction':
        fields({'sheetId', 'deviceId'});
        return SetMainFunction(
          sheetId(),
          jsonString(map, 'deviceId', max: 128),
        );
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
      case 'addConnectionCorner':
        fields({'sheetId', 'corner'});
        return AddConnectionCorner(
          sheetId(),
          ConnectionCorner.fromJson(map['corner']),
        );
      case 'updateConnectionCorner':
        fields({'sheetId', 'corner'});
        return UpdateConnectionCorner(
          sheetId(),
          ConnectionCorner.fromJson(map['corner']),
        );
      case 'deleteConnectionCorner':
        fields({'sheetId', 'cornerId'});
        return DeleteConnectionCorner(
          sheetId(),
          jsonString(map, 'cornerId', max: 128),
        );
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

class RenameStructureBranch extends EcadCommand {
  RenameStructureBranch(
    this.aspect,
    List<String> prefix,
    List<String> replacement,
  ) : prefix = List.unmodifiable(prefix),
      replacement = List.unmodifiable(replacement);
  final StructureAspect aspect;
  final List<String> prefix, replacement;
  @override
  Map<String, Object?> toJson() => {
    'type': 'renameStructureBranch',
    'aspect': aspect.name,
    'prefix': prefix,
    'replacement': replacement,
  };
}

class AddTerminalStrip extends EcadCommand {
  const AddTerminalStrip(this.strip);
  final TerminalStrip strip;
  @override
  Map<String, Object?> toJson() => {
    'type': 'addTerminalStrip',
    'strip': strip.toJson(),
  };
}

class UpdateTerminalStrip extends EcadCommand {
  const UpdateTerminalStrip(this.strip);
  final TerminalStrip strip;
  @override
  Map<String, Object?> toJson() => {
    'type': 'updateTerminalStrip',
    'strip': strip.toJson(),
  };
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

class SetMainFunction extends EcadCommand {
  const SetMainFunction(this.sheetId, this.deviceId);
  final String sheetId;
  final String deviceId;
  @override
  Map<String, Object?> toJson() => {
    'type': 'setMainFunction',
    'sheetId': sheetId,
    'deviceId': deviceId,
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

class AddArticle extends EcadCommand {
  const AddArticle(this.article);
  final Article article;
  @override
  Map<String, Object?> toJson() => {
    'type': 'addArticle',
    'article': article.toJson(),
  };
}

class UpdateArticle extends EcadCommand {
  const UpdateArticle(this.article);
  final Article article;
  @override
  Map<String, Object?> toJson() => {
    'type': 'updateArticle',
    'article': article.toJson(),
  };
}

class DeleteArticle extends EcadCommand {
  const DeleteArticle(this.articleId);
  final String articleId;
  @override
  Map<String, Object?> toJson() => {
    'type': 'deleteArticle',
    'articleId': articleId,
  };
}

class AddComponent extends EcadCommand {
  const AddComponent(this.component);
  final Component component;
  @override
  Map<String, Object?> toJson() => {
    'type': 'addComponent',
    'component': component.toJson(),
  };
}

class UpdateComponent extends EcadCommand {
  const UpdateComponent(this.component);
  final Component component;
  @override
  Map<String, Object?> toJson() => {
    'type': 'updateComponent',
    'component': component.toJson(),
  };
}

class DeleteComponent extends EcadCommand {
  const DeleteComponent(this.componentId);
  final String componentId;
  @override
  Map<String, Object?> toJson() => {
    'type': 'deleteComponent',
    'componentId': componentId,
  };
}

class AddContinuationLink extends EcadCommand {
  const AddContinuationLink(this.link);
  final ContinuationLink link;
  @override
  Map<String, Object?> toJson() => {
    'type': 'addContinuationLink',
    'link': link.toJson(),
  };
}

class UpdateContinuationLink extends EcadCommand {
  const UpdateContinuationLink(this.link);
  final ContinuationLink link;
  @override
  Map<String, Object?> toJson() => {
    'type': 'updateContinuationLink',
    'link': link.toJson(),
  };
}

class DeleteContinuationLink extends EcadCommand {
  const DeleteContinuationLink(this.linkId);
  final String linkId;
  @override
  Map<String, Object?> toJson() => {
    'type': 'deleteContinuationLink',
    'linkId': linkId,
  };
}

class AddMountingLayout extends EcadCommand {
  const AddMountingLayout(this.layout);
  final MountingLayout layout;
  @override
  Map<String, Object?> toJson() => {
    'type': 'addMountingLayout',
    'layout': layout.toJson(),
  };
}

class UpdateMountingLayout extends EcadCommand {
  const UpdateMountingLayout(this.layout);
  final MountingLayout layout;
  @override
  Map<String, Object?> toJson() => {
    'type': 'updateMountingLayout',
    'layout': layout.toJson(),
  };
}

class DeleteMountingLayout extends EcadCommand {
  const DeleteMountingLayout(this.layoutId);
  final String layoutId;
  @override
  Map<String, Object?> toJson() => {
    'type': 'deleteMountingLayout',
    'layoutId': layoutId,
  };
}

class AddContinuationMarker extends EcadCommand {
  const AddContinuationMarker(this.sheetId, this.marker);
  final String sheetId;
  final ContinuationMarker marker;
  @override
  Map<String, Object?> toJson() => {
    'type': 'addContinuationMarker',
    'sheetId': sheetId,
    'marker': marker.toJson(),
  };
}

class UpdateContinuationMarker extends EcadCommand {
  const UpdateContinuationMarker(this.sheetId, this.marker);
  final String sheetId;
  final ContinuationMarker marker;
  @override
  Map<String, Object?> toJson() => {
    'type': 'updateContinuationMarker',
    'sheetId': sheetId,
    'marker': marker.toJson(),
  };
}

class DeleteContinuationMarker extends EcadCommand {
  const DeleteContinuationMarker(this.sheetId, this.markerId);
  final String sheetId;
  final String markerId;
  @override
  Map<String, Object?> toJson() => {
    'type': 'deleteContinuationMarker',
    'sheetId': sheetId,
    'markerId': markerId,
  };
}

class UpdateSheet extends EcadCommand {
  const UpdateSheet(this.sheet);
  final Sheet sheet;
  @override
  Map<String, Object?> toJson() => {
    'type': 'updateSheet',
    'sheet': sheet.toJson(),
  };
}

class UpdateWire extends EcadCommand {
  const UpdateWire(this.sheetId, this.wire);
  final String sheetId;
  final Wire wire;
  @override
  Map<String, Object?> toJson() => {
    'type': 'updateWire',
    'sheetId': sheetId,
    'wire': wire.toJson(),
  };
}

class DeleteSheet extends EcadCommand {
  const DeleteSheet(this.sheetId);
  final String sheetId;
  @override
  Map<String, Object?> toJson() => {'type': 'deleteSheet', 'sheetId': sheetId};
}

class ReorderSheets extends EcadCommand {
  ReorderSheets(List<String> ids) : ids = List.unmodifiable(ids);
  final List<String> ids;
  @override
  Map<String, Object?> toJson() => {'type': 'reorderSheets', 'ids': ids};
}

class SetProjectDescription extends EcadCommand {
  const SetProjectDescription(this.description);
  final String description;
  @override
  Map<String, Object?> toJson() => {
    'type': 'setProjectDescription',
    'description': description,
  };
}

class AddConnectionCorner extends EcadCommand {
  const AddConnectionCorner(this.sheetId, this.corner);
  final String sheetId;
  final ConnectionCorner corner;
  @override
  Map<String, Object?> toJson() => {
    'type': 'addConnectionCorner',
    'sheetId': sheetId,
    'corner': corner.toJson(),
  };
}

class UpdateConnectionCorner extends EcadCommand {
  const UpdateConnectionCorner(this.sheetId, this.corner);
  final String sheetId;
  final ConnectionCorner corner;
  @override
  Map<String, Object?> toJson() => {
    'type': 'updateConnectionCorner',
    'sheetId': sheetId,
    'corner': corner.toJson(),
  };
}

class DeleteConnectionCorner extends EcadCommand {
  const DeleteConnectionCorner(this.sheetId, this.cornerId);
  final String sheetId;
  final String cornerId;
  @override
  Map<String, Object?> toJson() => {
    'type': 'deleteConnectionCorner',
    'sheetId': sheetId,
    'cornerId': cornerId,
  };
}
