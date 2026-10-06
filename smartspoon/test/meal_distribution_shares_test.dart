// A distribution has to be taken over what it is drawing.
//
// Reported from a real build: with the meal filter on "Snacks", the Meal
// Distribution card read "Lunch 51 bites (232%)" above "Snacks 22 bites
// (100%)", and the Lunch bar was drawn wider than the card holding it,
// because the percentage went straight into a FractionallySizedBox.
// 51/22 = 232% — the denominator was the FILTERED total, not the total of
// the meals on screen.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/insights/presentation/screens/bite_history_page.dart';

void main() {
  test('the exact numbers from the reported screen', () {
    final shares = mealDistributionShares({
      'Lunch': 51,
      'Snacks': 22,
      'Breakfast': 0,
      'Dinner': 0,
    });
    expect(shares['Lunch']!, closeTo(69.9, 0.1));
    expect(shares['Snacks']!, closeTo(30.1, 0.1));
    expect(shares['Breakfast'], 0.0);
    expect(shares['Dinner'], 0.0);
  });

  test('no share can exceed 100', () {
    for (final m in [
      {'Lunch': 51, 'Snacks': 22},
      {'Lunch': 1},
      {'A': 999999, 'B': 1},
    ]) {
      for (final v in mealDistributionShares(m).values) {
        expect(v, lessThanOrEqualTo(100.0), reason: '$m');
        expect(v, greaterThanOrEqualTo(0.0), reason: '$m');
      }
    }
  });

  test('shares sum to 100 whenever there are any bites', () {
    for (final m in [
      {'Lunch': 51, 'Snacks': 22},
      {'Breakfast': 3, 'Lunch': 3, 'Snacks': 3, 'Dinner': 3},
      {'Dinner': 7},
    ]) {
      final sum = mealDistributionShares(m).values.fold<double>(0, (a, b) => a + b);
      expect(sum, closeTo(100.0, 0.001), reason: '$m');
    }
  });

  test('a single meal is the whole distribution', () {
    expect(mealDistributionShares({'Snacks': 22})['Snacks'], 100.0);
  });

  test('empty and all-zero input do not divide by zero', () {
    expect(mealDistributionShares(const {}), isEmpty);
    final z = mealDistributionShares({'Lunch': 0, 'Snacks': 0});
    expect(z.values, everyElement(0.0));
    expect(z.values.any((v) => v.isNaN), isFalse);
  });

  test('negative counts cannot drag a share out of range', () {
    // Defensive: a bad row should not produce a bar wider than its track.
    for (final v in mealDistributionShares({'Lunch': 10, 'Snacks': -5}).values) {
      expect(v, inInclusiveRange(0.0, 100.0));
      expect(v.isNaN, isFalse);
    }
  });
}
