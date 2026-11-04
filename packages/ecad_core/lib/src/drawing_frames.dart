// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'model.dart';
import 'resolver.dart';

abstract final class FrameLimits {
  static const templates = 128;
  static const fields = 128;
  static const lines = 256;
  static const text = 2048;
  static const templateText = 32768;
  static const documentFields = 64;
  static const documentKey = 64;
  static const documentText = 32768;
  static const projectText = 1024 * 1024;
  static const zones = 100;
  static const dimensionMm = 10000.0;
  static const fontSizeMm = 50.0;
  static const strokeWidthMm = 10.0;
}

enum FrameMode { inherit, template, none }

enum FrameTextAlign { left, center, right }

enum FrameTextOverflow { wrap, shrink }

class FrameChoice {
  const FrameChoice.inherit({this.border, this.titleBlock, this.zones})
    : mode = FrameMode.inherit,
      templateId = null;
  const FrameChoice.template(
    this.templateId, {
    this.border,
    this.titleBlock,
    this.zones,
  }) : mode = FrameMode.template;
  const FrameChoice.none()
    : mode = FrameMode.none,
      templateId = null,
      border = null,
      titleBlock = null,
      zones = null;

  final FrameMode mode;
  final String? templateId;
  final bool? border;
  final bool? titleBlock;
  final bool? zones;

  FrameChoice copyWith({
    FrameMode? mode,
    Object? templateId = unchanged,
    Object? border = unchanged,
    Object? titleBlock = unchanged,
    Object? zones = unchanged,
  }) {
    final nextMode = mode ?? this.mode;
    final id =
        identical(templateId, unchanged)
            ? this.templateId
            : templateId as String?;
    final b = identical(border, unchanged) ? this.border : border as bool?;
    final t =
        identical(titleBlock, unchanged)
            ? this.titleBlock
            : titleBlock as bool?;
    final z = identical(zones, unchanged) ? this.zones : zones as bool?;
    return switch (nextMode) {
      FrameMode.none => const FrameChoice.none(),
      FrameMode.inherit => FrameChoice.inherit(
        border: b,
        titleBlock: t,
        zones: z,
      ),
      FrameMode.template => FrameChoice.template(
        id,
        border: b,
        titleBlock: t,
        zones: z,
      ),
    };
  }

  void validate({bool projectDefault = false}) {
    if (projectDefault && mode == FrameMode.inherit) {
      _fail('The project frame cannot inherit.', 'invalid_frame_choice');
    }
    if (mode == FrameMode.template && !_identifier.hasMatch(templateId ?? '')) {
      _fail(
        'A template choice requires a valid template ID.',
        'invalid_frame_choice',
      );
    }
  }

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    if (templateId != null) 'templateId': templateId,
    if (border != null) 'border': border,
    if (titleBlock != null) 'titleBlock': titleBlock,
    if (zones != null) 'zones': zones,
  };

  factory FrameChoice.fromJson(Object? value) {
    final m = jsonObject(
      value,
      'frame choice',
      allowed: const {'mode', 'templateId', 'border', 'titleBlock', 'zones'},
    );
    final mode = _enum(m, 'mode', FrameMode.values);
    if ((mode != FrameMode.template && m.containsKey('templateId')) ||
        (mode == FrameMode.none && m.keys.any((k) => k != 'mode'))) {
      _fail(
        'Frame choice contains properties incompatible with its mode.',
        'invalid_frame_choice',
      );
    }
    bool? part(String key) =>
        !m.containsKey(key) || m[key] == null
            ? null
            : jsonBool(m, key, fallback: true);
    final result = switch (mode) {
      FrameMode.none => const FrameChoice.none(),
      FrameMode.inherit => FrameChoice.inherit(
        border: part('border'),
        titleBlock: part('titleBlock'),
        zones: part('zones'),
      ),
      FrameMode.template => FrameChoice.template(
        jsonString(m, 'templateId', max: 128),
        border: part('border'),
        titleBlock: part('titleBlock'),
        zones: part('zones'),
      ),
    };
    result.validate();
    return result;
  }
}

