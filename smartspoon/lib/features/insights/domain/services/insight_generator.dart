// insight_generator.dart — turns raw metrics into human-readable insights/tips.
//
// Defines the Insight value object (title, message, accent color, optional
// action label) and the generator logic that inspects meal/tremor/temperature
// metrics and produces the coaching observations shown on the Insights
// dashboard (e.g. "You ate faster than usual", "Tremor was elevated today").
// Presentation-adjacent (carries a Color) but has no widget dependency, so the
// rules stay unit-testable.
import 'package:flutter/material.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import '../models.dart';

/// A single computed observation surfaced on the Insights dashboard.
///
/// Unlike the data models in `models.dart`, this is presentation-adjacent
/// (it carries a [Color] and copy meant to be shown directly to the user),
/// but it deliberately has no Flutter UI/widget dependency so it stays easy
/// to unit test.
@immutable
class Insight {
  final String type;
  final String title;
  final String message;
  final Color accentColor;

  /// Optional label describing what action a "learn more" / "act on this"
  /// button would perform. Not wired to navigation — purely descriptive
  /// metadata for now.
  final String? actionLabel;

  const Insight({
    required this.type,
    required this.title,
    required this.message,
    required this.accentColor,
    this.actionLabel,
  });
}

/// Computes [Insight]s by comparing the most recent 7 days of activity
/// against the 7 days before that (a "this week vs last week" comparison).
///
/// This is a pure function over already-fetched data — it does not touch
/// the network/database itself. Callers (e.g. `InsightsController`) are
/// expected to have already loaded at least 14 days of history via
/// `fetchHistory(14)` (or more) before calling this.
class InsightGenerator {
  const InsightGenerator._();

  /// Minimum number of percent-points of change required before we bother
  /// surfacing an insight. Below this, week-to-week noise in a handful of
  /// meals is not meaningful enough to claim a "trend" to the user.
  static const double _changeThresholdPercent = 10.0;

  /// Minimum number of data points required in *each* week for an average
  /// to be considered meaningful rather than a fluke from one or two meals.
  static const int _minPointsPerWeek = 2;

  /// Builds the list of insights to show on the dashboard.
  ///
  /// [tremorSummaries] and [dailySummaries] should be the controller's daily
  /// rollups (`DailyTremorSummary` / `DailyBiteSummary`), ideally covering at
  /// least the last 14 days.
  static List<Insight> generate({
    required List<DailyTremorSummary> tremorSummaries,
    required List<DailyBiteSummary> dailySummaries,
    DateTime? now,
  }) {
    final today = now ?? DateTime.now();
    final insights = <Insight>[];

    final tremorInsight = _tremorInsight(tremorSummaries, today);
    if (tremorInsight != null) insights.add(tremorInsight);

    final paceInsight = _paceInsight(dailySummaries, today);
    if (paceInsight != null) insights.add(paceInsight);

    return insights;
  }

  /// Splits dated values into "this week" (last 7 days, inclusive of today)
  /// and "prior week" (the 7 days before that), returning the average of
  /// each bucket, or null if a bucket doesn't have enough points to trust.
  static ({double thisWeek, double priorWeek})? _weekOverWeekAverages(
    List<({DateTime date, double value})> points,
    DateTime now,
  ) {
    final thisWeekStart = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 6));
    final priorWeekStart = thisWeekStart.subtract(const Duration(days: 7));
    final endExclusive =
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1));

    final thisWeekValues = <double>[];
    final priorWeekValues = <double>[];

    for (final p in points) {
      final d = DateTime(p.date.year, p.date.month, p.date.day);
      if (!d.isBefore(thisWeekStart) && d.isBefore(endExclusive)) {
        thisWeekValues.add(p.value);
      } else if (!d.isBefore(priorWeekStart) && d.isBefore(thisWeekStart)) {
        priorWeekValues.add(p.value);
      }
    }

    if (thisWeekValues.length < _minPointsPerWeek ||
        priorWeekValues.length < _minPointsPerWeek) {
      return null;
    }

    final thisWeekAvg =
        thisWeekValues.reduce((a, b) => a + b) / thisWeekValues.length;
    final priorWeekAvg =
        priorWeekValues.reduce((a, b) => a + b) / priorWeekValues.length;

    return (thisWeek: thisWeekAvg, priorWeek: priorWeekAvg);
  }

  /// Percent change from [from] to [to]. Returns null if [from] is ~0,
  /// since a percent change against (near) zero is meaningless/infinite.
  static double? _percentChange(double from, double to) {
    if (from.abs() < 1e-9) return null;
    return ((to - from) / from) * 100;
  }

  static Insight? _tremorInsight(
    List<DailyTremorSummary> summaries,
    DateTime now,
  ) {
    final points = summaries
        .map((s) => (date: s.date, value: s.avgMagnitude))
        .toList();
    final averages = _weekOverWeekAverages(points, now);
    if (averages == null) return null;

    final change = _percentChange(averages.priorWeek, averages.thisWeek);
    if (change == null) return null;
    if (change.abs() < _changeThresholdPercent) return null;

    final pct = change.abs().round();
    if (change < 0) {
      // Tremor magnitude went down → improvement.
      return Insight(
        type: 'Great Progress',
        title: 'Tremor levels decreased by $pct%',
        message:
            'Your tremor stability has improved over the past week compared to the week before.',
        accentColor: AppTheme.sageDeep,
        actionLabel: 'View tremor trends',
      );
    }

    // Tremor magnitude went up → caution. Escalate to the more serious
    // accent color once the change is large.
    final isSevere = pct >= 30;
    return Insight(
      type: isSevere ? 'Tremor Alert' : 'Tremor Notice',
      title: 'Tremor levels increased by $pct%',
      message: isSevere
          ? 'Your tremor activity has risen notably this week. Consider mentioning this to your care provider.'
          : 'Your tremor activity is a bit higher than last week. Keep an eye on it.',
      accentColor: isSevere ? AppTheme.paprika : AppTheme.honey,
      actionLabel: 'View tremor trends',
    );
  }

  static Insight? _paceInsight(
    List<DailyBiteSummary> summaries,
    DateTime now,
  ) {
    // Eating pace, in bites/minute. Higher = eating faster.
    final points = summaries
        .where((s) => s.avgPaceBpm > 0)
        .map((s) => (date: s.date, value: s.avgPaceBpm))
        .toList();
    final averages = _weekOverWeekAverages(points, now);
    if (averages == null) return null;

    final change = _percentChange(averages.priorWeek, averages.thisWeek);
    if (change == null) return null;
    if (change.abs() < _changeThresholdPercent) return null;

    final pct = change.abs().round();
    if (change > 0) {
      // Pace increased → eating faster → caution.
      return Insight(
        type: 'Eating Speed Alert',
        title: 'Pace increased by $pct%',
        message:
            'Try to slow down and chew more thoroughly for better digestion.',
        accentColor: AppTheme.honey,
        actionLabel: 'View eating pattern',
      );
    }

    // Pace decreased → eating slower → generally a positive change.
    return Insight(
      type: 'Nice Pacing',
      title: 'Eating pace slowed by $pct%',
      message:
          'You\'ve been taking your time at meals this week compared to last — great for digestion.',
      accentColor: AppTheme.sageDeep,
      actionLabel: 'View eating pattern',
    );
  }
}
