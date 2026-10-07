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


/// A least-squares fit of cumulative bites against time, following the model
/// Kissileff, Thornton and Becker established for cumulative intake curves:
///
///     I(t) = a + b*t + c*t^2
///
/// [initialRate] is b, the eating rate at the start of the meal.
/// [acceleration] is 2c, the rate at which the eating rate itself changes —
/// negative means the person slowed as the meal went on, which is the
/// signature of satiation. Positive means they sped up.
///
/// IMPORTANT, two honest limits:
///
///  1. The original model fits intake by WEIGHT. This fits bite COUNT, which
///     is only a proxy for intake and assumes roughly even bite sizes. The
///     spoon cannot weigh food, so this is the closest available measure, not
///     the same measure.
///  2. A quadratic has one fixed sign of curvature, so it cannot represent a
///     meal that sped up and then slowed down. [rSquared] is reported for
///     exactly this reason: a coefficient from a poor fit means nothing, and
///     callers should not present one without checking [isTrustworthy].
class IntakeCurveFit {
  const IntakeCurveFit({
    required this.initialRate,
    required this.acceleration,
    required this.rSquared,
    required this.samples,
  });

  /// Bites per minute at t = 0.
  final double initialRate;

  /// Change in bites/min per minute. Negative = slowing down.
  final double acceleration;

  /// Share of variance explained, 0–1.
  final double rSquared;
  final int samples;

  /// The original work reported 97–99% of variance explained. Well below
  /// that, the curvature is not describing this meal.
  bool get isTrustworthy => rSquared >= 0.90 && samples >= 6;

  /// Negative acceleration on a fit worth believing.
  bool get showsSatiation => isTrustworthy && acceleration < 0;
}

/// A run of bites with no long break in it.
class EatingBout {
  const EatingBout({
    required this.firstBite,
    required this.lastBite,
    required this.start,
    required this.end,
  });

  final int firstBite;
  final int lastBite;
  final DateTime start;
  final DateTime end;

  int get bites => lastBite - firstBite + 1;
  Duration get duration => end.difference(start);
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
    this.intakeCurve,
    this.bouts = const [],
    this.activeBitesPerMin,
    this.steadinessSlopePctPerMin,
    this.coolingRateCPerMin,
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
      intakeCurve: _fitIntakeCurve(moments),
      bouts: _findBouts(moments, gaps),
      activeBitesPerMin: _activeRate(valid.length, durationMin, pauses),
      steadinessSlopePctPerMin: _steadinessSlope(moments),
      coolingRateCPerMin: _coolingRate(moments),
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

  /// Cumulative-intake fit. Null when there were too few bites to fit three
  /// coefficients at all.
  final IntakeCurveFit? intakeCurve;

  /// Runs of bites with no long break between them.
  final List<EatingBout> bouts;

  /// Pace counting only time spent actually eating — pause time removed.
  ///
  /// More accurate than [bitesPerMin] for someone who stopped mid-meal: a
  /// 20-bite meal with a ten-minute break in it is not a slow eater, but
  /// dividing by wall-clock duration says it is.
  final double? activeBitesPerMin;

  /// Change in steadiness per minute across the meal. Negative means the
  /// hand grew less steady as the meal went on.
  final double? steadinessSlopePctPerMin;

  /// How fast the food cooled, degrees Celsius per minute.
  ///
  /// A straight line over the readings. Newton's law of cooling is
  /// exponential, but fitting three parameters to a handful of noisy
  /// per-bite readings would invent precision that is not there; the average
  /// rate over the meal is what the data supports.
  final double? coolingRateCPerMin;

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


