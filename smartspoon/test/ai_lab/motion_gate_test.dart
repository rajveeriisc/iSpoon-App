// A steadiness reading must come from a hand, not from a spoon on a table.
//
// Regression guard for "Steady 100%" shown beside 0 bites: the analyzer's
// `share` is a RATIO of in-band power, so a motionless spoon produces
// broadband sensor noise, a low share, a NOT-rhythmic window — and used to be
// counted as a steady hand. After five seconds of simply being connected the
// app reported a confident 100%.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/meal_tracker.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/steadiness_analyzer.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';

const _ref = SteadinessReference(
  fftSize: 256,
  hop: 100,
  bandLoHz: 4.0,
  bandHiHz: 12.0,
  rhythmicShareThreshold: 0.35,
  normalSteadyPctMin: 60.0,
  normalSteadyPctMedian: 85.0,
  syntheticDetection: {},
);

/// Feed [n] samples from [sample] and return the last window produced.
SteadinessResult? _run(int n, (double, double, double) Function(int) sample) {
  final a = SteadinessAnalyzer(_ref, sampleRateHz: 100);
  SteadinessResult? last;
  for (var i = 0; i < n; i++) {
    final (gx, gy, gz) = sample(i);
    final r = a.add(gx, gy, gz);
    if (r != null) last = r;
  }
  return last;
}

void main() {
  group('motion gate — is the spoon even in a hand', () {
    test('a spoon lying still is NOT active', () {
      // BMI270 gyro noise: tens of millidegrees/s. Deterministic pseudo-noise
      // so the test cannot flake.
      final rnd = math.Random(42);
      final w = _run(301, (_) {
        double n() => (rnd.nextDouble() - 0.5) * 0.08; // ~0.023 dps RMS
        return (n(), n(), n());
      });
      expect(w, isNotNull);
      expect(w!.motionRmsDps, lessThan(kDefaultMinMotionRmsDps));
      expect(w.active, isFalse,
          reason: 'a motionless spoon must produce no reading at all');
    });

    test('a hand holding and shaking the spoon IS active', () {
      // 6 Hz, 10 dps — squarely inside the 4-12 Hz tremor band.
      final w = _run(301, (i) {
        final v = 10.0 * math.sin(2 * math.pi * 6.0 * i / 100.0);
        return (v, 0.0, 0.0);
      });
      expect(w, isNotNull);
      expect(w!.motionRmsDps, greaterThan(kDefaultMinMotionRmsDps));
      expect(w.active, isTrue);
    });

    test('a constant gyro bias is not mistaken for motion', () {
      // Mean-removed, so a steady offset must not read as movement.
      final w = _run(301, (_) => (50.0, -20.0, 5.0));
      expect(w, isNotNull);
      expect(w!.motionRmsDps, lessThan(kDefaultMinMotionRmsDps));
      expect(w.active, isFalse);
    });
  });

  group('steadyPctOf divides by ACTIVE windows', () {
    test('no active windows is never a reading, however long we listened', () {
      // The exact shape of the bug: hundreds of analysed windows, none of them
      // movement. The honest answer is null, not 100.
      expect(steadyPctOf(0, 0), isNull);
      for (var active = 0; active < kMinSteadyWindows; active++) {
        expect(steadyPctOf(active, 0), isNull, reason: '$active active');
      }
    });

    test('at the minimum, all-steady active windows read 100', () {
      expect(steadyPctOf(kMinSteadyWindows, 0), 100.0);
    });

    test('rhythmic share lowers the figure', () {
      expect(steadyPctOf(10, 3), closeTo(70.0, 1e-9));
    });
  });

  group('MealTracker only counts movement as evidence', () {
    MealTracker started() {
      final t = MealTracker();
      // Two bites inside the start window open the meal.
      final t0 = DateTime(2026, 1, 1, 12);
      t.onBite(BiteEvent(time: t0, probability: 1.0));
      t.onBite(BiteEvent(
          time: t0.add(const Duration(seconds: 2)), probability: 1.0));
      return t;
    }

    test('inactive windows advance windows but not activeWindows', () {
      final t = started();
      expect(t.inMeal, isTrue, reason: 'two bites should start the meal');
      for (var i = 0; i < 50; i++) {
        t.onWindow(rhythmic: false, active: false, hz: 7);
      }
      expect(t.windows, 50, reason: 'we did analyse 50 windows');
      expect(t.activeWindows, 0, reason: 'none of them carried movement');
      expect(steadyPctOf(t.activeWindows, t.rhythmicWindows), isNull,
          reason: '50 motionless windows must not become "Steady 100%"');
    });

    test('active windows do produce a reading', () {
      final t = started();
      for (var i = 0; i < 10; i++) {
        t.onWindow(rhythmic: i < 2, active: true, hz: 6);
      }
      expect(t.activeWindows, 10);
      expect(t.rhythmicWindows, 2);
      expect(steadyPctOf(t.activeWindows, t.rhythmicWindows),
          closeTo(80.0, 1e-9));
    });

    test('a rhythmic-but-inactive window cannot count as shake either', () {
      final t = started();
      for (var i = 0; i < 20; i++) {
        t.onWindow(rhythmic: true, active: false, hz: 6);
      }
      expect(t.activeWindows, 0);
      expect(t.rhythmicWindows, 0,
          reason: 'inactive windows are evidence in NEITHER direction');
    });
  });
}
