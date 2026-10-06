// eating_insights.dart — turns a meal's bite times into an eating pattern and
// coaching tips.
//
// Pure functions: no clock, no storage, no Flutter. Wording avoids medical
// claims; the pace target is the 10-seconds-per-bite rhythm used by
// slow-eating ("augmented fork") studies.
import 'dart:math' as math;

const double kMindfulGapSec = 10.0;
const double kShakyBelowPct = 75.0;
const double kSteadyFromPct = 90.0;

/// Fewer windows than this is not a reading: one or two of them swing between
/// 0 % and 100 % and would make every screen flicker.
const int kMinSteadyWindows = 5;

/// Share of [windows] that showed no rhythmic shaking, or null when there is
/// not yet enough to say.
///
/// The one definition of "steady %". It used to exist four times — in
/// [MealMetrics], [MealRecord], and twice in AiLabService — with two different
/// minimums, so the AI Lab page could show a figure computed from a single
/// window while Home, reading the same meal, still showed nothing.
/// Steadiness over the ACTIVE windows only, or null when there is not enough
/// evidence to say.
///
/// [activeWindows] must be the count of windows that actually carried hand
/// movement (SteadinessResult.active), NOT every window analysed. Dividing by
/// every window counted a spoon lying on a table as a steady hand, which is
/// how "Steady 100%" came to sit beside 0 bites: an untouched spoon produces
/// non-rhythmic windows forever. Below the minimum the honest answer is null —
/// callers must render "no reading", never a number.
double? steadyPctOf(int activeWindows, int rhythmicWindows) => activeWindows <
        kMinSteadyWindows
    ? null
    : 100.0 *
        (activeWindows - rhythmicWindows.clamp(0, activeWindows)) /
        activeWindows;

class MealMetrics {
  const MealMetrics({
    required this.bites,
    required this.duration,
    this.bitesPerMin,
    this.meanGapSec,
    this.last5GapSec,
    this.gapCv,
    this.speedChange,
    this.pauses = 0,
    this.steadyPct,
    this.rhythmHz,
  });

  /// [windows] is the count of ACTIVE steadiness windows (those that carried
  /// real hand movement), not every window analysed — it is the denominator
  /// steadyPctOf divides by.
  factory MealMetrics.from({
    required List<DateTime> biteTimes,
    required DateTime start,
    required DateTime end,
    int windows = 0,
    int rhythmicWindows = 0,
    double? rhythmHz,
  }) {
    final gaps = <double>[
      for (var i = 1; i < biteTimes.length; i++)
        biteTimes[i].difference(biteTimes[i - 1]).inMilliseconds / 1000.0,
    ];
    double? mean(List<double> v) =>
        v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;

    final duration = end.difference(start);
    final meanGap = mean(gaps);
    double? cv;
    if (gaps.length >= 3 && meanGap != null && meanGap > 0) {
      final variance =
          gaps.map((g) => (g - meanGap) * (g - meanGap)).reduce((a, b) => a + b) /
              gaps.length;
      cv = math.sqrt(variance) / meanGap;
    }
    double? speed;
    if (biteTimes.length >= 8) {
      final half = gaps.length ~/ 2;
      final first = mean(gaps.sublist(0, half));
      final second = mean(gaps.sublist(gaps.length - half));
      if (first != null && second != null && first > 0) speed = second / first;
    }
    return MealMetrics(
      bites: biteTimes.length,
      duration: duration,
      bitesPerMin: duration.inSeconds >= 30
          ? biteTimes.length / (duration.inMilliseconds / 60000.0)
          : null,
      meanGapSec: meanGap,
      last5GapSec: gaps.length >= 3
          ? mean(gaps.sublist(math.max(0, gaps.length - 5)))
          : null,
      gapCv: cv,
      speedChange: speed,
      pauses: gaps.where((g) => g >= 60).length,
      steadyPct: steadyPctOf(windows, rhythmicWindows),
      rhythmHz: rhythmHz,
    );
  }

  final int bites;
  final Duration duration;
  final double? bitesPerMin;

  /// Mean seconds between bites over the whole meal, and over the last 5 gaps.
  final double? meanGapSec;
  final double? last5GapSec;

  /// Spread of the gaps relative to their mean: low = even rhythm.
  final double? gapCv;

  /// Second-half mean gap ÷ first-half mean gap: below 1 = sped up.
  final double? speedChange;

  /// Gaps of a minute or more.
  final int pauses;
  final double? steadyPct;
  final double? rhythmHz;
}

/// What the person's own history says is normal for them.
class PersonalBaseline {
  const PersonalBaseline({
    required this.meals,
    this.avgGapSec,
    this.avgGapCv,
    this.avgBites,
    this.avgDurationMin,
    this.avgSteadyPct,
    this.recentSteadyPct = const [],
  });

