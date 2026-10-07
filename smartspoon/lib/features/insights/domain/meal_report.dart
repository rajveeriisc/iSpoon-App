// meal_report.dart — everything one finished meal can be told about itself.
//
// The app already stores a row per BITE: its timestamp, the steadiness at that
// moment, and the food temperature. Until now only the sync service ever read
// those rows; no screen did. So the app knew far more about each meal than it
// ever showed — how the pace moved from the first half to the second, where
// the pauses were, how the food cooled while someone ate.
//
// This rebuilds all of that from the stored bites, which means it works for
// meals recorded long before this file existed. Nothing new has to be
// captured.
//
// Definitions are IMPORTED from eating_insights rather than restated, because
// the live card and this report describe the same meal — a pause has to mean
// the same thing in both. That is the mistake this codebase has already made
// once with the steadiness bands.
import 'dart:math' as math;

import 'package:smartspoon/core/models/bite.dart';
import 'package:smartspoon/core/models/meal.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';

/// Which way the pace moved across a meal.
enum PaceTrend {
  /// Gaps got shorter in the second half — eating faster as it went on.
  spedUp,

  /// Gaps got longer — slowed down.
  slowedDown,

  /// No meaningful change.
  steady,

  /// Too few bites to say.
  unknown,
}

/// A break in eating, long enough that it was not just a slow bite.
class MealPause {
  const MealPause({required this.afterBite, required this.at, required this.seconds});

  /// 1-based index of the bite this pause followed.
  final int afterBite;
  final DateTime at;
  final double seconds;
}

/// How the food's temperature moved while the meal was eaten.
class TemperatureTrace {
  const TemperatureTrace({
    required this.firstC,
    required this.lastC,
    required this.minC,
    required this.maxC,
    required this.readings,
  });

  final double firstC;
  final double lastC;
  final double minC;
  final double maxC;

  /// How many bites carried a temperature reading.
  final int readings;

  /// Positive means the food was cooler by the end.
  double get dropC => firstC - lastC;
}

/// One bite, for plotting the meal.
class BiteMoment {
  const BiteMoment({
    required this.index,
    required this.at,
    required this.sinceStart,
    this.gapBeforeSec,
    this.steadyPct,
    this.tempC,
    this.tremorIndex,
  });

  /// 1-based position in the meal.
  final int index;
  final DateTime at;
  final Duration sinceStart;

  /// Seconds since the previous bite; null for the first.
  final double? gapBeforeSec;
  final double? steadyPct;
  final double? tempC;
  final double? tremorIndex;
}

/// A finished meal, described from its own stored bites.
class MealReport {
  const MealReport({
    required this.meal,
    required this.moments,
    required this.gapsSec,
    required this.pauses,
    this.bitesPerMin,
    this.meanGapSec,
    this.medianGapSec,
    this.gapCv,
    this.firstHalfGapSec,
    this.secondHalfGapSec,
    this.meanSteadyPct,
    this.firstHalfSteadyPct,
    this.secondHalfSteadyPct,
    this.temperature,
  });

  /// Builds a report from the meal row and its bites.
  ///
  /// Invalid bites are dropped here rather than in the query, because
  /// DatabaseService.getBitesForMeal is shared with the sync service, which
  /// legitimately needs every row.
  factory MealReport.from({required Meal meal, required List<Bite> bites}) {
    final valid = bites.where((b) => b.isValid).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final start = meal.startedAt;
    final gaps = <double>[];
    final moments = <BiteMoment>[];
    final pauses = <MealPause>[];

    for (var i = 0; i < valid.length; i++) {
      final b = valid[i];
      double? gap;
      if (i > 0) {
        gap = b.timestamp.difference(valid[i - 1].timestamp).inMilliseconds /
            1000.0;
        // A negative or absurd gap means the clock moved, not the spoon.
        if (gap >= 0 && gap.isFinite) {
          gaps.add(gap);
          if (gap >= kPauseGapSec) {
            pauses.add(MealPause(
              afterBite: i,
              at: valid[i - 1].timestamp,
              seconds: gap,
            ));
          }
        } else {
          gap = null;
        }
      }
      moments.add(BiteMoment(
        index: i + 1,
        at: b.timestamp,
        sinceStart: b.timestamp.difference(start),
        gapBeforeSec: gap,
        steadyPct: b.steadyPct,
        tempC: b.foodTempC,
        tremorIndex: b.tremorMagnitude,
      ));
    }

    // Duration: prefer what the meal recorded, fall back to the bites.
    final durationMin = meal.durationMinutes ??
        (meal.endedAt != null
            ? meal.endedAt!.difference(start).inSeconds / 60.0
            : valid.isNotEmpty
                ? valid.last.timestamp.difference(start).inSeconds / 60.0
                : 0.0);

    final steadies = [
      for (final b in valid)
        if (b.steadyPct != null) b.steadyPct!,
    ];
    final temps = [
      for (final b in valid)
        if (b.foodTempC != null && b.foodTempC! > 0) b.foodTempC!,
    ];

    return MealReport(
      meal: meal,
      moments: List.unmodifiable(moments),
      gapsSec: List.unmodifiable(gaps),
      pauses: List.unmodifiable(pauses),
      // Only meaningful once the meal lasted long enough to have a rate.
      bitesPerMin: (durationMin > 0.5 && valid.isNotEmpty)
          ? valid.length / durationMin
          : null,
      meanGapSec: _mean(gaps),
      medianGapSec: _median(gaps),
      gapCv: _cv(gaps),
      firstHalfGapSec: _halfMean(gaps, first: true),
      secondHalfGapSec: _halfMean(gaps, first: false),
      meanSteadyPct: _mean(steadies),
      firstHalfSteadyPct: _halfMean(steadies, first: true),
      secondHalfSteadyPct: _halfMean(steadies, first: false),
      temperature: temps.length >= 2
          ? TemperatureTrace(
              firstC: temps.first,
              lastC: temps.last,
              minC: temps.reduce(math.min),
              maxC: temps.reduce(math.max),
              readings: temps.length,
            )
          : null,
    );
  }

