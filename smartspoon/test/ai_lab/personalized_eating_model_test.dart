// The per-person model: what it learns, what it refuses to learn from, and
// how often it is wrong.
//
// Thresholds in this model were chosen from the simulation below rather than
// by taste, so the simulation is kept as a test — if a change moves the
// false-alarm rate or the learned spread, this fails.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartspoon/features/ai_lab/domain/services/personalized_eating_model.dart';

double _gauss(math.Random r, double mean, double sd) {
  final u1 = 1.0 - r.nextDouble(), u2 = r.nextDouble();
  return mean + sd * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

Future<void> _feed(
  PersonalizedEatingModel m,
  String key,
  double pace, {
  String type = 'Lunch',
  int bites = 20,
}) =>
    m.recordMeal(
      spoonKey: key,
      bites: bites,
      paceBpm: pace,
      durationMinutes: bites / pace,
      tremor: 0.2,
      mealType: type,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PersonalizedEatingModel().resetForTest();
  });

  group('it refuses to learn from meals that are not meals', () {
    test('a two-bite session never becomes a baseline', () async {
      final m = PersonalizedEatingModel();
      await m.recordMeal(
        spoonKey: 'k',
        bites: 2,
        paceBpm: 40,
        durationMinutes: 0.05,
        tremor: -1,
      );
      expect(m.profileFor('k'), isNull,
          reason: 'the old guard was bites <= 0, which let this set the pace');
    });

    test('impossible paces and durations are rejected', () {
      bool ok(int b, double p, double d) =>
          PersonalizedEatingModel.isPlausibleMeal(
              bites: b, paceBpm: p, durationMinutes: d);
      expect(ok(20, 15, 1.5), isTrue);
      expect(ok(20, 500, 1.5), isFalse, reason: '8 bites a second');
      expect(ok(20, 15, 0.1), isFalse, reason: 'a six-second meal');
      expect(ok(1, 15, 2.0), isFalse);
      expect(ok(20, 0, 2.0), isFalse);
      expect(ok(20, double.nan, 2.0), isFalse);
      expect(ok(20, double.infinity, 2.0), isFalse);
    });
  });

  test('one glitched meal cannot take the baseline with it', () async {
    final m = PersonalizedEatingModel();
    final r = math.Random(3);
    for (var i = 0; i < 12; i++) {
      await _feed(m, 'k', _gauss(r, 15, 3).clamp(1.0, 100.0));
    }
    final before = m.profileFor('k')!.avgPaceBpm;

    // Believable enough to pass the plausibility gate, wrong enough to ruin
    // the profile: an EWMA gives every sample weight alpha, so unclamped this
    // single meal would move the baseline by a fifth of the way to 90.
    await _feed(m, 'k', 90, bites: 45);
    final after = m.profileFor('k')!.avgPaceBpm;

    final unclamped = before + PersonalizedEatingModel.alpha * (90 - before);
    expect(after, lessThan(before + 3),
        reason: 'moved $before -> $after; unwinsorised would be $unclamped');
    expect(unclamped, greaterThan(before + 10), reason: 'sanity: the risk is real');
  });

  test('the learned spread matches the real one', () async {
    // The deviation has to be taken against the mean BEFORE the meal moves
    // it. Taken afterwards it shrinks by (1-alpha), understating the spread
    // by ~20% and inflating every judgement that divides by it.
    for (final trueSd in [2.0, 4.0, 7.0]) {
      SharedPreferences.setMockInitialValues({});
      final m = PersonalizedEatingModel()..resetForTest();
      final r = math.Random(42);
      for (var i = 0; i < 60; i++) {
        await _feed(m, 'k', _gauss(r, 15, trueSd).clamp(1.0, 100.0));
      }
      final learned = m.profileFor('k')!.paceStd;
      expect(learned, closeTo(trueSd, trueSd * 0.25),
          reason: 'true $trueSd, learned $learned');
    }
  });

  test('no simulated eater is nagged on a fifth of their meals', () async {
    // The average false-alarm rate was never the problem — the unlucky tail
    // was. Baseline and spread are both estimated, and when both err the same
    // way one user gets flagged constantly. zFlag was chosen as the first
    // value where that stops happening, so this is measured over many
    // simulated eaters rather than one.
    final rates = <double>[];
    for (var seed = 0; seed < 25; seed++) {
      SharedPreferences.setMockInitialValues({});
      final m = PersonalizedEatingModel()..resetForTest();
      final r = math.Random(seed);
      for (var i = 0; i < 40; i++) {
        await _feed(m, 'k', _gauss(r, 15, 4).clamp(1.0, 100.0));
      }
      var fast = 0;
      const trials = 200;
      for (var i = 0; i < trials; i++) {
        final j = m.judgeMeal('k',
            paceBpm: _gauss(r, 15, 4).clamp(1.0, 100.0), mealType: 'Lunch');
        if (j!.verdict == PaceVerdict.faster) fast++;
      }
      rates.add(fast / trials);
    }
    final mean = rates.reduce((a, b) => a + b) / rates.length;
    expect(mean, lessThan(0.06), reason: 'mean false-alarm ${(mean * 100).round()}%');
    expect(rates.every((x) => x <= 0.20), isTrue,
        reason: 'worst eater saw ${(rates.reduce(math.max) * 100).round()}%');
  });

  test('a genuinely faster meal is still caught', () async {
    final m = PersonalizedEatingModel();
    final r = math.Random(11);
    for (var i = 0; i < 40; i++) {
      await _feed(m, 'k', _gauss(r, 15, 2).clamp(1.0, 100.0));
    }
    var caught = 0;
    const trials = 300;
    for (var i = 0; i < trials; i++) {
      final j = m.judgeMeal('k',
          paceBpm: _gauss(r, 22.5, 2).clamp(1.0, 100.0), mealType: 'Lunch');
      if (j!.verdict == PaceVerdict.faster) caught++;
    }
    expect(caught / trials, greaterThan(0.85));
  });

  group('meal types are judged separately', () {
    test('a brand-new meal type borrows the overall baseline', () async {
      final m = PersonalizedEatingModel();
      for (var i = 0; i < 10; i++) {
        await _feed(m, 'k', 15, type: 'Lunch');
      }
      final p = m.profileFor('k')!;
      expect(p.baselinePaceFor('Dinner'), closeTo(p.avgPaceBpm, 0.001),
          reason: 'never seen Dinner, so it must not invent a baseline');
    });

    test('an established meal type uses its own pace', () async {
      final m = PersonalizedEatingModel();
      // Slow dinners, brisk breakfasts.
      for (var i = 0; i < 15; i++) {
        await _feed(m, 'k', 10, type: 'Dinner');
        await _feed(m, 'k', 24, type: 'Breakfast');
      }
      final p = m.profileFor('k')!;
      expect(p.baselinePaceFor('Dinner'),
          lessThan(p.baselinePaceFor('Breakfast')),
          reason: 'the two meal types must not collapse to one number');
      // And a brisk breakfast is not scolded for being unlike a dinner.
      final j = m.judgeMeal('k', paceBpm: 24, mealType: 'Breakfast');
      expect(j!.verdict, isNot(PaceVerdict.faster));
    });

    test('one reading of a meal type is pulled toward the overall mean', () async {
      final m = PersonalizedEatingModel();
      for (var i = 0; i < 12; i++) {
        await _feed(m, 'k', 15, type: 'Lunch');
      }
      await _feed(m, 'k', 40, type: 'Dinner'); // a single odd dinner
      final p = m.profileFor('k')!;
      final dinner = p.baselinePaceFor('Dinner');
      expect(dinner, greaterThan(p.avgPaceBpm));
      expect(dinner, lessThan(30),
          reason: 'one reading must not become the whole baseline');
    });
  });

  group('it says nothing until it can say something true', () {
    test('no judgement before there is history', () async {
      final m = PersonalizedEatingModel();
      expect(m.judgeMeal('k', paceBpm: 20), isNull);
      await _feed(m, 'k', 15);
      expect(m.judgeMeal('k', paceBpm: 20), isNull);
      expect(m.feedbackForMeal('k', paceBpm: 20), isNull);
    });

    test('it unlocks once the history supports it', () async {
      final m = PersonalizedEatingModel();
      final r = math.Random(7);
      int? unlocked;
      for (var i = 1; i <= 12; i++) {
        await _feed(m, 'k', _gauss(r, 15, 3).clamp(1.0, 100.0));
        if (unlocked == null && m.profileFor('k')!.canPersonalize) unlocked = i;
      }
      expect(unlocked, isNotNull);
      expect(unlocked, lessThanOrEqualTo(8),
          reason: 'the old gate was 20 meals, far longer than the maths needs');
      expect(m.feedbackForMeal('k', paceBpm: 15), isNotNull);
    });

    test('confidence saturates, because an EWMA keeps forgetting', () async {
      final m = PersonalizedEatingModel();
      for (var i = 0; i < 60; i++) {
        await _feed(m, 'k', 15);
      }
      expect(m.profileFor('k')!.confidence, 1.0);
      expect(m.profileFor('k')!.confidence, lessThanOrEqualTo(1.0));
    });
  });

  test('profiles stay separate per spoon', () async {
    final m = PersonalizedEatingModel();
    for (var i = 0; i < 10; i++) {
      await _feed(m, 'spoon-a', 10);
      await _feed(m, 'spoon-b', 25);
    }
    expect(m.profileFor('spoon-a')!.avgPaceBpm,
        lessThan(m.profileFor('spoon-b')!.avgPaceBpm));
  });

  test('a profile saved before this version still loads', () {
    // No paceUpdates and no byMealType. Assuming zero updates would reset a
    // long-standing user to "still learning".
    final p = PersonalizedProfile.fromJson({
      'spoonKey': 'k',
      'mealCount': 30,
      'avgPaceBpm': 14.0,
      'paceVar': 9.0,
      'updatedAt': DateTime.now().toIso8601String(),
    });
    expect(p.mealCount, 30);
    expect(p.paceUpdates, 29);
    expect(p.canPersonalize, isTrue);
    expect(p.byMealType, isEmpty);
    expect(p.baselinePaceFor('Lunch'), 14.0);
  });

  test('meal-type buckets match how meals are labelled', () {
    expect(PersonalizedEatingModel.mealTypeForHour(8), 'Breakfast');
    expect(PersonalizedEatingModel.mealTypeForHour(12), 'Lunch');
    expect(PersonalizedEatingModel.mealTypeForHour(16), 'Snack');
    expect(PersonalizedEatingModel.mealTypeForHour(20), 'Dinner');
  });
}