  /// Least squares on I(t) = a + b*t + c*t^2 via the normal equations,
  /// solved with Cramer's rule on the 3x3 system.
  static IntakeCurveFit? _fitIntakeCurve(List<BiteMoment> m) {
    // Three coefficients need more than three points to mean anything.
    if (m.length < 5) return null;
    final t = [for (final x in m) x.sinceStart.inMilliseconds / 60000.0];
    final y = [for (var i = 0; i < m.length; i++) (i + 1).toDouble()];
    if (t.last <= 0) return null;

    double sum(List<double> v) => v.reduce((a, b) => a + b);
    final n = m.length.toDouble();
    final t1 = sum(t);
    final t2 = sum([for (final x in t) x * x]);
    final t3 = sum([for (final x in t) x * x * x]);
    final t4 = sum([for (final x in t) x * x * x * x]);
    final y0 = sum(y);
    final y1 = sum([for (var i = 0; i < t.length; i++) t[i] * y[i]]);
    final y2 = sum([for (var i = 0; i < t.length; i++) t[i] * t[i] * y[i]]);

    double det3(List<List<double>> a) =>
        a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) -
        a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) +
        a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]);

    final A = [
      [n, t1, t2],
      [t1, t2, t3],
      [t2, t3, t4],
    ];
    final d = det3(A);
    // Degenerate when the timestamps carry no spread.
    if (d.abs() < 1e-12) return null;

    List<List<double>> swapCol(int col, List<double> rhs) => [
          for (var r = 0; r < 3; r++)
            [for (var c = 0; c < 3; c++) c == col ? rhs[r] : A[r][c]],
        ];
    final rhs = [y0, y1, y2];
    final a = det3(swapCol(0, rhs)) / d;
    final b = det3(swapCol(1, rhs)) / d;
    final c = det3(swapCol(2, rhs)) / d;

    final yMean = y0 / n;
    var ssRes = 0.0, ssTot = 0.0;
    for (var i = 0; i < t.length; i++) {
      final pred = a + b * t[i] + c * t[i] * t[i];
      ssRes += (y[i] - pred) * (y[i] - pred);
      ssTot += (y[i] - yMean) * (y[i] - yMean);
    }
    final r2 = ssTot <= 0 ? 0.0 : (1.0 - ssRes / ssTot).clamp(0.0, 1.0);

    return IntakeCurveFit(
      initialRate: b,
      // 2c is the rate of change of the eating rate.
      acceleration: 2 * c,
      rSquared: r2,
      samples: m.length,
    );
  }

  /// Threshold for "that was a break, not just a slow bite".
  ///
  /// The microstructure literature uses an inter-bout interval of about 5
  /// seconds, but that comes from licking and chewing studies where events
  /// are a fraction of a second apart. Spoon bites sit 3-12 seconds apart, so
  /// 5 seconds would make almost every bite its own bout. This calibrates to
  /// the person instead: a break is a gap several times their own typical
  /// gap, with a floor so a very fast eater does not get a break declared
  /// every few seconds.
  ///
  /// The multiplier and floor are starting points chosen from the geometry of
  /// the data, not validated figures.
  static const double boutBreakFactor = 3.0;
  static const double boutBreakFloorSec = 20.0;

  static List<EatingBout> _findBouts(List<BiteMoment> m, List<double> gaps) {
    if (m.length < 2 || gaps.isEmpty) return const [];
    final med = _median(gaps)!;
    final threshold = math.max(boutBreakFloorSec, boutBreakFactor * med);

    final out = <EatingBout>[];
    var firstIdx = 0;
    for (var i = 1; i < m.length; i++) {
      final g = m[i].gapBeforeSec;
      if (g != null && g >= threshold) {
        out.add(EatingBout(
          firstBite: m[firstIdx].index,
          lastBite: m[i - 1].index,
          start: m[firstIdx].at,
          end: m[i - 1].at,
        ));
        firstIdx = i;
      }
    }
    out.add(EatingBout(
      firstBite: m[firstIdx].index,
      lastBite: m.last.index,
      start: m[firstIdx].at,
      end: m.last.at,
    ));
    return List.unmodifiable(out);
  }

  static double? _activeRate(
      int bites, double durationMin, List<MealPause> pauses) {
    if (bites < 2 || durationMin <= 0) return null;
    final pausedMin =
        pauses.fold<double>(0, (sum, p) => sum + p.seconds) / 60.0;
    final active = durationMin - pausedMin;
    if (active < 0.5) return null;
    return bites / active;
  }

  /// Ordinary least squares of steadiness against minutes elapsed.
  static double? _steadinessSlope(List<BiteMoment> m) {
    final pts = [
      for (final x in m)
        if (x.steadyPct != null)
          [x.sinceStart.inMilliseconds / 60000.0, x.steadyPct!],
    ];
    if (pts.length < 3) return null;
    return _slope(pts);
  }

  static double? _coolingRate(List<BiteMoment> m) {
    final pts = [
      for (final x in m)
        if (x.tempC != null && x.tempC! > 0)
          [x.sinceStart.inMilliseconds / 60000.0, x.tempC!],
    ];
    if (pts.length < 3) return null;
    final s = _slope(pts);
    // Reported as a positive cooling rate; food warming up is not cooling.
    return s == null ? null : -s;
  }

  static double? _slope(List<List<double>> pts) {
    final n = pts.length.toDouble();
    final sx = pts.fold<double>(0, (a, p) => a + p[0]);
    final sy = pts.fold<double>(0, (a, p) => a + p[1]);
    final sxx = pts.fold<double>(0, (a, p) => a + p[0] * p[0]);
    final sxy = pts.fold<double>(0, (a, p) => a + p[0] * p[1]);
    final denom = n * sxx - sx * sx;
    if (denom.abs() < 1e-12) return null;
    return (n * sxy - sx * sy) / denom;
  }

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