class FrameMargins {
  const FrameMargins({
    this.left = 10,
    this.top = 10,
    this.right = 10,
    this.bottom = 10,
  });
  final double left, top, right, bottom;
  FrameMargins copyWith({
    double? left,
    double? top,
    double? right,
    double? bottom,
  }) => FrameMargins(
    left: left ?? this.left,
    top: top ?? this.top,
    right: right ?? this.right,
    bottom: bottom ?? this.bottom,
  );
  Map<String, Object?> toJson() => {
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };
  factory FrameMargins.fromJson(Object? value) {
    final m = jsonObject(
      value,
      'frame margins',
      allowed: const {'left', 'top', 'right', 'bottom'},
    );
    return FrameMargins(
      left: jsonNumber(m, 'left'),
      top: jsonNumber(m, 'top'),
      right: jsonNumber(m, 'right'),
      bottom: jsonNumber(m, 'bottom'),
    );
  }
}

class RectMm {
  const RectMm({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
  final double x, y, width, height;
  double get right => x + width;
  double get bottom => y + height;
  Vec2 get topLeft => Vec2(x, y);
  Vec2 get bottomRight => Vec2(right, bottom);
  RectMm copyWith({double? x, double? y, double? width, double? height}) =>
      RectMm(
        x: x ?? this.x,
        y: y ?? this.y,
        width: width ?? this.width,
        height: height ?? this.height,
      );
  RectMm translated(Vec2 delta) => copyWith(x: x + delta.x, y: y + delta.y);
  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };
  factory RectMm.fromJson(Object? value) {
    final r = RectUnits.fromJson(value);
    return RectMm(x: r.x, y: r.y, width: r.width, height: r.height);
  }
}

class FrameLine {
  const FrameLine(this.from, this.to);
  final Vec2 from, to;
  FrameLine copyWith({Vec2? from, Vec2? to}) =>
      FrameLine(from ?? this.from, to ?? this.to);
  Map<String, Object?> toJson() => {'from': from.toJson(), 'to': to.toJson()};
  factory FrameLine.fromJson(Object? value) {
    final m = jsonObject(value, 'frame line', allowed: const {'from', 'to'});
    return FrameLine(Vec2.fromJson(m['from']), Vec2.fromJson(m['to']));
  }
}

class FrameZones {
  const FrameZones({
    this.columns = 5,
    this.rows = 4,
    this.bandMm = 5,
    this.tickMm = 2,
    this.fontSizeMm = 2.5,
  });
  final int columns, rows;
  final double bandMm, tickMm, fontSizeMm;
  FrameZones copyWith({
    int? columns,
    int? rows,
    double? bandMm,
    double? tickMm,
    double? fontSizeMm,
  }) => FrameZones(
    columns: columns ?? this.columns,
    rows: rows ?? this.rows,
    bandMm: bandMm ?? this.bandMm,
    tickMm: tickMm ?? this.tickMm,
    fontSizeMm: fontSizeMm ?? this.fontSizeMm,
  );
  Map<String, Object?> toJson() => {
    'columns': columns,
    'rows': rows,
    'bandMm': bandMm,
    'tickMm': tickMm,
    'fontSizeMm': fontSizeMm,
  };
  factory FrameZones.fromJson(Object? value) {
    final m = jsonObject(
      value,
      'frame zones',
      allowed: const {'columns', 'rows', 'bandMm', 'tickMm', 'fontSizeMm'},
    );
    return FrameZones(
      columns: jsonInteger(m, 'columns', max: FrameLimits.zones),
      rows: jsonInteger(m, 'rows', max: FrameLimits.zones),
      bandMm: jsonNumber(m, 'bandMm'),
      tickMm: jsonNumber(m, 'tickMm'),
      fontSizeMm: jsonNumber(m, 'fontSizeMm'),
    );
  }
}

class FrameField {
  const FrameField({
    required this.id,
    required this.rectMm,
    required this.text,
    this.fontSizeMm = 3,
    this.minFontSizeMm = 2,
    this.bold = false,
    this.align = FrameTextAlign.left,
    this.overflow = FrameTextOverflow.shrink,
  });
  final String id;
  final RectMm rectMm;
  final String text;
  final double fontSizeMm, minFontSizeMm;
  final bool bold;
  final FrameTextAlign align;
  final FrameTextOverflow overflow;
  FrameField copyWith({
    String? id,
    RectMm? rectMm,
    String? text,
    double? fontSizeMm,
    double? minFontSizeMm,
    bool? bold,
    FrameTextAlign? align,
    FrameTextOverflow? overflow,
  }) => FrameField(
    id: id ?? this.id,
    rectMm: rectMm ?? this.rectMm,
    text: text ?? this.text,
    fontSizeMm: fontSizeMm ?? this.fontSizeMm,
    minFontSizeMm: minFontSizeMm ?? this.minFontSizeMm,
    bold: bold ?? this.bold,
    align: align ?? this.align,
    overflow: overflow ?? this.overflow,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'rectMm': rectMm.toJson(),
    'text': text,
    'fontSizeMm': fontSizeMm,
    'minFontSizeMm': minFontSizeMm,
    'bold': bold,
    'align': align.name,
    'overflow': overflow.name,
  };
  factory FrameField.fromJson(Object? value) {
    final m = jsonObject(
      value,
      'frame field',
      allowed: const {
        'id',
        'rectMm',
        'text',
        'fontSizeMm',
        'minFontSizeMm',
        'bold',
        'align',
        'overflow',
      },
    );
    return FrameField(
      id: jsonString(m, 'id', max: 128),
      rectMm: RectMm.fromJson(m['rectMm']),
      text: jsonString(m, 'text', max: FrameLimits.text),
      fontSizeMm: jsonNumber(m, 'fontSizeMm'),
      minFontSizeMm: jsonNumber(m, 'minFontSizeMm'),
      bold: jsonBool(m, 'bold', fallback: false),
      align: _enum(m, 'align', FrameTextAlign.values),
      overflow: _enum(m, 'overflow', FrameTextOverflow.values),
    );
  }
}

class FrameTitleBlock {
  FrameTitleBlock({
    required this.widthMm,
    required this.heightMm,
    List<FrameLine> lines = const [],
    List<FrameField> fields = const [],
  }) : lines = List.unmodifiable(lines),
       fields = List.unmodifiable(fields);
  final double widthMm, heightMm;
  final List<FrameLine> lines;
  final List<FrameField> fields;
  FrameTitleBlock copyWith({
    double? widthMm,
    double? heightMm,
    List<FrameLine>? lines,
    List<FrameField>? fields,
  }) => FrameTitleBlock(
    widthMm: widthMm ?? this.widthMm,
    heightMm: heightMm ?? this.heightMm,
    lines: lines ?? this.lines,
    fields: fields ?? this.fields,
  );
  Map<String, Object?> toJson() => {
    'widthMm': widthMm,
    'heightMm': heightMm,
    'lines': lines.map((v) => v.toJson()).toList(),
    'fields': fields.map((v) => v.toJson()).toList(),
  };
  factory FrameTitleBlock.fromJson(Object? value) {
    final m = jsonObject(
      value,
      'title block',
      allowed: const {'widthMm', 'heightMm', 'lines', 'fields'},
    );
    return FrameTitleBlock(
      widthMm: jsonNumber(m, 'widthMm'),
      heightMm: jsonNumber(m, 'heightMm'),
      lines:
          jsonList(
            m,
            'lines',
            max: FrameLimits.lines,
          ).map(FrameLine.fromJson).toList(),
      fields:
          jsonList(
            m,
            'fields',
            max: FrameLimits.fields,
          ).map(FrameField.fromJson).toList(),
    );
  }
}

class FrameTemplate {
  FrameTemplate({
    required this.id,
    required this.name,
    required this.titleBlock,
    this.marginsMm = const FrameMargins(),
    this.contentPaddingMm = 3,
    this.strokeWidthMm = 0.35,
    this.zones = const FrameZones(),
  });
  final String id, name;
  final FrameMargins marginsMm;
  final double contentPaddingMm, strokeWidthMm;
  final FrameZones zones;
  final FrameTitleBlock titleBlock;
  FrameTemplate copyWith({
    String? id,
    String? name,
    FrameMargins? marginsMm,
    double? contentPaddingMm,
    double? strokeWidthMm,
    FrameZones? zones,
    FrameTitleBlock? titleBlock,
  }) => FrameTemplate(
    id: id ?? this.id,
    name: name ?? this.name,
    marginsMm: marginsMm ?? this.marginsMm,
    contentPaddingMm: contentPaddingMm ?? this.contentPaddingMm,
    strokeWidthMm: strokeWidthMm ?? this.strokeWidthMm,
    zones: zones ?? this.zones,
    titleBlock: titleBlock ?? this.titleBlock,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'marginsMm': marginsMm.toJson(),
    'contentPaddingMm': contentPaddingMm,
    'strokeWidthMm': strokeWidthMm,
    'zones': zones.toJson(),
    'titleBlock': titleBlock.toJson(),
  };
  factory FrameTemplate.fromJson(Object? value) {
    final m = jsonObject(
      value,
      'frame template',
      allowed: const {
        'id',
        'name',
        'marginsMm',
        'contentPaddingMm',
        'strokeWidthMm',
        'zones',
        'titleBlock',
      },
    );
    final result = FrameTemplate(
      id: jsonString(m, 'id', max: 128),
      name: jsonString(m, 'name'),
      marginsMm: FrameMargins.fromJson(m['marginsMm']),
      contentPaddingMm: jsonNumber(m, 'contentPaddingMm'),
      strokeWidthMm: jsonNumber(m, 'strokeWidthMm'),
      zones: FrameZones.fromJson(m['zones']),
      titleBlock: FrameTitleBlock.fromJson(m['titleBlock']),
    );
    result.validate();
    return result;
  }

