// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

void main() {
  for (final axis in [0, 1]) {
    for (final overlap in [0.0, 1.42e-14, 1e-10, .002]) {
      test('mounting overlap on axis $axis at $overlap mm', () {
        final p = EcadProject(
          id: 'p',
          name: 'Contact geometry',
          pages: [Sheet(id: 's', name: 'Sheet', number: '01')],
          components: [
            for (var i = 0; i < 2; i++)
              Component(
                id: 'c$i',
                designation: '-T$i',
                mountingSizeOverrideMm: const DimensionsMm(width: 8, height: 8),
              ),
          ],
          mountingLayouts: [
            MountingLayout(
              id: 'layout',
              name: 'Panel',
              widthMm: 80,
              heightMm: 80,
              placements: [
                const MountingPlacement(
                  id: 'a',
                  componentId: 'c0',
                  centerMm: Vec2(20, 20),
                ),
                MountingPlacement(
                  id: 'b',
                  componentId: 'c1',
                  centerMm:
                      axis == 0
                          ? Vec2(28 - overlap, 20)
                          : Vec2(20, 28 - overlap),
                ),
              ],
            ),
          ],
        );
        requireValidProject(p);
        expect(
          validateProject(p).where((d) => d.code == 'mounting_overlap'),
          hasLength(overlap > 1e-8 ? 1 : 0),
        );
      });
    }
  }
}
