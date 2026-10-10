// Whole-pipeline replay of two real meals. The shipped model was trained on
// these people, so this guards the pipeline, not generalisation — held-out
// accuracy is the trainer's leave-one-person-out report.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/eating_engine.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/handedness.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/meal_tracker.dart';

import 'ai_lab_fixtures.dart';

void main() {
  final model = loadModel();
  final golden = loadGolden();

  for (final label in fixtureLabels) {
    test('$label: one steady meal of about 20 bites, right hand', () {
      final rows =
          loadFixture((golden[label] as Map<String, dynamic>)['file'] as String);
      final engine = EatingEngine(model);
      var mealStartedAt = -1;
      for (var r = 0; r < rows.length; r++) {
        feedRow(engine, rows[r]);
        if (mealStartedAt < 0 && engine.tracker.inMeal) mealStartedAt = r;
      }
      expect(mealStartedAt, greaterThan(0), reason: 'meal never started');

      final last = DateTime.fromMillisecondsSinceEpoch(rows.last.ts);
      final meal = engine.tick(last.add(const Duration(minutes: 3, seconds: 1)));
      expect(meal, isNotNull);
      expect(meal!.bites.length, inInclusiveRange(18, 22));
      expect(meal.reason, MealEndReason.timeout);
      // 85, not 90. steadyPct now counts a window as unsteady if EITHER the
      // narrowband tremor test or the new shake index fires, and the shake
      // threshold is deliberately the 99th percentile of real eating — so
      // about 1% of windows in any ordinary meal trip it by construction.
      // Both fixtures sit at exactly that rate (typical_eater 1.0%,
      // slow_eater 1.8%), the same as the 874 windows of real recordings the
      // threshold was derived from, so this is the designed false-alarm rate
      // showing up, not a regression. typical_eater was already at 89.9 under
      // the old metric; one additional flagged window moved it to 88.8.
      expect(meal.steadyPct, greaterThanOrEqualTo(85));
      expect(engine.voter.detected, Hand.right);
      expect(engine.tracker.phase, MealPhase.finished);
    });
  }
}