  void validate() {
    if (!_identifier.hasMatch(id) || !_text(name, 200) || name.trim().isEmpty) {
      _fail('Invalid frame template identity "$id".', 'invalid_frame_template');
    }
    if (![
          marginsMm.left,
          marginsMm.top,
          marginsMm.right,
          marginsMm.bottom,
          contentPaddingMm,
        ].every(_nonnegative) ||
        !_positive(strokeWidthMm, FrameLimits.strokeWidthMm) ||
        !_positive(titleBlock.widthMm) ||
        !_positive(titleBlock.heightMm)) {
      _fail('Invalid dimensions in frame template "$id".');
    }
    final z = zones;
    if (z.columns < 1 ||
        z.columns > FrameLimits.zones ||
        z.rows < 1 ||
        z.rows > FrameLimits.zones ||
        !_positive(z.bandMm) ||
        !_positive(z.tickMm) ||
        z.tickMm > z.bandMm ||
        !_positive(z.fontSizeMm, FrameLimits.fontSizeMm) ||
        z.fontSizeMm > z.bandMm) {
      _fail('Invalid zones in frame template "$id".');
    }
    if (titleBlock.lines.length > FrameLimits.lines ||
        titleBlock.fields.length > FrameLimits.fields) {
      _fail('Too many title block items in "$id".', 'limit_exceeded');
    }
    bool inside(Vec2 p) =>
        p.x.isFinite &&
        p.y.isFinite &&
        p.x >= 0 &&
        p.y >= 0 &&
        p.x <= titleBlock.widthMm &&
        p.y <= titleBlock.heightMm;
    for (final l in titleBlock.lines) {
      if (!inside(l.from) || !inside(l.to) || l.from == l.to)
        _fail('Invalid title block line in "$id".');
    }
    final ids = <String>{};
    var textSize = name.length;
    for (final f in titleBlock.fields) {
      if (!_identifier.hasMatch(f.id) || !ids.add(f.id))
        _fail(
          'Invalid or duplicate frame field ID "${f.id}" in "$id".',
          'invalid_frame_template',
        );
      if (!_positive(f.rectMm.width) ||
          !_positive(f.rectMm.height) ||
          !inside(f.rectMm.topLeft) ||
          !inside(f.rectMm.bottomRight) ||
          !_positive(f.fontSizeMm, FrameLimits.fontSizeMm) ||
          !_positive(f.minFontSizeMm, FrameLimits.fontSizeMm) ||
          f.minFontSizeMm > f.fontSizeMm) {
        _fail('Invalid frame field geometry "$id/${f.id}".');
      }
      validateFrameText(f.text);
      textSize += f.text.length;
    }
    if (textSize > FrameLimits.templateText)
      _fail('Frame template text budget exceeded.', 'limit_exceeded');
  }
}

abstract final class FrameTemplates {
  static const builtinId = 'frame.generic.v1';
  static final builtin = FrameTemplate(
    id: builtinId,
    name: 'Generic',
    titleBlock: FrameTitleBlock(
      widthMm: 180,
      heightMm: 36,
      lines: const [
        FrameLine(Vec2(0, 12), Vec2(180, 12)),
        FrameLine(Vec2(0, 24), Vec2(180, 24)),
        FrameLine(Vec2(110, 12), Vec2(110, 36)),
      ],
      fields: const [
        FrameField(
          id: 'project',
          rectMm: RectMm(x: 2, y: 2, width: 176, height: 8),
          text: '{{project.name}}',
          fontSizeMm: 4,
          bold: true,
        ),
        FrameField(
          id: 'sheet',
          rectMm: RectMm(x: 2, y: 14, width: 106, height: 8),
          text: '{{sheet.name}}',
        ),
        FrameField(
          id: 'page',
          rectMm: RectMm(x: 112, y: 14, width: 66, height: 8),
          text: '{{page.number}} · {{page.index}} / {{page.count}}',
        ),
        FrameField(
          id: 'author',
          rectMm: RectMm(x: 2, y: 26, width: 106, height: 8),
          text: '{{document.drawnBy}}  {{document.issueDate}}',
        ),
        FrameField(
          id: 'revision',
          rectMm: RectMm(x: 112, y: 26, width: 66, height: 8),
          text: '{{document.drawingRevision}}  {{view.scale}}',
        ),
      ],
    ),
  );
}

abstract final class FrameTemplateCodec {
  static const format = 'open-ecad-frame-template';
  static const formatVersion = 1;
  static Map<String, Object?> toJson(FrameTemplate template) {
    template.validate();
    return {
      'format': format,
      'formatVersion': formatVersion,
      'template': template.toJson(),
    };
  }

