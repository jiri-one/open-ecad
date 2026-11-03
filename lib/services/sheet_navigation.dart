// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';

int compareSheetDesignations(Sheet a, Sheet b) {
  final left = fullPageDesignation(a), right = fullPageDesignation(b);
  final result = naturalCompare(left, right);
  return result != 0
      ? result
      : left != right
      ? left.compareTo(right)
      : a.id.compareTo(b.id);
}

List<Sheet> orderedSheets(
  Iterable<Sheet> sheets, {
  StructureAspect first = StructureAspect.function,
}) {
  final aspects = [first, ...StructureAspect.values.where((a) => a != first)];
  return sheets.toList()..sort((a, b) {
    for (final aspect in aspects) {
      final left = a.structure.paths[aspect.index];
      final right = b.structure.paths[aspect.index];
      for (var i = 0; i < left.length && i < right.length; i++) {
        final result = naturalCompare(left[i], right[i]);
        if (result != 0) return result;
        final exact = left[i].compareTo(right[i]);
        if (exact != 0) return exact;
      }
      final length = left.length.compareTo(right.length);
      if (length != 0) return length;
    }
    return compareSheetDesignations(a, b);
  });
}
