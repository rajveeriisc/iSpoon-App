// A finished meal, rebuilt from its stored bites.
//
// The per-bite rows were only ever read by the sync service, so everything
// here is derived from data the app already had and never showed.
//
// The important tests are the agreement ones: this report and the live
// MealMetrics card describe the same meal, so a pause, a rhythm figure and a
// pace change must mean the same thing in both. This codebase has already
// shipped one bug where two screens disagreed about the same reading.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/core/models/bite.dart';
import 'package:smartspoon/core/models/meal.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';
import 'package:smartspoon/features/insights/domain/meal_report.dart';

final _start = DateTime(2026, 10, 7, 13, 0, 0);

/// A meal whose bites sit at the given offsets, in seconds from the start.
MealReport reportOf(
  List<double> offsetsSec, {
  List<double?>? steady,
  List<double?>? temps,
  double? durationMinutes,
  List<bool>? valid,
}) {
  final bites = <Bite>[];
  for (var i = 0; i < offsetsSec.length; i++) {
    bites.add(Bite(
      mealUuid: 'm1',
      timestamp: _start.add(Duration(milliseconds: (offsetsSec[i] * 1000).round())),
      sequenceNumber: i + 1,
      steadyPct: steady == null ? null : steady[i],
      foodTempC: temps == null ? null : temps[i],
      isValid: valid == null ? true : valid[i],
    ));
  }
  final last = offsetsSec.isEmpty ? 0.0 : offsetsSec.last;
  return MealReport.from(
    meal: Meal(
      userId: 'u1',
      startedAt: _start,
      endedAt: _start.add(Duration(seconds: last.round())),
      mealType: 'Lunch',
      totalBites: offsetsSec.length,
      durationMinutes: durationMinutes ?? last / 60.0,
    ),
    bites: bites,
  );
}