  static const int comparisonMinMeals = 3;

  final int meals;
  final double? avgGapSec;
  final double? avgGapCv;
  final double? avgBites;
  final double? avgDurationMin;
  final double? avgSteadyPct;

  /// Steady % of the most recent meals, newest first.
  final List<double?> recentSteadyPct;

  bool get canCompare => meals >= comparisonMinMeals;
}

enum TipKind { nudge, positive, info }

class CoachTip {
  const CoachTip({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.priority,
  });

  final String id;
  final TipKind kind;
  final String title;
  final String body;
  final int priority;
}

String secs(double s) =>
    s >= 10 ? '${s.round()} s' : '${s.toStringAsFixed(1)} s';

/// Up to three tips for [m], most important first. [live] = the meal is still
/// running (summary-only rules are skipped).
List<CoachTip> coachTips(
  MealMetrics m, {
  PersonalBaseline? baseline,
  required bool live,
}) {
  if (m.bites < 2) return const [];
  final tips = <CoachTip>[];

  final shakyRecent = (baseline?.recentSteadyPct ?? const [])
      .take(5)
      .where((p) => p != null && p < kShakyBelowPct)
      .length;
  if (!live && shakyRecent >= 3) {
    tips.add(CoachTip(
      id: 'shaking_repeated',
      kind: TipKind.info,
      title: 'Shaking showed up in several meals',
      body: 'Frequent rhythmic shaking appeared in $shakyRecent of your last '
          '5 meals. Worth watching against your own usual meals.',
      priority: 90,
    ));
  }

  final steady = m.steadyPct;
  if (steady != null && steady < kShakyBelowPct) {
    tips.add(const CoachTip(
      id: 'steady_support',
      kind: TipKind.nudge,
      title: 'Steady the spoon',
      body: 'Resting your elbow on the table and bringing the bowl a little '
          'closer can make each lift steadier.',
      priority: 80,
    ));
  }

  final recent = m.last5GapSec;
  if (recent != null && recent < kMindfulGapSec) {
    tips.add(CoachTip(
      id: 'slow_down',
      kind: TipKind.nudge,
      title: 'Slow down a little',
      body: 'Your last bites came every ${secs(recent)}. Try resting the spoon '
          'between bites — about 10 s per bite gives your body time to notice '
          'fullness.',
      priority: 70,
    ));
  }

  final speed = m.speedChange;
  if (speed != null && speed < 0.8) {
    tips.add(CoachTip(
      id: 'sped_up',
      kind: TipKind.nudge,
      title: 'You sped up',
      body: 'Bites came ${((1 - speed) * 100).round()}% faster in the second '
          'half. Keeping the same easy pace to the end helps.',
      priority: 60,
    ));
  }

  final usual = baseline?.avgGapSec;
  final gap = m.meanGapSec;
  if (baseline != null && baseline.canCompare && usual != null && gap != null &&
      usual > 0) {
    final ratio = gap / usual;
    if (ratio < 0.8) {
      tips.add(CoachTip(
        id: 'faster_than_usual',
        kind: TipKind.info,
        title: 'Faster than your usual',
        body: 'About ${secs(gap)} between bites today, against your usual '
            '${secs(usual)}.',
        priority: 50,
      ));
    } else if (ratio > 1.2) {
      tips.add(CoachTip(
        id: 'slower_than_usual',
        kind: TipKind.positive,
        title: 'Calmer than your usual',
        body: 'About ${secs(gap)} between bites today, against your usual '
            '${secs(usual)}. Nice and unhurried.',
        priority: 50,
      ));
    }
  }

  if (!live && m.bites >= 15 && m.duration < const Duration(minutes: 10)) {
    tips.add(CoachTip(
      id: 'longer_meal',
      kind: TipKind.nudge,
      title: 'Take a little longer',
      body: 'This meal took ${math.max(1, m.duration.inMinutes)} min. Letting '
          'a meal stretch toward 20 minutes makes it easier to notice when '
          'you are full.',
      priority: 40,
    ));
  }

  if (!tips.any((t) => t.kind == TipKind.nudge)) {
    if (gap != null && gap >= kMindfulGapSec) {
      tips.add(CoachTip(
        id: 'mindful_pace',
        kind: TipKind.positive,
        title: 'Mindful pace',
        body: 'About ${secs(gap)} between bites — a calm, unhurried rhythm.',
        priority: 10,
      ));
    } else if (steady != null && steady >= kSteadyFromPct) {
      tips.add(const CoachTip(
        id: 'steady_hand',
        kind: TipKind.positive,
        title: 'Steady hand',
        body: 'Your spoon stayed steady through this meal.',
        priority: 10,
      ));
    }
  }

  tips.sort((a, b) => b.priority.compareTo(a.priority));
  return tips.take(3).toList(growable: false);
}
