// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/foundation.dart';

import 'sheet_types.dart';

typedef SheetPaperFormat = ({double shortSide, double longSide});

enum SheetOrientation {
  landscape('Na šířku'),
  portrait('Na výšku'),
  square('Čtverec');

  const SheetOrientation(this.label);
  final String label;
}

double _roundedMm(double value) => (value * 10).round() / 10;

// PDF page sizes can differ slightly after conversion from points to millimeters.
SheetPaperFormat sheetPaperFormat(Sheet sheet) => (
  shortSide: _roundedMm(
    math.min(sheet.paperSizeMm.width, sheet.paperSizeMm.height),
  ),
  longSide: _roundedMm(
    math.max(sheet.paperSizeMm.width, sheet.paperSizeMm.height),
  ),
);

SheetOrientation sheetOrientation(Sheet sheet) {
  final width = _roundedMm(sheet.paperSizeMm.width);
  final height = _roundedMm(sheet.paperSizeMm.height);
  return width == height
      ? SheetOrientation.square
      : width > height
      ? SheetOrientation.landscape
      : SheetOrientation.portrait;
}

final _whitespace = RegExp(r'\s+');
String _normalize(String value) =>
    foldForSearch(value.trim()).replaceAll(_whitespace, ' ');

String sheetPaperFormatLabel(SheetPaperFormat format) {
  String mm(double value) =>
      value == value.roundToDouble()
          ? value.toInt().toString()
          : value.toStringAsFixed(1).replaceAll('.', ',');
  final prefix = switch (format) {
    (shortSide: 210.0, longSide: 297.0) => 'A4 · ',
    (shortSide: 297.0, longSide: 420.0) => 'A3 · ',
    _ => '',
  };
  return '$prefix${mm(format.shortSide)} × ${mm(format.longSide)} mm';
}

@immutable
class SheetFilter {
  factory SheetFilter({
    String query = '',
    String name = '',
    String number = '',
    String function = '',
    String location = '',
    String product = '',
    String documentCode = '',
    Set<SheetType> types = const {},
    SheetPaperFormat? paperFormat,
    SheetOrientation? orientation,
  }) => SheetFilter._(
    query: query.trim(),
    name: name.trim(),
    number: number.trim(),
    function: function.trim(),
    location: location.trim(),
    product: product.trim(),
    documentCode: documentCode.trim(),
    types: Set.unmodifiable(types),
    paperFormat: paperFormat,
    orientation: orientation,
  );

  SheetFilter._({
    this.query = '',
    this.name = '',
    this.number = '',
    this.function = '',
    this.location = '',
    this.product = '',
    this.documentCode = '',
    this.types = const {},
    this.paperFormat,
    this.orientation,
  });

  static final empty = SheetFilter();
  final String query, name, number, function, location, product, documentCode;
  final Set<SheetType> types;
  final SheetPaperFormat? paperFormat;
  final SheetOrientation? orientation;

  late final _query = _normalize(query);
  late final _name = _normalize(name);
  late final _number = _normalize(number);
  late final _function = _normalize(function);
  late final _location = _normalize(location);
  late final _product = _normalize(product);
  late final _documentCode = _normalize(documentCode);

  SheetFilter withQuery(String value) => SheetFilter(
    query: value,
    name: name,
    number: number,
    function: function,
    location: location,
    product: product,
    documentCode: documentCode,
    types: types,
    paperFormat: paperFormat,
    orientation: orientation,
  );

  int get activeCount =>
      [
        query,
        name,
        number,
        function,
        location,
        product,
        documentCode,
      ].where((value) => value.isNotEmpty).length +
      (types.isEmpty ? 0 : 1) +
      (paperFormat == null ? 0 : 1) +
      (orientation == null ? 0 : 1);
  bool get isActive => activeCount != 0;

  bool _contains(String value, String needle) =>
      needle.isEmpty || _normalize(value).contains(needle);

  bool _path(List<String> path, String sign, String needle) =>
      needle.isEmpty ||
      _contains(
        '${path.join(' ')} ${path.map((part) => '$sign$part').join()}',
        needle,
      );

  bool matches(Sheet sheet) =>
      (types.isEmpty || types.contains(sheet.type)) &&
      (paperFormat == null || sheetPaperFormat(sheet) == paperFormat) &&
      (orientation == null || sheetOrientation(sheet) == orientation) &&
      _contains(sheet.name, _name) &&
      _contains(sheet.number, _number) &&
      _contains(sheet.documentCode, _documentCode) &&
      _path(sheet.structure.functionPath, '=', _function) &&
      _path(sheet.structure.locationPath, '+', _location) &&
      _path(sheet.structure.productPath, '-', _product) &&
      (_query.isEmpty ||
          _contains(
            '${sheet.number} ${sheet.name} ${sheet.type.label}'
            '${sheet.type == SheetType.singleLine ? ' 1P' : ''} ${fullPageDesignation(sheet)}',
            _query,
          ));

  @override
  bool operator ==(Object other) =>
      other is SheetFilter &&
      query == other.query &&
      name == other.name &&
      number == other.number &&
      function == other.function &&
      location == other.location &&
      product == other.product &&
      documentCode == other.documentCode &&
      setEquals(types, other.types) &&
      paperFormat == other.paperFormat &&
      orientation == other.orientation;

  @override
  int get hashCode => Object.hash(
    query,
    name,
    number,
    function,
    location,
    product,
    documentCode,
    Object.hashAllUnordered(types),
    paperFormat,
    orientation,
  );
}
