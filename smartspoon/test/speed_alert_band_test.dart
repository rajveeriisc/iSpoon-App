// The live "eating too fast" alert has to fire on this eater, not on an
// average one.
//
// It used to arm at a flat 25 bites/min for everybody, and quote "aim for
// <20" in the message. Two people that threshold is simply wrong for:
//
//   - a brisk eater whose ordinary lunch runs at 28 bpm would be scolded at
//     every single meal, which trains them to dismiss the alert;
//   - a slow eater whose ordinary pace is 8 bpm could eat at 20 — two and a
//     half times their normal, the exact event worth flagging — and never
//     cross it.
//
// The band is now baseline + z*sigma against the per-meal-type baseline the
// model has learned, and these tests pin both ends plus the fallback that
// applies before the model can personalize.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/services/personalized_eating_model.dart';
import 'package:smartspoon/features/insights/domain/services/unified_data_service.dart';

/// 13:00 — "Lunch" under PersonalizedEatingModel.mealTypeForHour.
final _lunchtime = DateTime(2026, 10, 9, 13);

PersonalizedProfile _profile({
  required double pace,
  required double paceVar,
  int meals = 12,
  Map<String, MealTypeStats>? byMealType,
}) =>
    PersonalizedProfile(
      spoonKey: 'spoon-1',
      mealCount: meals,
      avgPaceBpm: pace,
      paceVar: paceVar,
      paceUpdates: meals - 1,
      // A profile is only personalised once its meals span several days.
      distinctDays: meals,
      byMealType: byMealType,
    );

void main() {
  test('no profile at all falls back to the fixed guide', () {
    final band = UnifiedDataService.speedAlertBandFor(null, at: _lunchtime);
    expect(band.arm, 25.0);
    expect(band.clear, 18.0);
    // It must not imply a personal reading it does not have.
    expect(band.reference, contains('general guide'));
    expect(band.reference.toLowerCase(), isNot(contains('your usual')));
  });

  test('a profile too new to personalize still uses the fixed guide', () {
    final young = _profile(pace: 9, paceVar: 4, meals: 3);
    expect(young.canPersonalize, isFalse);
    final band = UnifiedDataService.speedAlertBandFor(young, at: _lunchtime);
    expect(band.arm, 25.0);
    expect(band.reference, contains('general guide'));
  });

  group('once personalized', () {
    test('the slow eater is reachable: 20 bpm now fires', () {
      // 8 bpm usual, sigma 2 → arms at 8 + 2*2 = 12.
      final slow = _profile(pace: 8, paceVar: 4);
      expect(slow.canPersonalize, isTrue);
      final band = UnifiedDataService.speedAlertBandFor(slow, at: _lunchtime);
      expect(band.arm, closeTo(12.0, 0.01));
      expect(20.0, greaterThan(band.arm),
          reason: 'under the old flat 25 this person could never trip it');
    });

    test('the brisk eater is not nagged: their ordinary 28 stays quiet', () {
      // 28 bpm usual, sigma 3 → arms at 34.
      final brisk = _profile(pace: 28, paceVar: 9);
      final band = UnifiedDataService.speedAlertBandFor(brisk, at: _lunchtime);
      expect(band.arm, closeTo(34.0, 0.01));
      expect(28.0, lessThan(band.arm),
          reason: 'the old flat 25 fired on every meal this person ate');
    });

    test('hysteresis survives: clear sits below arm, above baseline', () {
      final p = _profile(pace: 15, paceVar: 9);
      final band = UnifiedDataService.speedAlertBandFor(p, at: _lunchtime);
      expect(band.clear, lessThan(band.arm));
      expect(band.clear, greaterThan(15.0),
          reason: 'clearing at or below the baseline would re-arm constantly');
      // Same gap the fixed pair had, expressed in this person's spread.
      expect(band.arm - band.clear, closeTo(3.0, 0.01));
    });

    test('a tiny measured spread is floored, not trusted', () {
      // paceVar 0 would put arm == clear == baseline and fire on every bite.
      final p = _profile(pace: 12, paceVar: 0);
      final band = UnifiedDataService.speedAlertBandFor(p, at: _lunchtime);
      final floor = PersonalizedEatingModel.paceStdFloor;
      expect(band.arm,
          closeTo(12 + PersonalizedEatingModel.zFlag * floor, 0.01));
      expect(band.arm, greaterThan(band.clear));
    });

    test('the band follows the meal type, not one daily average', () {
      // Dinner measured much faster than this person's overall mean. The
      // threshold at dinner has to move with it, or dinner trips on what is
      // normal for dinner.
      final p = _profile(
        pace: 12,
        paceVar: 4,
        byMealType: {
          'Dinner': MealTypeStats(n: 8, meanPace: 22),
          'Lunch': MealTypeStats(n: 8, meanPace: 11),
        },
      );
      final lunch = UnifiedDataService.speedAlertBandFor(p, at: _lunchtime);
      final dinner = UnifiedDataService.speedAlertBandFor(
        p,
        at: DateTime(2026, 10, 9, 20),
      );
      expect(dinner.arm, greaterThan(lunch.arm));
      expect(dinner.reference, contains('dinner'));
      expect(lunch.reference, contains('lunch'));
    });

    test('the message quotes the baseline it judged against', () {
      final p = _profile(pace: 10, paceVar: 4);
      final band = UnifiedDataService.speedAlertBandFor(p, at: _lunchtime);
      expect(band.reference, contains('your usual'));
      // Partial pooling pulls an unseen meal type to the global mean, so the
      // figure quoted is the global 10 here.
      expect(band.reference, contains('10'));
      expect(band.reference, isNot(contains('aim for')));
    });
  });
}
