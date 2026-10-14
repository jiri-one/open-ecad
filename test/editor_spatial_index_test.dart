import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/editor/spatial_index.dart';

void main() {
  test(
    'spatial query excludes nearby cells, deduplicates and moves entries',
    () {
      final index = SpatialIndex<String>(cellSize: 100);
      index.insert('wire', const Rect.fromLTWH(-150, -20, 350, 40));
      index.insert('device', const Rect.fromLTWH(5, 5, 10, 10));
      index.insert('distant', const Rect.fromLTWH(90, 90, 4, 4));
      expect(index.query(const Rect.fromLTWH(0, 0, 30, 30)), {
        'wire',
        'device',
      });
      index.insert('device', const Rect.fromLTWH(800, 800, 10, 10));
      expect(index.query(const Rect.fromLTWH(0, 0, 30, 30)), {'wire'});
      index.remove('wire');
      expect(index.query(const Rect.fromLTWH(-200, -50, 500, 100)), isEmpty);
      expect(index.length, 2);
    },
  );

  test('very large valid coordinates do not allocate millions of cells', () {
    final index = SpatialIndex<String>();
    index.insert(
      'huge',
      const Rect.fromLTRB(-1000000, -1000000, 1000000, 1000000),
    );
    index.insert('outside', const Rect.fromLTWH(1000001, 1000001, 10, 10));
    expect(index.query(const Rect.fromLTWH(0, 0, 100, 100)), {'huge'});
    expect(
      index.query(const Rect.fromLTRB(-1000000, -1000000, 1000000, 1000000)),
      {'huge'},
    );
    index.remove('huge');
    expect(index.query(const Rect.fromLTWH(0, 0, 100, 100)), isEmpty);
  });

  test('wire hit distance clamps to endpoints and supports point segments', () {
    expect(
      distanceToSegment(const Offset(4, 3), Offset.zero, const Offset(8, 0)),
      3,
    );
    expect(
      distanceToSegment(const Offset(11, 4), Offset.zero, const Offset(8, 0)),
      5,
    );
    expect(distanceToSegment(const Offset(3, 4), Offset.zero, Offset.zero), 5);
  });
}
