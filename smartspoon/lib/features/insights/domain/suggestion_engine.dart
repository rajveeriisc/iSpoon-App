// suggestion_engine.dart — suggestions derived from measurements, or none.
//
// This replaces a widget that printed two fixed sentences — "Great progress!
// Tremor decreased this week." and an eating-speed tip — regardless of what
// the person had actually done. Its own doc comment claimed they were
// "derived from the user's recent eating trends". They were not, and it was
// handed real TrendData it never read.
//
// Every rule here is answerable from stored data, and every suggestion
// carries the numbers it came from in [Suggestion.evidence], so nothing it
// says is unfalsifiable. The engine returns an EMPTY list when the data does
// not support anything — saying nothing is a valid and often correct answer.
// That is the whole point: a suggestion the measurements cannot back is worse
// than no suggestion, because it teaches the person to ignore the ones that
// are real.
import 'dart:math' as math;

import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';
import 'package:smartspoon/features/ai_lab/domain/services/personalized_eating_model.dart';
import 'package:smartspoon/features/insights/domain/meal_report.dart';

enum SuggestionKind {
  /// Something went well and is worth reinforcing.
  praise,

  /// Something the person could change.
  nudge,

  /// A neutral fact about how they eat.
  observation,

  /// The model does not know enough yet, and says so.
  learning,
}

class Suggestion {
  const Suggestion({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.evidence,
    required this.priority,
  });

  final String id;
  final SuggestionKind kind;
  final String title;
  final String body;

  /// The measurement behind this suggestion, for the UI to show on demand and
  /// for anyone auditing whether the engine is telling the truth.
  final String evidence;

  final int priority;
}

class SuggestionEngine {
  /// Meals needed before a trend across meals is worth describing.
  static const int minMealsForTrend = 4;

  /// Share of gaps below the mindful target before it is worth mentioning.
  static const double rushedShareThreshold = 0.7;

  /// Steadiness decline across a meal, in percentage points, before it is
  /// called out. Below this it is indistinguishable from ordinary variation.
  static const double steadinessDeclinePts = 12.0;

  /// Degrees the food must cool across a meal before temperature is raised.
  static const double coolingNoticeC = 12.0;

  /// Builds the suggestion list, most important first.
  ///
  /// [recentMeals] newest first. [profile] may be null before any meal has
  /// been recorded.
  static List<Suggestion> build({
    required List<MealReport> recentMeals,
    PersonalizedProfile? profile,
    int max = 3,
  }) {
    final usable = recentMeals.where((m) => m.isReportable).toList();
    final out = <Suggestion>[];

    // Nothing recorded: do not invent encouragement.
    if (usable.isEmpty) {
      return const [
        Suggestion(
          id: 'no_data',
          kind: SuggestionKind.learning,
          title: 'No meals recorded yet',
          body: 'Eat a meal with your spoon and suggestions will appear here, '
              'based on what it measures.',
          evidence: 'no meals with at least 3 bites',
          priority: 0,
        ),
      ];
    }

    final latest = usable.first;

    out.addAll(_paceAgainstOwnBaseline(latest, profile));
    out.addAll(_satiation(latest));
    out.addAll(_mindfulPace(latest));
    out.addAll(_pauses(latest));
    out.addAll(_steadinessWithinMeal(latest));
    out.addAll(_cooling(latest));
    out.addAll(_trend(usable));
    out.addAll(_mealTypeSpread(profile));
    out.addAll(_stillLearning(profile));

    out.sort((a, b) => b.priority.compareTo(a.priority));
    return out.take(max).toList(growable: false);
  }

  // ── rules ────────────────────────────────────────────────────────────────

  /// How this meal compared with the person's own usual pace.
  ///
  /// Delegates the judgement to PersonalizedEatingModel so the threshold and
  /// the per-meal-type baseline are not restated here. It returns null until
  /// that model has enough history, which is why this can be silent.
  static List<Suggestion> _paceAgainstOwnBaseline(
    MealReport m,
    PersonalizedProfile? p,
  ) {
    final pace = m.bitesPerMin;
    if (pace == null || p == null || !p.canPersonalize) return const [];

    final baseline = p.baselinePaceFor(m.meal.mealType);
    final std = math.max(p.paceStd, PersonalizedEatingModel.paceStdFloor);
    final z = (pace - baseline) / std;
    final obs = pace.toStringAsFixed(0);
    final usual = baseline.toStringAsFixed(0);
    final ev = 'this meal $obs bites/min, your usual $usual, '
        'z=${z.toStringAsFixed(1)}';

    if (z > PersonalizedEatingModel.zFlag) {
      return [
        Suggestion(
          id: 'pace_fast_vs_self',
          kind: SuggestionKind.nudge,
          title: 'Quicker than you usually eat',
          body: '$obs bites a minute, against the $usual you normally keep. '
              'Putting the spoon down between bites is the easiest way back.',
          evidence: ev,
          priority: 90,
        ),
      ];
    }
    if (z < -PersonalizedEatingModel.zFlag) {
      return [
        Suggestion(
          id: 'pace_slow_vs_self',
          kind: SuggestionKind.praise,
          title: 'Slower than your usual',
          body: '$obs bites a minute against your usual $usual. That extra '
              'time is what lets you notice you are full.',
          evidence: ev,
          priority: 70,
        ),
      ];
    }
    return [
      Suggestion(
        id: 'pace_on_baseline',
        kind: SuggestionKind.praise,
        title: 'Steady on your own rhythm',
        body: '$obs bites a minute — right where your '
            '${(m.meal.mealType ?? 'meals').toLowerCase()} normally sit.',
        evidence: ev,
        priority: 40,
      ),
    ];
  }

