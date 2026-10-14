import 'dart:ui';

/// A uniform spatial grid used for drawing, selection, and pointer hit tests.
/// Long wires may occupy several cells; query results contain each item once.
class SpatialIndex<T> {
  SpatialIndex({this.cellSize = 128});

  final double cellSize;
  final Map<(int, int), Set<T>> _cells = {};
  final Map<T, Rect> _bounds = {};
  final Set<T> _largeItems = {};
  static const _maxCellsPerItem = 4096;

  int get length => _bounds.length;

  void insert(T item, Rect bounds) {
    remove(item);
    _bounds[item] = bounds;
    if (_cellCount(bounds) > _maxCellsPerItem) {
      _largeItems.add(item);
      return;
    }
    for (final cell in _coveredCells(bounds)) {
      (_cells[cell] ??= <T>{}).add(item);
    }
  }

  void remove(T item) {
    final bounds = _bounds.remove(item);
    if (bounds == null) return;
    if (_largeItems.remove(item)) return;
    for (final cell in _coveredCells(bounds)) {
      final items = _cells[cell];
      items?.remove(item);
      if (items?.isEmpty ?? false) _cells.remove(cell);
    }
  }

  Set<T> query(Rect area) {
    if (area.isEmpty) return {};
    if (_cellCount(area) > _maxCellsPerItem) {
      return _bounds.entries
          .where((entry) => entry.value.overlaps(area))
          .map((entry) => entry.key)
          .toSet();
    }
    final candidates = {..._largeItems};
    for (final cell in _coveredCells(area)) {
      candidates.addAll(_cells[cell] ?? <T>{});
    }
    candidates.removeWhere((item) => !_bounds[item]!.overlaps(area));
    return candidates;
  }

  int _cellCount(Rect rect) =>
      ((rect.right / cellSize).floor() - (rect.left / cellSize).floor() + 1) *
      ((rect.bottom / cellSize).floor() - (rect.top / cellSize).floor() + 1);

  Iterable<(int, int)> _coveredCells(Rect rect) sync* {
    final minX = (rect.left / cellSize).floor();
    final maxX = (rect.right / cellSize).floor();
    final minY = (rect.top / cellSize).floor();
    final maxY = (rect.bottom / cellSize).floor();
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        yield (x, y);
      }
    }
  }
}

/// Distance from a point to a finite line segment, including zero-length ones.
double distanceToSegment(Offset point, Offset start, Offset end) {
  final delta = end - start;
  final lengthSquared = delta.dx * delta.dx + delta.dy * delta.dy;
  if (lengthSquared == 0) return (point - start).distance;
  final relative = point - start;
  final fraction = ((relative.dx * delta.dx + relative.dy * delta.dy) /
          lengthSquared)
      .clamp(0.0, 1.0);
  return (point - (start + delta * fraction)).distance;
}
