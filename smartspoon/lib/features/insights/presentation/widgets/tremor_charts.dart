// tremor_charts.dart — tremor metrics summary + chart widget.
//
// TremorCharts renders the current tremor picture from TremorMetrics (severity
// band, frequency, score) as a card/chart on the Insights dashboard, with an
// optional "view history" callback into the tremor-history page.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartspoon/features/insights/domain/models.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/premium_widgets.dart';

class TremorCharts extends StatelessWidget {
  final TremorMetrics? metrics;
  final VoidCallback? onViewHistory;

  const TremorCharts({super.key, this.metrics, this.onViewHistory});

  @override
  Widget build(BuildContext context) {
    final level = metrics?.level ?? TremorLevel.low;
    final isMeasured = metrics?.isMeasured ?? false;
    final magnitude = metrics?.currentMagnitude ?? 0.0;
    final frequency = metrics?.peakFrequencyHz ?? 0.0;
    final sampleSeconds = metrics?.sampleDurationSeconds ?? 0.0;

    Color levelColor;
    String levelLabel;
    switch (level) {
      case TremorLevel.low:
        levelColor = AppTheme.primary;
        levelLabel = 'No repeated rhythm';
        break;
      case TremorLevel.moderate:
        levelColor = AppTheme.honey;
        levelLabel = 'Some repeated rhythm';
        break;
      case TremorLevel.high:
        levelColor = AppTheme.paprika;
        levelLabel = 'More repeated rhythm';
        break;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header row with title + optional "View History" button
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Movement pattern',
                  style: GoogleFonts.figtree(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Repeated hand motion while eating',
                  style: GoogleFonts.figtree(
                    fontSize: 14,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
            if (onViewHistory != null)
              TextButton(
                onPressed: onViewHistory,
                child: Text(
                  'View History',
                  style: GoogleFonts.figtree(
                    fontSize: 12,
                    color: AppTheme.sageDeep,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (!isMeasured)
          PremiumGlassCard(
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppTheme.brandTint,
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                  child: const Icon(
                    Icons.sensors_rounded,
                    color: AppTheme.primary,
                  ),
                ),
                const SizedBox(width: AppTheme.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Collecting a steady sample',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Hold and use the spoon naturally. A reading appears after about 5 seconds of movement.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )
        else
          PremiumGlassCard(
            // Echo the card's own live tremor-level color (sage/honey/paprika)
            // — same color already driving the dot, badge, and gauge below.
            accentColor: levelColor,
            child: Column(
              children: [
                // Level indicator
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: levelColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          levelLabel,
                          style: GoogleFonts.figtree(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: levelColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: levelColor.withValues(alpha: 0.4),
                        ),
                      ),
                      // How much movement this rests on, not a quality
                      // grade. `confidence` is active-seconds/10 capped at 1,
                      // so it measures SAMPLE SIZE: it says nothing about
                      // dropped packets, gaps, impacts or clipping. Eight
                      // seconds of movement scored 80% and earned the badge
                      // "GOOD READING" even on a ragged stream. A 92% from
                      // 6 s and a 92% from 10 min must not look identical.
                      child: Text(
                        '${sampleSeconds.round()}s OF MOVEMENT',
                        style: GoogleFonts.figtree(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: levelColor,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // Metrics row
                Row(
                  children: [
                    Expanded(
                      child: _MetricBox(
                        // The share of the measured time with no repeated
                        // rhythm — the same number the AI Lab page shows.
                        label: 'Steady time',
                        value: '${(100 - magnitude / 3 * 100).round()}',
                        unit: '%',
                        color: levelColor,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _MetricBox(
                        label: 'Repeated rhythm',
                        value: frequency > 0
                            ? frequency.toStringAsFixed(1)
                            : 'Not seen',
                        unit: frequency > 0 ? 'Hz' : '',
                        color: AppTheme.caramel,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // Gauge bar
                _TremorGaugeBar(level: level, magnitude: magnitude),
                const SizedBox(height: AppTheme.spaceMd),
                Row(
                  children: [
                    Icon(
                      Icons.signal_cellular_alt_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      // Say what the percentage actually is, and what it was
                      // measured over, instead of calling sample size
                      // "quality".
                      'Measured over ${sampleSeconds.round()}s of movement',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: AppTheme.spaceSm),
                Text(
                  frequency > 0
                      ? 'Measured by Mealsense over ${sampleSeconds.round()} s: '
                            'index ${magnitude.toStringAsFixed(2)} / 3, rhythm ${frequency.toStringAsFixed(1)} Hz'
                      : 'Measured by Mealsense over ${sampleSeconds.round()} s: '
                            'index ${magnitude.toStringAsFixed(2)} / 3, no repeated rhythm',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppTheme.spaceSm),
                Text(
                  'Use this to compare your own meal trends. It is not a medical diagnosis.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _MetricBox extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color color;

  const _MetricBox({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.figtree(
              fontSize: 11,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  style: GoogleFonts.figtree(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    unit,
                    style: GoogleFonts.figtree(
                      fontSize: 11,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TremorGaugeBar extends StatelessWidget {
  final TremorLevel level;
  final double magnitude;

  const _TremorGaugeBar({required this.level, required this.magnitude});

  @override
  Widget build(BuildContext context) {
    // Normalize magnitude index (0–3 scale) to 0–1 range for gauge bar
    final normalized = (magnitude / 3.0).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Movement variation',
              style: GoogleFonts.figtree(
                fontSize: 12,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            Text(
              '${(normalized * 100).toStringAsFixed(0)}%',
              style: GoogleFonts.figtree(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: normalized,
            minHeight: 10,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.1),
            valueColor: AlwaysStoppedAnimation<Color>(
              level == TremorLevel.low
                  ? AppTheme.sageDeep
                  : level == TremorLevel.moderate
                  ? AppTheme.honey
                  : AppTheme.paprika,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'None',
              style: GoogleFonts.figtree(
                fontSize: 10,
                color: AppTheme.sageDeep,
              ),
            ),
            Text(
              'Some',
              style: GoogleFonts.figtree(fontSize: 10, color: AppTheme.honey),
            ),
            Text(
              'More',
              style: GoogleFonts.figtree(fontSize: 10, color: AppTheme.paprika),
            ),
          ],
        ),
      ],
    );
  }
}
