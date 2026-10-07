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
}
