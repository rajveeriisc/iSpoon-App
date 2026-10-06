// ai_lab_view.dart — the AI Lab page body, built only from AiLabViewData.
import 'package:flutter/material.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_view_data.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/ai_lab_card.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/bite_timeline.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/coach_card.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/eating_pattern_card.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/live_meal_card.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/model_data_section.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/recent_meals_card.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/steadiness_card.dart';

class AiLabView extends StatelessWidget {
  const AiLabView({super.key, required this.data, required this.actions});

  final AiLabViewData data;
  final AiLabActions actions;

  @override
  Widget build(BuildContext context) {
    final start = data.mealStart;
    final recent = data.profile?.recent ?? const [];
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 110),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(data: data),
          const SizedBox(height: 18),
          LiveMealCard(data: data, onFinish: actions.finishMeal),
          if (start != null && data.bites.isNotEmpty) ...[
            const SizedBox(height: 14),
            BiteTimeline(
              bites: data.bites,
              start: start,
              end: data.mealEnd ?? data.now,
            ),
          ],
          const SizedBox(height: 14),
          CoachCard(tips: data.tips, inMeal: data.inMeal),
          const SizedBox(height: 14),
          SteadinessCard(
            metrics: data.metrics,
            reference: data.model?.steadiness,
            live: data.inMeal,
            rhythmicNow: data.rhythmicNow,
          ),
          const SizedBox(height: 14),
          EatingPatternCard(profile: data.profile, current: data.metrics),
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 14),
            RecentMealsCard(meals: recent, now: data.now),
          ],
          const SizedBox(height: 14),
          ModelDataSection(data: data, actions: actions),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.data});

  final AiLabViewData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = data.streaming;
    final chipColor = live ? kSteadyGreen : Colors.grey;
    return Row(children: [
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [theme.colorScheme.primary, theme.colorScheme.secondary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.psychology_alt_rounded, color: Colors.white, size: 24),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Mealsense',
              style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800, color: theme.colorScheme.primary)),
          Text(
            data.spoonName == null ? 'Your eating coach' : 'Your eating coach · ${data.spoonName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: mutedText(context)),
          ),
        ]),
      ),
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: chipColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: chipColor.withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(shape: BoxShape.circle, color: chipColor)),
          const SizedBox(width: 6),
          Text(live ? 'LIVE' : 'OFFLINE',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: chipColor)),
        ]),
      ),
    ]);
  }
}
