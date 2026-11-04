import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

void main() {
  test('natural order stays numeric for labels beyond the integer range', () {
    final labels = ['Q9', 'Q10', 'Q${'1' * 64}', 'Q${'9' * 64}'];
    for (var i = 0; i < labels.length; i++) {
      for (var j = 0; j < labels.length; j++) {
        expect(naturalCompare(labels[i], labels[j]).sign, i.compareTo(j));
      }
    }
    expect(naturalCompare('Q${'0' * 40}9', 'Q10'), lessThan(0));
    expect(naturalCompare('Q${'0' * 40}9', 'Q9'), 0);
    expect(naturalCompare('Q${'0' * 40}', 'Q0'), 0);
  });
}