  final Meal meal;

  /// Every bite, in order, for charting.
  final List<BiteMoment> moments;

  /// Seconds between consecutive bites.
  final List<double> gapsSec;

  /// Breaks of [kPauseGapSec] or longer.
  final List<MealPause> pauses;

  final double? bitesPerMin;
  final double? meanGapSec;
  final double? medianGapSec;

  /// Coefficient of variation of the gaps — how even the rhythm was.
  /// Same measure the live card calls "Rhythm".
  final double? gapCv;

  final double? firstHalfGapSec;
  final double? secondHalfGapSec;

  final double? meanSteadyPct;
  final double? firstHalfSteadyPct;
  final double? secondHalfSteadyPct;

  /// Null when fewer than two bites carried a temperature reading.
  final TemperatureTrace? temperature;

  int get biteCount => moments.length;

  /// Ratio of second-half to first-half gaps, matching
  /// [MealMetrics.speedChange]: below 1 means the gaps shortened, i.e. they
  /// ate faster as the meal went on.
  double? get speedChange {
    final a = firstHalfGapSec, b = secondHalfGapSec;
    if (a == null || b == null || a <= 0) return null;
    return b / a;
  }

  /// Same 0.8 / 1.25 cuts the live card uses, so the two agree.
  PaceTrend get paceTrend {
    final s = speedChange;
    if (s == null) return PaceTrend.unknown;
    if (s < 0.8) return PaceTrend.spedUp;
    if (s > 1.25) return PaceTrend.slowedDown;
    return PaceTrend.steady;
  }

  /// Positive means steadier in the second half than the first.
  double? get steadinessChangePct {
    final a = firstHalfSteadyPct, b = secondHalfSteadyPct;
    if (a == null || b == null) return null;
    return b - a;
  }

  /// Share of gaps at or above the mindful 10-second pace, 0–100.
  double? get mindfulSharePct {
    if (gapsSec.isEmpty) return null;
    final n = gapsSec.where((g) => g >= kMindfulGapSec).length;
    return n / gapsSec.length * 100.0;
  }

  /// True when there is enough in this meal to be worth showing a report for.
  bool get isReportable => biteCount >= 3;

  // ── helpers ──────────────────────────────────────────────────────────────

  static double? _mean(List<double> v) =>
      v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;

  static double? _median(List<double> v) {
    if (v.isEmpty) return null;
    final s = [...v]..sort();
    final mid = s.length ~/ 2;
    return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2.0;
  }

  static double? _cv(List<double> v) {
    if (v.length < 2) return null;
    final m = _mean(v)!;
    if (m <= 0) return null;
    final varSum =
        v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / v.length;
    return math.sqrt(varSum) / m;
  }

  /// Mean of the first or last half. Uses the outer halves and lets the
  /// middle sample fall in both when the count is odd, which is what
  /// MealMetrics does.
  static double? _halfMean(List<double> v, {required bool first}) {
    if (v.length < 2) return null;
    final half = v.length ~/ 2;
    if (half == 0) return null;
    return _mean(first ? v.sublist(0, half) : v.sublist(v.length - half));
  }
}
