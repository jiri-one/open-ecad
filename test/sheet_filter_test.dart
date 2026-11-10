// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/widgets/sheet_filter.dart';

final _heating = Sheet(
  id: 'heating',
  name: 'Řízení pohonu\r\nJištění motoru',
  number: '012',
  documentCode: 'EL01',
  structure: StructureContext(
    functionPath: ['TECH', 'HEAT'],
    locationPath: ['Dům', 'Přízemí'],
    productPath: ['A1', 'R1'],
  ),
);

void main() {
  test('empty criteria preserve all sheets and whitespace is inactive', () {
    expect(SheetFilter.empty.matches(_heating), isTrue);
    expect(SheetFilter(query: '  ', name: '\n').isActive, isFalse);
  });

  test('partial text ignores Czech accents, case and line breaks', () {
    expect(
      SheetFilter(name: 'rizeni POHONU jisteni').matches(_heating),
      isTrue,
    );
    expect(SheetFilter(query: 'JISTENI MOTORU').matches(_heating), isTrue);
    expect(
      SheetFilter(number: '12', documentCode: 'el').matches(_heating),
      isTrue,
    );
    expect(
      SheetFilter(
        query: '=tech=heat+dum+prizemi-a1-r1&el01/012',
      ).matches(_heating),
      isTrue,
    );
    expect(
      SheetFilter(
        query: '1p',
      ).matches(_heating.copyWith(type: SheetType.singleLine)),
      isTrue,
    );
    expect(SheetFilter(query: '1p').matches(_heating), isFalse);
  });

  test(
    'all populated criteria intersect while selected types form a union',
    () {
      final filter = SheetFilter(
        name: 'pohon',
        number: '012',
        function: '=tech=heat',
        location: 'prizemi',
        product: '-a1-r1',
        documentCode: 'el',
        types: {SheetType.multiLine, SheetType.singleLine},
      );
      expect(filter.matches(_heating), isTrue);
      expect(
        filter.matches(_heating.copyWith(type: SheetType.singleLine)),
        isTrue,
      );
      for (final sheet in [
        _heating.copyWith(name: 'Osvětlení'),
        _heating.copyWith(number: '013'),
        _heating.copyWith(documentCode: 'DOC'),
        _heating.copyWith(type: SheetType.form),
        _heating.copyWith(structure: StructureContext(functionPath: ['WATER'])),
        _heating.copyWith(
          structure: StructureContext(
            functionPath: ['TECH', 'HEAT'],
            locationPath: ['Sklep'],
          ),
        ),
        _heating.copyWith(
          structure: StructureContext(
            functionPath: ['TECH', 'HEAT'],
            locationPath: ['Dům', 'Přízemí'],
            productPath: ['A2'],
          ),
        ),
      ]) {
        expect(filter.matches(sheet), isFalse);
      }
    },
  );

  test('structure criteria handle complete prefixes and individual levels', () {
    expect(
      SheetFilter(
        function: 'TECH HEAT',
        location: '+dum+prizemi',
        product: 'R1',
      ).matches(_heating),
      isTrue,
    );
    expect(
      SheetFilter(
        function: 'HEAT',
      ).matches(_heating.copyWith(structure: const StructureContext.empty())),
      isFalse,
    );
  });

  test(
    'paper format ignores rotation and PDF rounding; orientation is independent',
    () {
      final landscape = _heating.copyWith(
        paperSizeMm: const SizeMm(width: 297.00001, height: 210.00001),
      );
      final portrait = _heating.copyWith(
        paperSizeMm: const SizeMm(width: 210, height: 297),
      );
      final format = sheetPaperFormat(portrait);
      final filter = SheetFilter(paperFormat: format);
      expect(filter.matches(landscape), isTrue);
      expect(filter.matches(portrait), isTrue);
      expect(filter.matches(_heating), isFalse);
      expect(
        SheetFilter(
          paperFormat: format,
          orientation: SheetOrientation.portrait,
        ).matches(landscape),
        isFalse,
      );
      expect(
        SheetFilter(
          paperFormat: format,
          orientation: SheetOrientation.portrait,
        ).matches(portrait),
        isTrue,
      );
      expect(
        SheetFilter(orientation: SheetOrientation.square).matches(
          _heating.copyWith(paperSizeMm: const SizeMm(width: 200, height: 200)),
        ),
        isTrue,
      );
    },
  );

  test('changing quick search retains every detailed criterion', () {
    final filter = SheetFilter(
      name: 'pohon',
      number: '12',
      function: 'heat',
      location: 'prizemi',
      product: 'r1',
      documentCode: 'el',
      types: {SheetType.multiLine},
      paperFormat: sheetPaperFormat(_heating),
      orientation: SheetOrientation.landscape,
    );
    final searched = filter.withQuery('jisteni');
    expect(searched.matches(_heating), isTrue);
    expect(
      searched.withQuery('').matches(_heating.copyWith(name: 'Zásuvky')),
      isFalse,
    );
    expect(
      searched
          .withQuery('')
          .matches(_heating.copyWith(type: SheetType.singleLine)),
      isFalse,
    );
    expect(searched.withQuery('neexistuje').matches(_heating), isFalse);
    expect(searched.withQuery(''), filter);
  });

  test(
    'filter values are immutable and equivalent type sets share cache identity',
    () {
      final types = {SheetType.multiLine, SheetType.singleLine};
      final filter = SheetFilter(types: types);
      types.clear();
      expect(filter.matches(_heating.copyWith(type: SheetType.form)), isFalse);
      expect(() => filter.types.clear(), throwsUnsupportedError);
      final same = SheetFilter(
        types: {SheetType.singleLine, SheetType.multiLine},
      );
      expect(filter, same);
      expect(filter.hashCode, same.hashCode);
    },
  );
}
