// The three numbers the AI Lab page and the rest of the app must agree on:
// what may be stored as a tremor window, how many bites a meal contributes to
// the app-wide total, and what "steady %" means.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/meal_tracker.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';
import 'package:smartspoon/features/insights/domain/services/unified_data_service.dart';

void main() {
  group('tremor_window_ms stays inside the column contract', () {
    // A meal runs for as long as it runs; the column accepts 3–30 s. Before
    // this was clamped, every bite past 0:30 aborted the bite+meal
    // transaction, the anchor rolled back, and the next tick retried the same
    // doomed write forever — no bite after the 30 s mark was ever stored.
    test('a long meal is clamped instead of violating the CHECK', () {
      for (final mealSeconds in [5, 20, 30, 31, 120, 3600]) {
        final r = UnifiedDataService.aiLabTremorResult(
          steadyPct: 88,
          rhythmHz: 5.2,
          windowCount: mealSeconds,
          at: DateTime(2026),
        );
        final stored =
            UnifiedDataService.storableTremorWindowMs(r.windowDurationMs);
        expect(stored, greaterThanOrEqualTo(UnifiedDataService.minTremorWindowMs),
            reason: 'meal of ${mealSeconds}s');
        expect(stored, lessThanOrEqualTo(UnifiedDataService.maxTremorWindowMs),
            reason: 'meal of ${mealSeconds}s');
      }
    });

    test('a reading short enough to store keeps its real span', () {
      final r = UnifiedDataService.aiLabTremorResult(
          steadyPct: 88, rhythmHz: 5.2, windowCount: 12, at: DateTime(2026));
      expect(UnifiedDataService.storableTremorWindowMs(r.windowDurationMs),
          12000);
    });

    test('the rolling buffer never needs the clamp at all', () {
      // AiLabService caps the rolling window at 60, and migration 021 / local
      // schema v17 accept exactly that. Anything the bite path can actually
      // produce is therefore stored at its true span, not a clamped one.
      for (var windows = 5; windows <= 60; windows++) {
        final r = UnifiedDataService.aiLabTremorResult(
            steadyPct: 90, rhythmHz: null, windowCount: windows, at: DateTime(2026));
        expect(UnifiedDataService.storableTremorWindowMs(r.windowDurationMs),
            windows * 1000,
            reason: 'a $windows-window reading must keep its real span');
      }
    });

    test('every storable reading is one the DB would accept', () {
      for (var windows = 1; windows <= 600; windows++) {
        final r = UnifiedDataService.aiLabTremorResult(
            steadyPct: 90, rhythmHz: null, windowCount: windows, at: DateTime(2026));
        if (!(r.measured && r.confidence >= 0.5)) continue; // not written
        final ms = UnifiedDataService.storableTremorWindowMs(r.windowDurationMs);
        expect(ms >= 3000 && ms <= 60000, isTrue,
            reason: 'window count $windows would be rejected as $ms');
      }
    });
  });

  group('a discarded meal does not inflate the app-wide bite total', () {
    // Mirrors AiLabService: bites are counted as they arrive, and the meal-end
    // path hands them back when the meal is too short to keep.
    late MealTracker t;
    late int detected;
    late int seen;

    setUp(() {
      t = MealTracker();
      detected = 0;
      seen = 0;
    });

    void sample() {
      final mealBites = t.inMeal ? t.bites.length : 0;
      if (mealBites > seen) detected += mealBites - seen;
      seen = mealBites;
    }

    MealRecord? endMeal(DateTime now, MealEndReason reason) {
      final wasInMeal = t.inMeal;
      final provisional = wasInMeal ? t.bites.length : 0;
      final meal = t.finish(now, reason);
      final ended = wasInMeal && !t.inMeal;
      if (meal == null && ended && provisional > 0) {
        detected = (detected - provisional).clamp(0, detected);
      }
      if (ended) seen = 0;
      return meal;
    }

    void bite(DateTime at) {
      t.onBite(BiteEvent(time: at, probability: 0.9));
      sample();
    }

    test('two bites that never became a meal are given back', () {
      final t0 = DateTime(2026, 1, 1, 12);
      bite(t0);
      bite(t0.add(const Duration(seconds: 5)));
      expect(detected, 2, reason: 'counted live, as the page shows them');

      expect(endMeal(t0.add(const Duration(minutes: 5)), MealEndReason.timeout),
          isNull, reason: 'under minBites, so no meal is kept');
      expect(detected, 0, reason: 'and no bite may survive the meal it was in');
    });

    test('total across meals equals what the kept meals recorded', () {
      var recorded = 0;
      final t0 = DateTime(2026, 1, 1, 12);

      // Discarded: two bites.
      bite(t0);
      bite(t0.add(const Duration(seconds: 5)));
      endMeal(t0.add(const Duration(minutes: 5)), MealEndReason.timeout);

      // Kept: four bites.
      final t1 = t0.add(const Duration(hours: 1));
      for (var i = 0; i < 4; i++) {
        bite(t1.add(Duration(seconds: 5 * i)));
      }
      recorded += endMeal(t1.add(const Duration(minutes: 1)),
              MealEndReason.userFinished)!.bites.length;

      // Kept again, after the tracker went quiet — the counter must not still
      // be anchored on the previous meal's length.
      final t2 = t1.add(const Duration(hours: 1));
      for (var i = 0; i < 3; i++) {
        bite(t2.add(Duration(seconds: 5 * i)));
      }
      recorded += endMeal(t2.add(const Duration(minutes: 1)),
              MealEndReason.userFinished)!.bites.length;

      expect(detected, recorded);
      expect(detected, 7);
    });
  });

  group('one definition of steady %', () {
    test('below the minimum it is not a reading anywhere', () {
      for (var w = 0; w < kMinSteadyWindows; w++) {
        expect(steadyPctOf(w, 0), isNull, reason: '$w windows');
      }
    });

    test('MealRecord and MealMetrics give the same answer', () {
      final start = DateTime(2026, 1, 1, 12);
      const windows = 40;
      const rhythmic = 6;
      final record = MealRecord(
        start: start,
        end: start.add(const Duration(minutes: 1)),
        bites: const [],
        windows: windows,
        activeWindows: windows,
        rhythmicWindows: rhythmic,
        rhythmHz: 5.0,
        reason: MealEndReason.timeout,
      );
      final metrics = MealMetrics.from(
        biteTimes: [start],
        start: start,
        end: start.add(const Duration(minutes: 1)),
        windows: windows,
        rhythmicWindows: rhythmic,
        rhythmHz: 5.0,
      );
      expect(record.steadyPct, metrics.steadyPct);
      expect(record.steadyPct, steadyPctOf(windows, rhythmic));
      expect(record.steadyPct, closeTo(85.0, 1e-9));
    });
  });
}
