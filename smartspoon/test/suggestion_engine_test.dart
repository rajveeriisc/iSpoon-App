// Suggestions must come from measurements, or not come at all.
//
// What this replaces: a widget that printed "Great progress! Tremor decreased
// this week." and an eating-speed tip on every render, whatever the person
// had done, while being handed real TrendData it never read.
//
// So the tests that matter most here are the NEGATIVE ones — that the engine
// stays quiet when the data cannot support a claim. A suggestion that is not
// backed by a measurement is worse than silence, because it teaches people to
// ignore the ones that are real.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/core/models/bite.dart';
import 'package:smartspoon/core/models/meal.dart';
import 'package:smartspoon/features/ai_lab/domain/services/personalized_eating_model.dart';
import 'package:smartspoon/features/insights/domain/meal_report.dart';
import 'package:smartspoon/features/insights/domain/suggestion_engine.dart';

final _start = DateTime(2026, 10, 9, 13, 0, 0);

MealReport mealAt(
  List<double> offsetsSec, {
  String type = 'Lunch',
  List<double?>? steady,
  List<double?>? temps,
  DateTime? start,
}) {
  final s = start ?? _start;
  final bites = <Bite>[];
  for (var i = 0; i < offsetsSec.length; i++) {
    bites.add(Bite(
      mealUuid: 'm',
      timestamp: s.add(Duration(milliseconds: (offsetsSec[i] * 1000).round())),
      sequenceNumber: i + 1,
      steadyPct: steady == null ? null : steady[i],
      foodTempC: temps == null ? null : temps[i],
    ));
  }
  final last = offsetsSec.isEmpty ? 0.0 : offsetsSec.last;
  return MealReport.from(
    meal: Meal(
      userId: 'u',
      startedAt: s,
      endedAt: s.add(Duration(seconds: last.round())),
      mealType: type,
      totalBites: offsetsSec.length,
      durationMinutes: last / 60.0,
    ),
    bites: bites,
  );
}

/// An even meal of [n] bites at [gap] seconds apart.
MealReport evenMeal(int n, double gap, {String type = 'Lunch', DateTime? start}) =>
    mealAt([for (var i = 0; i < n; i++) i * gap], type: type, start: start);

/// A profile built by feeding the real model, so canPersonalize and the
/// baselines are whatever the production code actually produces.
Future<PersonalizedProfile> profileOf(
  List<double> paces, {
  String type = 'Lunch',
}) async {
  final m = PersonalizedEatingModel()..resetForTest();
  var day = 0;
  for (final p in paces) {
    await m.recordMeal(
      spoonKey: 'k',
      bites: 20,
      paceBpm: p,
      durationMinutes: 20 / p,
      tremor: 0.2,
      mealType: type,
      // One meal a day: same-day meals alone do not unlock personalisation.
      at: DateTime(2026, 1, 1).add(Duration(days: day++)),
    );
  }
  return m.profileFor('k')!;
}

