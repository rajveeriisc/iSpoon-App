// recent_meals_card.dart — the last five meals AI Lab saw.
import 'package:flutter/material.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_profile_store.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/ai_lab_card.dart';

String mealWhen(DateTime t, DateTime now) {
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today $hm';
  if (diff == 1) return 'Yesterday $hm';
  return '${t.day}/${t.month} $hm';
}

class RecentMealsCard extends StatelessWidget {
  const RecentMealsCard({super.key, required this.meals, required this.now});

  final List<MealSummary> meals;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = meals.take(5).toList();
    return AiLabCard(
      title: 'Recent meals',
      icon: Icons.history_rounded,
      child: Column(children: [
        for (var i = 0; i < shown.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              border: i == shown.length - 1
                  ? null
                  : Border(
                      bottom: BorderSide(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.06))),
            ),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(mealWhen(shown[i].start, now),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  Text(
                    '${shown[i].bites} bites · '
                    '${shown[i].durationMin.toStringAsFixed(shown[i].durationMin < 10 ? 1 : 0)} min · '
                    '${gapText(shown[i].meanGapSec)} apart',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: mutedText(context)),
                  ),
                ]),
              ),
              if (shown[i].steadyPct != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: steadinessColor(shown[i].steadyPct!).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('${shown[i].steadyPct!.round()}% steady',
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: steadinessColor(shown[i].steadyPct!))),
                ),
            ]),
          ),
      ]),
    );
  }
}