void main() {
  group('gaps and pace', () {
    test('gaps come from the bite timestamps', () {
      final r = reportOf([0, 10, 20, 32]);
      expect(r.biteCount, 4);
      expect(r.gapsSec, [10.0, 10.0, 12.0]);
      expect(r.meanGapSec, closeTo(10.67, 0.01));
      expect(r.medianGapSec, 10.0);
    });

    test('pace needs a meal long enough to have a rate', () {
      // Under 30 s there is no meaningful bites/min.
      expect(reportOf([0, 5, 10], durationMinutes: 0.25).bitesPerMin, isNull);
      final r = reportOf([0, 10, 20, 30, 40, 50, 60], durationMinutes: 1.0);
      expect(r.bitesPerMin, closeTo(7.0, 0.01));
    });

    test('a single bite yields no gaps and no rhythm', () {
      final r = reportOf([0]);
      expect(r.gapsSec, isEmpty);
      expect(r.meanGapSec, isNull);
      expect(r.gapCv, isNull);
      expect(r.speedChange, isNull);
      expect(r.paceTrend, PaceTrend.unknown);
      expect(r.isReportable, isFalse);
    });

    test('a clock going backwards does not produce a negative gap', () {
      // Bite timestamps come off the phone; they are not guaranteed monotonic.
      final r = reportOf([0, 10, 5, 20]);
      expect(r.gapsSec.every((g) => g >= 0), isTrue);
      expect(r.gapsSec.any((g) => g.isNaN), isFalse);
    });
  });

  group('pace trend', () {
    test('shortening gaps read as sped up', () {
      final r = reportOf([0, 20, 40, 60, 65, 70, 75]);
      expect(r.speedChange, lessThan(0.8));
      expect(r.paceTrend, PaceTrend.spedUp);
    });

    test('lengthening gaps read as slowed down', () {
      final r = reportOf([0, 5, 10, 15, 35, 55, 75]);
      expect(r.speedChange, greaterThan(1.25));
      expect(r.paceTrend, PaceTrend.slowedDown);
    });

    test('an even meal reads as steady', () {
      final r = reportOf([0, 10, 20, 30, 40, 50, 60]);
      expect(r.paceTrend, PaceTrend.steady);
    });
  });

  group('pauses', () {
    test('a break of a minute or more is a pause, and is located', () {
      final r = reportOf([0, 10, 20, 100, 110]);
      expect(r.pauses, hasLength(1));
      expect(r.pauses.single.seconds, 80.0);
      expect(r.pauses.single.afterBite, 3,
          reason: 'the pause followed the third bite');
    });

    test('slow eating is not a pause', () {
      final r = reportOf([0, 30, 60, 90]);
      expect(r.pauses, isEmpty);
    });

    test('the threshold is the one the live card uses', () {
      // Exactly at the boundary counts, matching gaps.where((g) => g >= kPauseGapSec).
      expect(reportOf([0, kPauseGapSec]).pauses, hasLength(1));
      expect(reportOf([0, kPauseGapSec - 0.1]).pauses, isEmpty);
    });
  });

  group('agreement with the live MealMetrics card', () {
    // Same meal, both routes. If these drift, one screen contradicts another.
    final offsets = [0.0, 8.0, 19.0, 26.0, 40.0, 95.0, 103.0, 112.0];
    final times = [for (final o in offsets) _start.add(Duration(seconds: o.round()))];
    final live = MealMetrics.from(
      biteTimes: times,
      start: _start,
      end: times.last,
      windows: 10,
      rhythmicWindows: 1,
    );
    final report = reportOf(offsets);

    test('pause count agrees', () {
      expect(report.pauses.length, live.pauses);
    });

    test('rhythm (gap CV) agrees', () {
      expect(report.gapCv, isNotNull);
      expect(report.gapCv!, closeTo(live.gapCv!, 0.001));
    });

    test('pace change agrees', () {
      expect(report.speedChange, isNotNull);
      expect(report.speedChange!, closeTo(live.speedChange!, 0.001));
    });

    test('mean gap agrees', () {
      expect(report.meanGapSec!, closeTo(live.meanGapSec!, 0.001));
    });
  });

  group('steadiness through the meal', () {
    test('mean and the halves are reported', () {
      final r = reportOf(
        [0, 10, 20, 30],
        steady: [100.0, 90.0, 70.0, 60.0],
      );
      expect(r.meanSteadyPct, closeTo(80.0, 0.01));
      expect(r.firstHalfSteadyPct, closeTo(95.0, 0.01));
      expect(r.secondHalfSteadyPct, closeTo(65.0, 0.01));
      expect(r.steadinessChangePct, closeTo(-30.0, 0.01),
          reason: 'hand got less steady as the meal went on');
    });

    test('bites with no steadiness reading are skipped, not counted as zero', () {
      final r = reportOf([0, 10, 20], steady: [90.0, null, 80.0]);
      expect(r.meanSteadyPct, closeTo(85.0, 0.01));
    });

    test('no steadiness at all leaves it null', () {
      expect(reportOf([0, 10, 20]).meanSteadyPct, isNull);
    });
  });

  group('food temperature across the meal', () {
    test('the cooling is described', () {
      final r = reportOf([0, 10, 20, 30], temps: [62.0, 58.0, 51.0, 47.0]);
      final t = r.temperature!;
      expect(t.firstC, 62.0);
      expect(t.lastC, 47.0);
      expect(t.maxC, 62.0);
      expect(t.minC, 47.0);
      expect(t.dropC, closeTo(15.0, 0.01));
      expect(t.readings, 4);
    });

    test('zero and missing readings are not treated as temperatures', () {
      // 0 C is the sentinel for "no reading", not freezing food.
      final r = reportOf([0, 10, 20, 30], temps: [60.0, 0.0, null, 50.0]);
      expect(r.temperature!.readings, 2);
      expect(r.temperature!.minC, 50.0);
    });

    test('one reading is not a trace', () {
      expect(reportOf([0, 10], temps: [60.0, null]).temperature, isNull);
    });
  });

  group('mindful pace', () {
    test('share of gaps at or above the 10 s target', () {
      final r = reportOf([0, 12, 24, 29, 34]);
      // gaps: 12, 12, 5, 5 -> half are mindful
      expect(r.mindfulSharePct, closeTo(50.0, 0.01));
    });

    test('null when there are no gaps', () {
      expect(reportOf([0]).mindfulSharePct, isNull);
    });
  });

  test('invalid bites are excluded', () {
    final r = reportOf(
      [0, 10, 20, 30],
      valid: [true, false, true, true],
    );
    expect(r.biteCount, 3, reason: 'the invalid bite must not be counted');
  });

  test('moments carry what a chart needs, in order', () {
    final r = reportOf([0, 10, 25], steady: [95.0, 80.0, 70.0], temps: [60.0, 55.0, 50.0]);
    expect(r.moments.map((m) => m.index), [1, 2, 3]);
    expect(r.moments.first.gapBeforeSec, isNull, reason: 'nothing precedes bite 1');
    expect(r.moments[1].gapBeforeSec, 10.0);
    expect(r.moments[2].sinceStart.inSeconds, 25);
    expect(r.moments[2].tempC, 50.0);
    expect(r.moments[2].steadyPct, 70.0);
  });

  // ── research-grounded microstructure ──────────────────────────────────────
  //
  // The cumulative-intake model is Kissileff/Thornton/Becker's quadratic
  // I = a + b*t + c*t^2, where b is the starting eating rate and 2c is the
  // rate at which that rate changes. Negative 2c is the satiation signature.
  group('cumulative intake curve', () {
    test('even gaps give a straight line: no acceleration, near-perfect fit', () {
      // A bite every 10 s is 6 bites/min, and the rate never changes.
      final r = reportOf([for (var i = 0; i < 12; i++) i * 10.0]);
      final f = r.intakeCurve!;
      expect(f.initialRate, closeTo(6.0, 0.3));
      expect(f.acceleration, closeTo(0.0, 0.3));
      expect(f.rSquared, greaterThan(0.99));
      expect(f.isTrustworthy, isTrue);
      expect(f.showsSatiation, isFalse);
    });

    test('lengthening gaps read as slowing down — the satiation signature', () {
      // Gaps grow 5,6,7,... so the curve bends over.
      final offs = <double>[0];
      var g = 5.0;
      for (var i = 0; i < 11; i++) { offs.add(offs.last + g); g += 2.0; }
      final f = reportOf(offs).intakeCurve!;
      expect(f.acceleration, lessThan(0.0));
      expect(f.isTrustworthy, isTrue);
      expect(f.showsSatiation, isTrue);
    });

    test('shortening gaps read as speeding up', () {
      final offs = <double>[0];
      var g = 26.0;
      for (var i = 0; i < 11; i++) { offs.add(offs.last + g); g -= 2.0; }
      final f = reportOf(offs).intakeCurve!;
      expect(f.acceleration, greaterThan(0.0));
      expect(f.showsSatiation, isFalse);
    });

    test('a meal that speeds up then slows down is reported as untrustworthy', () {
      // A quadratic has one sign of curvature, so it cannot describe this.
      // The point of rSquared is to stop us presenting the coefficient anyway.
      final offs = <double>[0];
      for (final g in [20.0, 16, 12, 8, 4, 4, 8, 12, 16, 20, 24]) {
        offs.add(offs.last + g);
      }
      final f = reportOf(offs).intakeCurve!;
      // A cumulative curve fits a quadratic well whatever its shape, so the
      // gate is what protects us, not a low R² — this one still scores 0.96.
      expect(f.rSquared, lessThan(0.99));
      expect(f.isTrustworthy, isFalse);
    });

    test('too few bites to fit three coefficients', () {
      expect(reportOf([0, 10, 20, 30]).intakeCurve, isNull);
    });
  });

  group('eating bouts', () {
    test('a long break splits the meal into two bouts', () {
      final r = reportOf([0, 8, 16, 24, 200, 208, 216]);
      expect(r.bouts, hasLength(2));
      expect(r.bouts.first.bites, 4);
      expect(r.bouts.last.bites, 3);
      expect(r.bouts.first.firstBite, 1);
      expect(r.bouts.last.lastBite, 7);
    });

    test('an uninterrupted meal is one bout', () {
      final r = reportOf([for (var i = 0; i < 10; i++) i * 9.0]);
      expect(r.bouts, hasLength(1));
      expect(r.bouts.single.bites, 10);
    });

    test('the threshold calibrates to the eater, not a fixed 5 s', () {
      // A slow eater on 30 s gaps must not have every bite called a bout.
      final slow = reportOf([for (var i = 0; i < 8; i++) i * 30.0]);
      expect(slow.bouts, hasLength(1),
          reason: '30 s gaps are this person\'s normal, not breaks');
      // A fast eater on 4 s gaps: a 25 s gap IS a break for them.
      final fast = reportOf([0, 4, 8, 12, 37, 41, 45]);
      expect(fast.bouts, hasLength(2));
    });
  });

  group('active pace excludes time not spent eating', () {
    test('a long break does not make someone a slow eater', () {
      // 8 bites over ~9 min, but 5 of those minutes were a single pause.
      final offs = <double>[0, 10, 20, 30, 330, 340, 350, 360];
      final r = reportOf(offs);
      expect(r.pauses, hasLength(1));
      expect(r.activeBitesPerMin, isNotNull);
      expect(r.activeBitesPerMin!, greaterThan(r.bitesPerMin!),
          reason: 'removing the pause raises the real eating rate');
    });

    test('with no pauses it agrees with the wall-clock rate', () {
      final r = reportOf([for (var i = 0; i < 10; i++) i * 10.0]);
      expect(r.activeBitesPerMin!, closeTo(r.bitesPerMin!, 0.01));
    });
  });

  group('trends through the meal', () {
    test('cooling is reported as a positive rate', () {
      // 60 C down to 48 C over 2 minutes = 6 C/min.
      final r = reportOf([0, 30, 60, 90, 120],
          temps: [60.0, 57.0, 54.0, 51.0, 48.0]);
      expect(r.coolingRateCPerMin!, closeTo(6.0, 0.2));
    });

    test('food warming up is not reported as cooling', () {
      final r = reportOf([0, 30, 60, 90],
          temps: [40.0, 44.0, 48.0, 52.0]);
      expect(r.coolingRateCPerMin!, lessThan(0.0));
    });

    test('a hand getting less steady gives a negative slope', () {
      final r = reportOf([0, 60, 120, 180],
          steady: [100.0, 90.0, 80.0, 70.0]);
      expect(r.steadinessSlopePctPerMin!, closeTo(-10.0, 0.5));
    });

    test('slopes need at least three readings', () {
      expect(reportOf([0, 30], temps: [60.0, 50.0]).coolingRateCPerMin, isNull);
      expect(reportOf([0, 30], steady: [90.0, 80.0]).steadinessSlopePctPerMin,
          isNull);
    });
  });
}