  static FrameTemplate fromJson(Object? value) {
    final m = jsonObject(
      value,
      'frame template envelope',
      allowed: const {'format', 'formatVersion', 'template'},
    );
    if (m['format'] != format ||
        m['formatVersion'] is! int ||
        m['formatVersion'] != formatVersion) {
      _fail('Unsupported frame template format.', 'unsupported_format');
    }
    return FrameTemplate.fromJson(m['template']);
  }

  static String encode(FrameTemplate template) => jsonEncode(toJson(template));
  static FrameTemplate decode(String text) {
    if (text.length > 1024 * 1024)
      _fail('Frame definition is too large.', 'limit_exceeded');
    return fromJson(jsonDecode(text));
  }
}

const frameBuiltinBindings = <String>{
  'project.name',
  'project.description',
  'sheet.name',
  'sheet.number',
  'sheet.designation',
  'sheet.documentCode',
  'sheet.type',
  'page.number',
  'page.index',
  'page.count',
  'page.inSheet',
  'page.sheetCount',
  'view.scale',
};
final _identifier = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,127}$');
final _documentKey = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$');
final _token = RegExp(r'\{\{([^{}]+)\}\}');

void validateFrameText(String text) {
  if (!_text(text, FrameLimits.text))
    _fail('Frame text exceeds its budget.', 'limit_exceeded');
  for (final match in _token.allMatches(text)) {
    final key = match[1]!;
    if (!frameBuiltinBindings.contains(key) &&
        !(key.startsWith('document.') &&
            _documentKey.hasMatch(key.substring(9)))) {
      _fail('Unknown frame binding "$key".', 'invalid_frame_binding');
    }
  }
  final literal = text.replaceAll(_token, '');
  if (literal.contains('{{') || literal.contains('}}'))
    _fail('Malformed frame binding.', 'invalid_frame_binding');
}

