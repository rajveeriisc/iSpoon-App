// steadiness_card.dart — hand steadiness for this meal against normal eaters.
import 'package:flutter/material.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/ai_lab_card.dart';

class SteadinessCard extends StatelessWidget {
  const SteadinessCard({
    super.key,
    required this.metrics,
    required this.reference,
    required this.live,
    required this.rhythmicNow,
  });

  /// A reading from a few seconds of eating would jump around; wait this long.
  static const Duration minMealTime = Duration(seconds: 20);

  final MealMetrics? metrics;
  final SteadinessReference? reference;
  final bool live;
  final bool rhythmicNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = metrics;
    final pct = m?.steadyPct;
    if (m == null || pct == null || m.duration < minMealTime) {
      return AiLabCard(
        title: 'Hand steadiness',
        icon: Icons.back_hand_outlined,
        child: Text('Shows after you have eaten for a little while.',
            style: theme.textTheme.bodySmall?.copyWith(color: mutedText(context))),
      );
    }
    final normalMin = reference?.normalSteadyPctMin ?? kSteadyFromPct;
    final hz = m.rhythmHz;
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: mutedText(context), height: 1.35);
    return AiLabCard(
      title: 'Hand steadiness',
      icon: Icons.back_hand_outlined,
      trailing: live
          ? Text(rhythmicNow ? 'Now: shaking' : 'Now: steady',
              style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: rhythmicNow ? kShakeAmber : kSteadyGreen))
          : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${pct.round()}%',
              style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900, color: steadinessColor(pct))),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                '${steadinessLabel(pct)} · ${live ? 'so far' : 'this meal'}',
                style:
                    theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        _RangeBar(value: pct, normalMin: normalMin),
        const SizedBox(height: 8),
        Text(
          'Share of the meal without rhythmic shaking. Normal eaters: '
          '${normalMin.round()}–100%.',
          style: muted,
        ),
        const SizedBox(height: 6),
        // Always says what the rhythm check found. Showing this line only on a
        // hit left the commonest result — a steady hand — as a blank space,
        // which reads as "the feature is broken" rather than "nothing found".
        Text(
          hz != null && pct < 100
              ? 'Shaking had a rhythm around ${hz.toStringAsFixed(1)} Hz.'
              : 'No rhythmic shaking found between '
                  '${(reference?.bandLoHz ?? 4).round()} and '
                  '${(reference?.bandHiHz ?? 12).round()} Hz — the hand moved, '
                  'but not to a steady beat.',
          style: muted,
        ),
        const SizedBox(height: 6),
        Text('A steadiness measure, not a diagnosis.',
            style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11, fontStyle: FontStyle.italic, color: mutedText(context))),
      ]),
    );
  }
}

class _RangeBar extends StatelessWidget {
  const _RangeBar({required this.value, required this.normalMin});

  final double value;
  final double normalMin;

  @override
  Widget build(BuildContext context) {
    final track = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final x = (value / 100).clamp(0.0, 1.0) * w;
      final lo = (normalMin / 100).clamp(0.0, 1.0) * w;
      return SizedBox(
        height: 18,
        width: w,
        child: Stack(children: [
          Positioned(
            left: 0,
            right: 0,
            top: 5,
            height: 8,
            child: DecoratedBox(
              decoration:
                  BoxDecoration(color: track, borderRadius: BorderRadius.circular(4)),
            ),
          ),
          Positioned(
            left: lo,
            right: 0,
            top: 5,
            height: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                  color: kSteadyGreen.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(4)),
            ),
          ),
          Positioned(
            left: (x - 3).clamp(0.0, w - 6),
            top: 0,
            width: 6,
            height: 18,
            child: DecoratedBox(
              decoration: BoxDecoration(
                  color: steadinessColor(value),
                  borderRadius: BorderRadius.circular(3)),
            ),
          ),
        ]),
      );
    });
  }
}
