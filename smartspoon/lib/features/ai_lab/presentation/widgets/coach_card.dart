// coach_card.dart — the AI coach's tips for this meal.
import 'package:flutter/material.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/ai_lab_card.dart';

class CoachCard extends StatelessWidget {
  const CoachCard({super.key, required this.tips, required this.inMeal});

  final List<CoachTip> tips;
  final bool inMeal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AiLabCard(
      title: 'Your coach',
      icon: Icons.insights_rounded,
      child: tips.isEmpty
          ? Text(
              inMeal
                  ? 'A few more bites and there will be something to say.'
                  : 'Eat a meal with your spoon to see how your pace and '
                      'steadiness are doing.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: mutedText(context), height: 1.4),
            )
          : Column(children: [
              for (var i = 0; i < tips.length; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                _TipRow(tip: tips[i]),
              ],
            ]),
    );
  }
}

class _TipRow extends StatelessWidget {
  const _TipRow({required this.tip});

  final CoachTip tip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = switch (tip.kind) {
      // Not tips_and_updates (a lightbulb with sparkles): the sparkle-bulb is
      // the stock "AI suggestion" glyph every template ships with. This is
      // the same icon SuggestionRow uses for a nudge, so one kind of advice
      // looks the same wherever it appears.
      TipKind.nudge => (Icons.adjust_rounded, kShakeAmber),
      TipKind.positive => (Icons.check_circle_rounded, kSteadyGreen),
      TipKind.info => (Icons.info_rounded, theme.colorScheme.primary),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tip.title,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text(tip.body,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
                    height: 1.35)),
          ]),
        ),
      ]),
    );
  }
}