Set<String> idsOf(List<Suggestion> s) => s.map((x) => x.id).toSet();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('it refuses to invent encouragement', () {
    test('no meals at all: says so, praises nothing', () {
      final s = SuggestionEngine.build(recentMeals: const []);
      expect(s, hasLength(1));
      expect(s.single.id, 'no_data');
      expect(s.single.kind, SuggestionKind.learning);
      expect(s.map((x) => x.kind), isNot(contains(SuggestionKind.praise)));
    });

    test('a meal too short to measure counts as no data', () {
      // Two bites cannot give a rhythm, a trend or a pace.
      final s = SuggestionEngine.build(recentMeals: [mealAt([0, 10])]);
      expect(s.single.id, 'no_data');
    });

    test('one meal and no profile yields no pace judgement', () {
      final s = SuggestionEngine.build(recentMeals: [evenMeal(10, 10)]);
      expect(idsOf(s), isNot(contains('pace_fast_vs_self')));
      expect(idsOf(s), isNot(contains('pace_slow_vs_self')));
      expect(idsOf(s), isNot(contains('pace_on_baseline')));
    });

    test('the retired hardcoded claims never appear', () {
      final s = SuggestionEngine.build(recentMeals: [evenMeal(12, 9)]);
      for (final x in s) {
        expect(x.body, isNot(contains('Great progress')));
        expect(x.body, isNot(contains('Tremor decreased this week')));
      }
    });

    test('every suggestion carries its evidence', () {
      final s = SuggestionEngine.build(recentMeals: [
        for (var i = 0; i < 6; i++)
          evenMeal(12, 9, start: _start.subtract(Duration(days: i))),
      ]);
      expect(s, isNotEmpty);
      for (final x in s) {
        expect(x.evidence, isNotEmpty, reason: '${x.id} has no evidence');
        expect(x.title, isNotEmpty);
        expect(x.body, isNotEmpty);
      }
    });
  });

  group('pace against the person own baseline', () {
    test('a genuinely faster meal is flagged', () async {
      // Baseline ~6 bites/min (10 s gaps); this meal is 20 at 3 s gaps.
      final p = await profileOf(List.filled(12, 6.0));
      final s = SuggestionEngine.build(
        recentMeals: [evenMeal(20, 3)],
        profile: p,
      );
      expect(idsOf(s), contains('pace_fast_vs_self'));
      final hit = s.firstWhere((x) => x.id == 'pace_fast_vs_self');
      expect(hit.kind, SuggestionKind.nudge);
      expect(hit.evidence, contains('z='));
    });

    test('an ordinary meal is not scolded', () async {
      final p = await profileOf(List.filled(12, 6.0));
      final s = SuggestionEngine.build(
        recentMeals: [evenMeal(12, 10)],
        profile: p,
      );
      expect(idsOf(s), isNot(contains('pace_fast_vs_self')));
    });

    test('it stays silent while the model is still learning', () async {
      final p = await profileOf([6.0, 6.0]); // below minMealsToPersonalize
      expect(p.canPersonalize, isFalse);
      final s = SuggestionEngine.build(
        recentMeals: [evenMeal(20, 3)],
        profile: p,
      );
      expect(idsOf(s), isNot(contains('pace_fast_vs_self')));
      expect(idsOf(s), contains('still_learning'));
    });
  });

  group('satiation, gated on the fit being believable', () {
    test('a decelerating meal is praised', () {
      final offs = <double>[0];
      var g = 5.0;
      for (var i = 0; i < 11; i++) {
        offs.add(offs.last + g);
        g += 2.0;
      }
      final s = SuggestionEngine.build(recentMeals: [mealAt(offs)]);
      expect(idsOf(s), contains('satiation_present'));
    });

    test('an accelerating meal is nudged', () {
      final offs = <double>[0];
      var g = 26.0;
      for (var i = 0; i < 11; i++) {
        offs.add(offs.last + g);
        g -= 2.0;
      }
      final s = SuggestionEngine.build(recentMeals: [mealAt(offs)]);
      expect(idsOf(s), contains('satiation_absent'));
    });

    test('a meal the quadratic cannot describe produces no satiation claim', () {
      // Speeds up then slows down: one sign of curvature cannot fit it, so
      // rSquared drops and the engine must not report either direction.
      final offs = <double>[0];
      for (final g in [20.0, 16, 12, 8, 4, 4, 8, 12, 16, 20, 24]) {
        offs.add(offs.last + g);
      }
      final r = mealAt(offs);
      expect(r.intakeCurve!.isTrustworthy, isFalse);
      final s = SuggestionEngine.build(recentMeals: [r]);
      expect(idsOf(s), isNot(contains('satiation_present')));
      expect(idsOf(s), isNot(contains('satiation_absent')));
    });

    test('too few bites to fit: silent', () {
      final s = SuggestionEngine.build(recentMeals: [evenMeal(4, 10)]);
      expect(idsOf(s), isNot(contains('satiation_present')));
      expect(idsOf(s), isNot(contains('satiation_absent')));
    });
  });

  group('rules fire only when the measurement is there', () {
    test('pauses are reported with the real longest break', () {
      final s = SuggestionEngine.build(
        recentMeals: [mealAt([0, 8, 16, 24, 200, 208, 216, 224])],
      );
      expect(idsOf(s), contains('pauses'));
      expect(s.firstWhere((x) => x.id == 'pauses').evidence, contains('176s'));
    });

    test('an unbroken meal reports no pauses', () {
      final s = SuggestionEngine.build(recentMeals: [evenMeal(12, 9)]);
      expect(idsOf(s), isNot(contains('pauses')));
    });

    test('a declining hand is called out, a steady one is not', () {
      final declining = SuggestionEngine.build(recentMeals: [
        mealAt([0, 30, 60, 90, 120, 150],
            steady: [98.0, 95.0, 92.0, 70.0, 66.0, 62.0]),
      ]);
      expect(idsOf(declining), contains('steadiness_declined'));

      final flat = SuggestionEngine.build(recentMeals: [
        mealAt([0, 30, 60, 90, 120, 150],
            steady: [90.0, 91.0, 89.0, 90.0, 92.0, 90.0]),
      ]);
      expect(idsOf(flat), isNot(contains('steadiness_declined')));
    });

    test('no steadiness readings means no steadiness claim', () {
      final s = SuggestionEngine.build(recentMeals: [evenMeal(10, 20)]);
      expect(idsOf(s), isNot(contains('steadiness_declined')));
    });

    test('cooling is raised only when it is substantial', () {
      final cooled = SuggestionEngine.build(recentMeals: [
        mealAt([0, 60, 120, 180, 240],
            temps: [64.0, 58.0, 52.0, 47.0, 43.0]),
      ]);
      expect(idsOf(cooled), contains('food_cooled'));

      final barely = SuggestionEngine.build(recentMeals: [
        mealAt([0, 60, 120, 180, 240],
            temps: [55.0, 54.0, 53.0, 52.0, 51.0]),
      ]);
      expect(idsOf(barely), isNot(contains('food_cooled')));
    });

    test('no temperature readings means no temperature claim', () {
      final s = SuggestionEngine.build(recentMeals: [evenMeal(10, 20)]);
      expect(idsOf(s), isNot(contains('food_cooled')));
    });
  });

  group('trend across meals', () {
    List<MealReport> series(List<double> gaps) => [
          // newest first, which is the order the engine documents
          for (var i = 0; i < gaps.length; i++)
            evenMeal(12, gaps[i], start: _start.subtract(Duration(days: i))),
        ];

    test('speeding up across meals is flagged', () {
      // newest has the SHORTEST gaps, i.e. fastest
      final s = SuggestionEngine.build(recentMeals: series([4, 6, 8, 10, 12]));
      expect(idsOf(s), contains('trend_speeding'));
    });

    test('slowing down across meals is praised', () {
      final s = SuggestionEngine.build(recentMeals: series([12, 10, 8, 6, 4]));
      expect(idsOf(s), contains('trend_slowing'));
    });

    test('a flat run produces no trend claim', () {
      final s = SuggestionEngine.build(recentMeals: series([9, 9, 9, 9, 9]));
      expect(idsOf(s), isNot(contains('trend_speeding')));
      expect(idsOf(s), isNot(contains('trend_slowing')));
    });

    test('too few meals: no trend claim', () {
      final s = SuggestionEngine.build(recentMeals: series([4, 8]));
      expect(idsOf(s), isNot(contains('trend_speeding')));
      expect(idsOf(s), isNot(contains('trend_slowing')));
    });
  });

  group('output shape', () {
    test('respects the max and is ordered by priority', () {
      final s = SuggestionEngine.build(
        recentMeals: [
          for (var i = 0; i < 6; i++)
            mealAt([0, 4, 8, 12, 16, 20, 24, 200, 204, 208, 212, 216],
                steady: [98.0, 96, 94, 92, 90, 70, 66, 64, 62, 60, 58, 56],
                temps: [64.0, 60, 56, 52, 50, 48, 46, 45, 44, 43, 42, 41],
                start: _start.subtract(Duration(days: i))),
        ],
        max: 3,
      );
      expect(s.length, lessThanOrEqualTo(3));
      for (var i = 1; i < s.length; i++) {
        expect(s[i - 1].priority, greaterThanOrEqualTo(s[i].priority));
      }
    });

    test('ids are unique in one build', () {
      final s = SuggestionEngine.build(
        recentMeals: [
          for (var i = 0; i < 6; i++)
            evenMeal(12, 9, start: _start.subtract(Duration(days: i))),
        ],
        max: 10,
      );
      expect(idsOf(s).length, s.length);
    });
  });
}
