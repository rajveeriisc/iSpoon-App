// eating_pattern_card.dart — this meal against the person's own usual.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_profile_store.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/ai_lab_card.dart';

String rhythmLabel(double? cv) => cv == null
    ? '—'
    : cv < 0.25
        ? 'Even'
        : cv < 0.5
            ? 'Fairly even'
            : 'Varied';

class EatingPatternCard extends StatelessWidget {
  const EatingPatternCard({super.key, required this.profile, required this.current});

  final AiLabProfile? profile;
  final MealMetrics? current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = profile;
    final m = current;
    if ((p == null || p.mealCount == 0) && m == null) {
      return AiLabCard(
        title: 'Your eating pattern',
        icon: Icons.insights_rounded,
        child: Text(
          'After your first meal, your pace and rhythm appear here — and after '
          '${PersonalBaseline.comparisonMinMeals} meals, how each meal compares '
          'with your usual.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: mutedText(context), height: 1.4),
        ),
      );
    }
    // Non-null only once there are enough meals to compare against.
    final usual = (p != null && p.baseline.canCompare) ? p : null;
    final canCompare = usual != null;
    final gaps = [
      for (final s in (p?.recent ?? const <MealSummary>[]).take(10).toList().reversed)
        if (s.meanGapSec != null) s.meanGapSec!,
    ];

    // Between meals there is no "this meal", so the comparison column was a
    // full column of em-dashes next to the only numbers that meant anything.
    // Collapse to one column until there is actually something to compare.
    final live = m != null;

    String pace(double? v) => gapText(v);
    String mins(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)} min';

    return AiLabCard(
      title: 'Your eating pattern',
      icon: Icons.insights_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (live)
          _Row(
            label: '',
            now: 'This meal',
            usual: canCompare ? 'Your usual' : '',
            header: true,
          )
        else
          _Row(label: '', now: 'Your usual', usual: '', header: true),
        _Row(
          label: 'Time between bites',
          now: live ? pace(m.meanGapSec) : pace(usual?.avgGapSec),
          usual: !live || usual == null ? '' : pace(usual.avgGapSec),
        ),
        _Row(
          label: 'Rhythm',
          now: live ? rhythmLabel(m.gapCv) : rhythmLabel(usual?.avgGapCv),
          usual: !live || usual == null ? '' : rhythmLabel(usual.avgGapCv),
        ),
        // Only ever describes a meal in progress, so it has nothing to say
        // between meals.
        if (live)
          _Row(
            label: 'Pace change',
            now: m.speedChange == null
                ? '—'
                : m.speedChange! < 0.8
                    ? 'Sped up'
                    : m.speedChange! > 1.25
                        ? 'Slowed down'
                        : 'Steady',
            usual: '',
          ),
        _Row(
          label: 'Meal length',
          now: live
              ? '${(m.duration.inSeconds / 60).toStringAsFixed(1)} min'
              : mins(usual?.avgDurationMin),
          usual: !live || usual?.avgDurationMin == null
              ? ''
              : mins(usual!.avgDurationMin),
        ),
        if (!canCompare) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: ((p?.mealCount ?? 0) / PersonalBaseline.comparisonMinMeals)
                  .clamp(0.0, 1.0),
              minHeight: 7,
              backgroundColor:
                  theme.colorScheme.onSurface.withValues(alpha: 0.08),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Learning your style — '
            '${PersonalBaseline.comparisonMinMeals - (p?.mealCount ?? 0)} more '
            'meal(s) until personal comparisons.',
            style: theme.textTheme.bodySmall?.copyWith(color: mutedText(context)),
          ),
        ],
        if (gaps.length >= 2) ...[
          const SizedBox(height: 14),
          SizedBox(
            height: 70,
            child: LineChart(LineChartData(
              gridData: const FlGridData(show: false),
              titlesData: const FlTitlesData(show: false),
              borderData: FlBorderData(show: false),
              lineTouchData: const LineTouchData(enabled: false),
              minY: 0,
              maxY: [...gaps, kMindfulGapSec].reduce((a, b) => a > b ? a : b) * 1.2,
              extraLinesData: ExtraLinesData(horizontalLines: [
                HorizontalLine(
                  y: kMindfulGapSec,
                  color: kSteadyGreen.withValues(alpha: 0.6),
                  strokeWidth: 1,
                  dashArray: const [4, 4],
                ),
              ]),
              lineBarsData: [
                LineChartBarData(
                  spots: [
                    for (var i = 0; i < gaps.length; i++) FlSpot(i.toDouble(), gaps[i]),
                  ],
                  isCurved: true,
                  color: theme.colorScheme.primary,
                  barWidth: 2.5,
                  dotData: const FlDotData(show: true),
                ),
              ],
            )),
          ),
          const SizedBox(height: 4),
          Text('Seconds between bites, last ${gaps.length} meals · dashed = 10 s mindful pace',
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontSize: 11, color: mutedText(context))),
        ],
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.now, required this.usual, this.header = false});

  final String label;
  final String now;
  final String usual;
  final bool header;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = header
        ? theme.textTheme.bodySmall
            ?.copyWith(fontSize: 11, color: mutedText(context), fontWeight: FontWeight.w700)
        : theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w800);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          flex: 5,
          child: Text(label,
              style: theme.textTheme.bodySmall?.copyWith(color: mutedText(context))),
        ),
        Expanded(flex: 3, child: Text(now, style: style, textAlign: TextAlign.right)),
        Expanded(flex: 3, child: Text(usual, style: style, textAlign: TextAlign.right)),
      ]),
    );
  }
}