  /// Whether the eating rate slowed across the meal.
  ///
  /// Gated on the fit being trustworthy, because a quadratic cannot describe a
  /// meal that sped up and then slowed down, and a coefficient from a poor fit
  /// means nothing.
  static List<Suggestion> _satiation(MealReport m) {
    final f = m.intakeCurve;
    if (f == null || !f.isTrustworthy) return const [];
    final ev = 'acceleration ${f.acceleration.toStringAsFixed(1)} '
        'bites/min per min, R²=${f.rSquared.toStringAsFixed(2)}, '
        '${f.samples} bites';
    if (f.showsSatiation) {
      return [
        Suggestion(
          id: 'satiation_present',
          kind: SuggestionKind.praise,
          title: 'You eased off as you went',
          body: 'Your pace tailed away through the meal rather than holding '
              'flat, which is what it looks like when you are eating to '
              'appetite rather than to the plate.',
          evidence: ev,
          priority: 75,
        ),
      ];
    }
    if (f.acceleration > 0) {
      return [
        Suggestion(
          id: 'satiation_absent',
          kind: SuggestionKind.nudge,
          title: 'You sped up towards the end',
          body: 'Your pace rose through the meal instead of easing off. '
              'Slowing the last few bites gives fullness time to register.',
          evidence: ev,
          priority: 80,
        ),
      ];
    }
    return const [];
  }

  /// Share of gaps that met the mindful target.
  static List<Suggestion> _mindfulPace(MealReport m) {
    final share = m.mindfulSharePct;
    if (share == null || m.gapsSec.length < 4) return const [];
    final ev = '${share.round()}% of ${m.gapsSec.length} gaps were '
        '${kMindfulGapSec.round()}s or longer';
    if (share < (1 - rushedShareThreshold) * 100) {
      return [
        Suggestion(
          id: 'mindful_low',
          kind: SuggestionKind.nudge,
          title: 'Most bites came quickly after the last',
          body: 'Only ${share.round()}% of your gaps reached '
              '${kMindfulGapSec.round()} seconds. Aiming for that on even half '
              'of them changes the whole meal.',
          evidence: ev,
          priority: 85,
        ),
      ];
    }
    if (share >= 70) {
      return [
        Suggestion(
          id: 'mindful_high',
          kind: SuggestionKind.praise,
          title: 'Well spaced out',
          body: '${share.round()}% of your bites were at least '
              '${kMindfulGapSec.round()} seconds apart.',
          evidence: ev,
          priority: 50,
        ),
      ];
    }
    return const [];
  }

  static List<Suggestion> _pauses(MealReport m) {
    if (m.pauses.isEmpty) return const [];
    final longest = m.pauses
        .map((p) => p.seconds)
        .reduce(math.max);
    final n = m.pauses.length;
    return [
      Suggestion(
        id: 'pauses',
        kind: SuggestionKind.observation,
        title: n == 1 ? 'You stopped once mid-meal' : 'You stopped $n times',
        body: 'The longest break was ${(longest / 60).toStringAsFixed(1)} '
            'minutes. Breaks are counted separately from slow eating, so they '
            'do not drag your pace down.',
        evidence: '$n gap${n == 1 ? '' : 's'} of '
            '${kPauseGapSec.round()}s or more, longest '
            '${longest.round()}s',
        priority: 30,
      ),
    ];
  }

  /// Did the hand get less steady as the meal went on.
  static List<Suggestion> _steadinessWithinMeal(MealReport m) {
    final a = m.firstHalfSteadyPct, b = m.secondHalfSteadyPct;
    final change = m.steadinessChangePct;
    if (a == null || b == null || change == null) return const [];
    if (change > -steadinessDeclinePts) return const [];
    return [
      Suggestion(
        id: 'steadiness_declined',
        kind: SuggestionKind.observation,
        title: 'Your hand settled less by the end',
        body: 'Steadiness went from ${a.round()}% in the first half to '
            '${b.round()}% in the second. Resting your elbow for the last few '
            'bites often helps.',
        evidence: 'first half ${a.round()}%, second half ${b.round()}%, '
            'change ${change.toStringAsFixed(0)} points',
        priority: 65,
      ),
    ];
  }