void validateDocumentFields(Map<String, String> fields) {
  var size = 0;
  if (fields.length > FrameLimits.documentFields)
    _fail('Too many document fields.', 'limit_exceeded');
  for (final entry in fields.entries) {
    if (!_documentKey.hasMatch(entry.key) ||
        !_text(entry.value, FrameLimits.text)) {
      _fail(
        'Invalid document field "${entry.key}".',
        'invalid_document_fields',
      );
    }
    size += entry.key.length + entry.value.length;
  }
  if (size > FrameLimits.documentText)
    _fail('Document field text budget exceeded.', 'limit_exceeded');
}

Map<String, String> decodeDocumentFields(Object? value) {
  final m = jsonObject(value, 'document fields');
  if (m.length > FrameLimits.documentFields)
    _fail('Too many document fields.', 'limit_exceeded');
  final fields = m.map(
    (key, value) => MapEntry(key, jsonString(m, key, max: FrameLimits.text)),
  );
  validateDocumentFields(fields);
  return Map.unmodifiable(fields);
}

class ResolvedFrame {
  const ResolvedFrame(
    this.template, {
    this.border = true,
    this.titleBlock = true,
    this.zones = true,
  });
  final FrameTemplate template;
  final bool border, titleBlock, zones;
}

ResolvedFrame? resolveSheetFrame(EcadProject project, Sheet sheet) {
  project.defaultFrame.validate(projectDefault: true);
  sheet.frame.validate();
  final choice =
      sheet.frame.mode == FrameMode.inherit
          ? project.defaultFrame
          : sheet.frame;
  if (choice.mode == FrameMode.none) return null;
  final matches = project.frameTemplates.where(
    (t) => t.id == choice.templateId,
  );
  if (matches.isEmpty)
    _fail(
      'Unknown frame template "${choice.templateId}".',
      'missing_frame_template',
    );
  if (matches.length != 1)
    _fail('Duplicate frame template "${choice.templateId}".', 'duplicate_id');
  final overrides =
      sheet.frame.mode == FrameMode.inherit ? sheet.frame : choice;
  return ResolvedFrame(
    matches.single,
    border: overrides.border ?? choice.border ?? true,
    titleBlock: overrides.titleBlock ?? choice.titleBlock ?? true,
    zones: overrides.zones ?? choice.zones ?? true,
  );
}

