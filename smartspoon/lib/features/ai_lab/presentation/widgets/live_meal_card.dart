// live_meal_card.dart — the top card: what is happening right now.
import 'package:flutter/material.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/meal_tracker.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_view_data.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/bite_cycle_tracker.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/ai_lab_card.dart';

class LiveMealCard extends StatelessWidget {
  const LiveMealCard({super.key, required this.data, required this.onFinish});

  final AiLabViewData data;
  final VoidCallback onFinish;

  (String, String, Color) _headline(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    if (!data.ready) {
      return data.error != null
          ? ('Mealsense isn\'t ready', data.error!, kShakeRed)
          : ('Starting up…', 'Getting your spoon ready.', Colors.grey);
    }
    switch (data.phase) {
      case MealPhase.eating:
        return (
          'Eating now',
          'Every spoonful is counted as you eat.',
          kSteadyGreen
        );
      case MealPhase.paused:
        return (
          'Paused',
          'Still here when you are. The meal closes itself if you\'re done.',
          kShakeAmber
        );
      case MealPhase.finished:
        return (
          'Meal finished',
          'How that one went. Your next meal starts on its own.',
          primary
        );
      case MealPhase.idle:
        return data.streaming
            ? (
                'Ready — start eating',
                'Just start eating — we\'ll take it from there.',
                primary
              )
            : (
                'Waiting for your spoon',
                'Switch your spoon on and we\'ll start tracking.',
                Colors.grey
              );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (title, subtitle, color) = _headline(context);
    final m = data.metrics;
    final showStats = data.inMeal || (data.phase == MealPhase.finished && m != null);
    final duration = data.mealStart == null
        ? Duration.zero
        : (data.mealEnd ?? data.now).difference(data.mealStart!);

    return AiLabCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
            ),
            if (data.inMeal)
              TextButton.icon(
                onPressed: onFinish,
                icon: const Icon(Icons.flag_outlined, size: 18),
                label: const Text('Finish'),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
          ]),
          const SizedBox(height: 4),
          Text(subtitle,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: mutedText(context), height: 1.35)),
          // What the spoon is doing right now. The engine has tracked this all
          // along — collecting, lifting, held at the mouth, coming back — and
          // no screen showed it, so the page could only ever report totals
          // after the fact.
          if (data.streaming) ...[
            const SizedBox(height: 12),
            _PhaseChip(phase: data.cyclePhase, calibrated: data.calibrated),
          ],
          if (showStats) ...[
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${data.bites.length}',
                          style: theme.textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: theme.colorScheme.primary)),
                      Text(data.inMeal ? 'bites this meal' : 'bites',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: mutedText(context))),
                    ],
                  ),
                ),
                if (data.phase == MealPhase.eating && data.sinceLastBite != null)
                  _PaceRing(since: data.sinceLastBite!),
              ],
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: StatTile(value: mmss(duration), label: 'Meal time')),
              Expanded(
                child: StatTile(
                  value: m?.bitesPerMin == null
                      ? '—'
                      : m!.bitesPerMin!.toStringAsFixed(1),
                  label: 'Bites / min',
                ),
              ),
              Expanded(
                child: StatTile(
                    value: gapText(m?.meanGapSec), label: 'Between bites'),
              ),
            ]),
          ],
        ],
      ),
    );
  }
}

/// Seconds since the last bite, filling toward the 10 s mindful pace.
class _PaceRing extends StatelessWidget {
  const _PaceRing({required this.since});

  final Duration since;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = since.inMilliseconds / 1000.0;
    final reached = s >= kMindfulGapSec;
    final color = reached ? kSteadyGreen : theme.colorScheme.primary;
    return SizedBox(
      width: 92,
      height: 92,
      child: Stack(alignment: Alignment.center, children: [
        SizedBox.expand(
          child: CircularProgressIndicator(
            value: (s / kMindfulGapSec).clamp(0.0, 1.0),
            strokeWidth: 8,
            strokeCap: StrokeCap.round,
            backgroundColor: color.withValues(alpha: 0.12),
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Text(reached ? '✓' : '${s.floor()} s',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w900, color: color)),
          Text('since bite',
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontSize: 10, color: mutedText(context))),
        ]),
      ]),
    );
  }
}


/// Live eating-cycle phase.
class _PhaseChip extends StatelessWidget {
  const _PhaseChip({required this.phase, required this.calibrated});

  final BitePhase phase;
  final bool calibrated;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Before the resting-pose reference has settled the phases are not
    // trustworthy, so say that rather than show a confident wrong label.
    if (!calibrated) {
      return _chip(
        context,
        Icons.tune_rounded,
        'Getting to know how you hold the spoon',
        theme.colorScheme.primary,
        muted: true,
      );
    }

    final (icon, label, color) = switch (phase) {
      BitePhase.load => (
          Icons.restaurant_rounded,
          'Collecting food',
          theme.colorScheme.primary,
        ),
      BitePhase.lift => (
          Icons.arrow_upward_rounded,
          'Lifting to your mouth',
          theme.colorScheme.primary,
        ),
      BitePhase.mouth => (
          Icons.check_circle_rounded,
          'At your mouth',
          kSteadyGreen,
        ),
      BitePhase.returning => (
          Icons.arrow_downward_rounded,
          'Going back down',
          theme.colorScheme.primary,
        ),
      BitePhase.idle => (
          Icons.pause_circle_outline_rounded,
          'Spoon at rest',
          Colors.grey,
        ),
    };
    return _chip(context, icon, label, color);
  }

  Widget _chip(BuildContext context, IconData icon, String label, Color color,
      {bool muted = false}) {
    final c = muted ? mutedText(context) : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.28)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: c,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
      ]),
    );
  }
}