  static List<Suggestion> _cooling(MealReport m) {
    final t = m.temperature;
    if (t == null || t.readings < 4) return const [];
    if (t.dropC < coolingNoticeC) return const [];
    final rate = m.coolingRateCPerMin;
    return [
      Suggestion(
        id: 'food_cooled',
        kind: SuggestionKind.observation,
        title: 'Your food cooled while you ate',
        body: 'It went from ${t.firstC.round()}°C to ${t.lastC.round()}°C. '
            'If that matters to you, a smaller portion kept warm beats a full '
            'plate going cold.',
        evidence: 'drop ${t.dropC.round()}°C over ${t.readings} readings'
            '${rate == null ? '' : ', ${rate.toStringAsFixed(1)}°C/min'}',
        priority: 35,
      ),
    ];
  }

  /// Direction across recent meals, by least-squares slope on pace.
  static List<Suggestion> _trend(List<MealReport> meals) {
    final pts = <List<double>>[];
    for (var i = 0; i < meals.length; i++) {
      final p = meals[i].bitesPerMin;
      // meals are newest first, so index 0 is the most recent
      if (p != null) pts.add([(meals.length - 1 - i).toDouble(), p]);
    }
    if (pts.length < minMealsForTrend) return const [];

    final n = pts.length.toDouble();
    final sx = pts.fold<double>(0, (a, p) => a + p[0]);
    final sy = pts.fold<double>(0, (a, p) => a + p[1]);
    final sxx = pts.fold<double>(0, (a, p) => a + p[0] * p[0]);
    final sxy = pts.fold<double>(0, (a, p) => a + p[0] * p[1]);
    final denom = n * sxx - sx * sx;
    if (denom.abs() < 1e-9) return const [];
    final slope = (n * sxy - sx * sy) / denom;
    final mean = sy / n;
    if (mean <= 0) return const [];

    // Only describe a direction that is material relative to the level.
    final perMeal = slope / mean;
    final ev = 'slope ${slope.toStringAsFixed(2)} bites/min per meal '
        'over ${pts.length} meals, mean ${mean.toStringAsFixed(1)}';
    if (perMeal <= -0.04) {
      return [
        Suggestion(
          id: 'trend_slowing',
          kind: SuggestionKind.praise,
          title: 'You have been slowing down across meals',
          body: 'Your pace has drifted down over your last ${pts.length} '
              'meals. That is the direction worth holding.',
          evidence: ev,
          priority: 60,
        ),
      ];
    }
    if (perMeal >= 0.04) {
      return [
        Suggestion(
          id: 'trend_speeding',
          kind: SuggestionKind.nudge,
          title: 'Your pace has crept up',
          body: 'Across your last ${pts.length} meals you have been eating a '
              'little faster each time. Worth catching early.',
          evidence: ev,
          priority: 78,
        ),
      ];
    }
    return const [];
  }

  /// Breakfast and dinner are usually not the same meal.
  static List<Suggestion> _mealTypeSpread(PersonalizedProfile? p) {
    if (p == null || !p.canPersonalize) return const [];
    final named = <String, double>{
      for (final e in p.byMealType.entries)
        if (e.value.n >= 3) e.key: p.baselinePaceFor(e.key),
    };
    if (named.length < 2) return const [];
    final sorted = named.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final fast = sorted.first, slow = sorted.last;
    if ((fast.value - slow.value).abs() < 2.0) return const [];
    return [
      Suggestion(
        id: 'meal_type_spread',
        kind: SuggestionKind.observation,
        title: 'Your meals are not all the same',
        body: 'You eat ${fast.key.toLowerCase()} at about '
            '${fast.value.toStringAsFixed(0)} bites a minute and '
            '${slow.key.toLowerCase()} at about '
            '${slow.value.toStringAsFixed(0)}. Each is judged against its own '
            'pace, not one daily average.',
        evidence: '${fast.key} ${fast.value.toStringAsFixed(1)} vs '
            '${slow.key} ${slow.value.toStringAsFixed(1)} bites/min',
        priority: 45,
      ),
    ];
  }

  /// Says plainly that it cannot judge yet, instead of guessing.
  static List<Suggestion> _stillLearning(PersonalizedProfile? p) {
    if (p == null) return const [];
    if (p.canPersonalize) return const [];
    final left = PersonalizedProfile.minMealsToPersonalize - p.mealCount;
    return [
      Suggestion(
        id: 'still_learning',
        kind: SuggestionKind.learning,
        title: 'Still learning how you eat',
        body: left > 0
            ? '${p.mealCount} meal${p.mealCount == 1 ? '' : 's'} recorded. '
                'After about $left more, this can tell an unusual meal from an '
                'ordinary one for you specifically.'
            : 'Almost there — a couple more meals and these will be judged '
                'against your own normal.',
        evidence: '${p.mealCount} meals, needs '
            '${PersonalizedProfile.minMealsToPersonalize}',
        priority: 55,
      ),
    ];
  }
}