class FrameStroke {
  const FrameStroke(this.fromMm, this.toMm, this.widthMm);
  final Vec2 fromMm, toMm;
  final double widthMm;
}

class FrameGeometry {
  FrameGeometry({
    required this.paperRectMm,
    required this.contentRectMm,
    this.borderRectMm,
    this.titleBlockRectMm,
    List<FrameStroke> strokesMm = const [],
    List<FrameField> zoneLabelSlots = const [],
    List<FrameField> titleFieldSlots = const [],
  }) : strokesMm = List.unmodifiable(strokesMm),
       zoneLabelSlots = List.unmodifiable(zoneLabelSlots),
       titleFieldSlots = List.unmodifiable(titleFieldSlots);
  final RectMm paperRectMm, contentRectMm;
  final RectMm? borderRectMm, titleBlockRectMm;
  final List<FrameStroke> strokesMm;
  final List<FrameField> zoneLabelSlots, titleFieldSlots;
}

FrameGeometry layoutFrameGeometry(SizeMm paperSizeMm, ResolvedFrame? frame) {
  if (!_positive(paperSizeMm.width) || !_positive(paperSizeMm.height))
    _fail('Invalid frame paper size.');
  final paper = RectMm(
    x: 0,
    y: 0,
    width: paperSizeMm.width,
    height: paperSizeMm.height,
  );
  if (frame == null)
    return FrameGeometry(paperRectMm: paper, contentRectMm: paper);
  final t = frame.template;
  t.validate();
  final m = t.marginsMm;
  final border = RectMm(
    x: m.left,
    y: m.top,
    width: paper.width - m.left - m.right,
    height: paper.height - m.top - m.bottom,
  );
  final halfStroke = t.strokeWidthMm / 2;
  final minMargin =
      frame.zones
          ? t.zones.bandMm + halfStroke
          : (frame.border ? halfStroke : 0.0);
  if ([m.left, m.top, m.right, m.bottom].any((v) => v < minMargin) ||
      border.width <= 0 ||
      border.height <= 0) {
    _fail('Frame "${t.id}" does not fit the paper margins.');
  }
  final title =
      frame.titleBlock
          ? RectMm(
            x: border.right - t.titleBlock.widthMm,
            y: border.bottom - t.titleBlock.heightMm,
            width: t.titleBlock.widthMm,
            height: t.titleBlock.heightMm,
          )
          : null;
  if (title != null &&
      (title.x < border.x ||
          title.y < border.y ||
          title.x < halfStroke ||
          title.y < halfStroke ||
          title.right + halfStroke > paper.right ||
          title.bottom + halfStroke > paper.bottom))
    _fail('Title block "${t.id}" does not fit the paper.');
  final p = t.contentPaddingMm;
  final content = RectMm(
    x: border.x + p,
    y: border.y + p,
    width: border.width - 2 * p,
    height: (title?.y ?? border.bottom) - p - (border.y + p),
  );
  if (content.width < 1 || content.height < 1)
    _fail('Frame "${t.id}" leaves no usable content rectangle.');
  final strokes = <FrameStroke>[];
  final labels = <FrameField>[];
  void line(Vec2 a, Vec2 b) => strokes.add(FrameStroke(a, b, t.strokeWidthMm));
  void outline(RectMm r) {
    line(r.topLeft, Vec2(r.right, r.y));
    line(Vec2(r.right, r.y), r.bottomRight);
    line(r.bottomRight, Vec2(r.x, r.bottom));
    line(Vec2(r.x, r.bottom), r.topLeft);
  }

  if (frame.border) outline(border);
  if (title != null) {
    outline(title);
    for (final l in t.titleBlock.lines) {
      line(l.from + title.topLeft, l.to + title.topLeft);
    }
  }
  if (frame.zones) {
    final z = t.zones;
    final cw = border.width / z.columns, rh = border.height / z.rows;
    if (cw < z.fontSizeMm || rh < z.fontSizeMm)
      _fail('Frame coordinate zones are too small.');
    void label(String id, String text, RectMm box) => labels.add(
      FrameField(
        id: id,
        rectMm: box,
        text: text,
        fontSizeMm: z.fontSizeMm,
        minFontSizeMm: z.fontSizeMm,
        align: FrameTextAlign.center,
      ),
    );
    for (var i = 0; i < z.columns; i++) {
      final x = border.x + i * cw;
      label(
        'zone.top.$i',
        _column(i),
        RectMm(x: x, y: border.y - z.bandMm, width: cw, height: z.bandMm),
      );
      label(
        'zone.bottom.$i',
        _column(i),
        RectMm(x: x, y: border.bottom, width: cw, height: z.bandMm),
      );
      if (i > 0) {
        line(Vec2(x, border.y - z.tickMm), Vec2(x, border.y));
        line(Vec2(x, border.bottom), Vec2(x, border.bottom + z.tickMm));
      }
    }
    for (var i = 0; i < z.rows; i++) {
      final y = border.y + i * rh;
      label(
        'zone.left.$i',
        '${i + 1}',
        RectMm(
          x: border.x - z.bandMm,
          y: y + (rh - z.bandMm) / 2,
          width: z.bandMm,
          height: z.bandMm,
        ),
      );
      label(
        'zone.right.$i',
        '${i + 1}',
        RectMm(
          x: border.right,
          y: y + (rh - z.bandMm) / 2,
          width: z.bandMm,
          height: z.bandMm,
        ),
      );
      if (i > 0) {
        line(Vec2(border.x - z.tickMm, y), Vec2(border.x, y));
        line(Vec2(border.right, y), Vec2(border.right + z.tickMm, y));
      }
    }
  }
  return FrameGeometry(
    paperRectMm: paper,
    borderRectMm: border,
    titleBlockRectMm: title,
    contentRectMm: content,
    strokesMm: strokes,
    zoneLabelSlots: labels,
    titleFieldSlots:
        title == null
            ? const []
            : t.titleBlock.fields
                .map(
                  (f) => f.copyWith(rectMm: f.rectMm.translated(title.topLeft)),
                )
                .toList(),
  );
}

class FramePageContext {
  const FramePageContext({
    required this.number,
    required this.documentIndex,
    required this.documentCount,
    this.sheetPageIndex = 1,
    this.sheetPageCount = 1,
  });
  final String number;
  final int documentIndex, documentCount, sheetPageIndex, sheetPageCount;
  void validate() {
    if (!_text(number, 1024) ||
        documentIndex < 1 ||
        documentIndex > documentCount ||
        sheetPageIndex < 1 ||
        sheetPageIndex > sheetPageCount ||
        sheetPageCount > documentCount ||
        documentCount > 1000000) {
      _fail('Invalid physical frame page context.', 'invalid_frame_context');
    }
  }
}

class FrameTextSpec {
  const FrameTextSpec({required this.slot, required this.text});
  final FrameField slot;
  final String text;
  String get id => slot.id;
  RectMm get rectMm => slot.rectMm;
  double get fontSizeMm => slot.fontSizeMm;
  double get minFontSizeMm => slot.minFontSizeMm;
  bool get bold => slot.bold;
  FrameTextAlign get align => slot.align;
  FrameTextOverflow get overflow => slot.overflow;
}

class FrameLayout {
  FrameLayout({required this.geometry, required List<FrameTextSpec> texts})
    : texts = List.unmodifiable(texts);
  final FrameGeometry geometry;
  final List<FrameTextSpec> texts;
}

FrameLayout bindFrame(
  FrameGeometry geometry,
  EcadProject project,
  Sheet sheet,
  FramePageContext pageContext,
) {
  pageContext.validate();
  validateDocumentFields(project.documentFields);
  validateDocumentFields(sheet.documentFields);
  final document = {...project.documentFields, ...sheet.documentFields};
  final scale = sheet.mountingView?.scaleDenominator;
  if (scale != null && !_positive(scale, ProjectLimits.maxCoordinate)) {
    _fail('Invalid mounting scale for frame binding.', 'invalid_frame_context');
  }
  final bindings = <String, String>{
    'project.name': project.name,
    'project.description': project.description,
    'sheet.name': sheet.name,
    'sheet.number': sheet.number,
    'sheet.designation': fullPageDesignation(sheet),
    'sheet.documentCode': sheet.documentCode,
    'sheet.type': sheet.type.name,
    'page.number': pageContext.number,
    'page.index': '${pageContext.documentIndex}',
    'page.count': '${pageContext.documentCount}',
    'page.inSheet': '${pageContext.sheetPageIndex}',
    'page.sheetCount': '${pageContext.sheetPageCount}',
    'view.scale':
        scale == null
            ? ''
            : '1:${scale == scale.roundToDouble() ? scale.toInt() : scale}',
  };
  final texts = <FrameTextSpec>[];
  for (final slot in [
    ...geometry.zoneLabelSlots,
    ...geometry.titleFieldSlots,
  ]) {
    validateFrameText(slot.text);
    final buffer = StringBuffer();
    var offset = 0;
    void append(String value) {
      if (buffer.length + value.length > FrameLimits.templateText)
        _fail(
          'Bound frame field "${slot.id}" exceeds text budget.',
          'limit_exceeded',
        );
      buffer.write(value);
    }

    for (final match in _token.allMatches(slot.text)) {
      append(slot.text.substring(offset, match.start));
      final key = match[1]!;
      append(
        key.startsWith('document.')
            ? document[key.substring(9)] ?? ''
            : bindings[key]!,
      );
      offset = match.end;
    }
    append(slot.text.substring(offset));
    texts.add(FrameTextSpec(slot: slot, text: buffer.toString()));
  }
  return FrameLayout(geometry: geometry, texts: texts);
}

RectUnits frameContentUnits(Sheet sheet, FrameGeometry geometry) {
  if (sheet.paperSizeMm.width != geometry.paperRectMm.width ||
      sheet.paperSizeMm.height != geometry.paperRectMm.height ||
      !_positive(sheet.width, ProjectLimits.maxCoordinate) ||
      !_positive(sheet.height, ProjectLimits.maxCoordinate)) {
    _fail('Frame geometry must match the target sheet paper.');
  }
  final transform = SheetTransform(sheet);
  final a = transform.fromPaperMm(geometry.contentRectMm.topLeft);
  final b = transform.fromPaperMm(geometry.contentRectMm.bottomRight);
  return RectUnits(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y);
}

void validateProjectFrames(EcadProject project) {
  if (project.frameTemplates.length > FrameLimits.templates)
    _fail('Too many frame templates.', 'limit_exceeded');
  final ids = <String>{};
  var size = 0;
  for (final template in project.frameTemplates) {
    template.validate();
    if (!ids.add(template.id))
      _fail('Duplicate frame template "${template.id}".', 'duplicate_id');
    size +=
        template.name.length +
        template.titleBlock.fields.fold<int>(0, (n, f) => n + f.text.length);
  }
  void choice(FrameChoice value, {bool projectDefault = false}) {
    value.validate(projectDefault: projectDefault);
    if (value.mode == FrameMode.template && !ids.contains(value.templateId))
      _fail(
        'Unknown frame template "${value.templateId}".',
        'missing_frame_template',
      );
  }

  void fields(Map<String, String> values) {
    validateDocumentFields(values);
    size += values.entries.fold<int>(
      0,
      (n, e) => n + e.key.length + e.value.length,
    );
    if (size > FrameLimits.projectText)
      _fail('Project frame text budget exceeded.', 'limit_exceeded');
  }

  choice(project.defaultFrame, projectDefault: true);
  fields(project.documentFields);
  for (final sheet in project.pages) {
    choice(sheet.frame);
    fields(sheet.documentFields);
    try {
      layoutFrameGeometry(sheet.paperSizeMm, resolveSheetFrame(project, sheet));
    } on EcadException catch (error) {
      throw EcadException(
        'Sheet "${sheet.id}": ${error.message}',
        code: error.code,
      );
    }
  }
}

String _column(int index) {
  var result = '';
  do {
    result = String.fromCharCode(65 + index % 26) + result;
    index = index ~/ 26 - 1;
  } while (index >= 0);
  return result;
}

T _enum<T extends Enum>(Map<String, Object?> m, String key, List<T> values) {
  final text = jsonString(m, key, max: 32);
  return values.firstWhere(
    (v) => v.name == text,
    orElse:
        () =>
            throw EcadException(
              'Unknown $key "$text".',
              code: 'invalid_schema',
            ),
  );
}

bool _text(String value, int max) =>
    value.length <= max && !value.contains('\u0000');
bool _positive(double value, [double max = FrameLimits.dimensionMm]) =>
    value.isFinite && value > 0 && value <= max;
bool _nonnegative(double value) =>
    value.isFinite && value >= 0 && value <= FrameLimits.dimensionMm;
Never _fail(String message, [String code = 'invalid_frame_layout']) =>
    throw EcadException(message, code: code);
