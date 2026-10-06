import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';

final t0 = DateTime(2026, 9, 11, 12);

MealMetrics meal(List<double> gaps,
    {int windows = 0, int rhythmic = 0, Duration? extra}) {
  final times = [t0];
  for (final g in gaps) {
    times.add(times.last.add(Duration(milliseconds: (g * 1000).round())));
  }
  return MealMetrics.from(
    biteTimes: times,
    start: t0,
    end: times.last.add(extra ?? Duration.zero),
    windows: windows,
    rhythmicWindows: rhythmic,
  );
}

List<String> ids(List<CoachTip> t) => [for (final x in t) x.id];

void main() {
  test('metrics: gaps, regularity, speed change, pauses', () {
    final m = meal([12, 12, 12, 12, 6, 6, 6, 6, 70]);
    expect(m.bites, 10);
    expect(m.meanGapSec, closeTo(142 / 9, 1e-9));
    expect(m.last5GapSec, closeTo((6 + 6 + 6 + 6 + 70) / 5, 1e-9));
    expect(m.speedChange, closeTo(((6 + 6 + 6 + 70) / 4) / 12, 1e-9));
    expect(m.pauses, 1);
    expect(m.gapCv, isNotNull);
  });

  test('no tips before two bites', () {
    expect(coachTips(meal([]), live: true), isEmpty);
  });

  test('fast recent pace → slow-down nudge first', () {
    final tips = coachTips(meal([4, 4, 4, 4, 4]), live: true);
    expect(tips.first.id, 'slow_down');
    expect(tips.first.kind, TipKind.nudge);
  });

  test('a calm pace gets positive feedback', () {
    final tips = coachTips(meal([12, 13, 11, 12]), live: true);
    expect(ids(tips), ['mindful_pace']);
  });

  test('speeding up in the second half is noticed', () {
    expect(ids(coachTips(meal([12, 12, 12, 12, 12, 6, 6, 6, 6, 6, 6]),
            live: true)),
        contains('sped_up'));
  });

  test('comparison with your usual needs 3 meals', () {
    const two = PersonalBaseline(meals: 2, avgGapSec: 12);
    const three = PersonalBaseline(meals: 3, avgGapSec: 12);
    final m = meal([5, 5, 5, 5]);
    expect(ids(coachTips(m, baseline: two, live: true)),
        isNot(contains('faster_than_usual')));
    expect(ids(coachTips(m, baseline: three, live: true)),
        contains('faster_than_usual'));
  });

  test('short-meal advice only in the summary', () {
    final m = meal(List.filled(19, 4.0));
    expect(ids(coachTips(m, live: true)), isNot(contains('longer_meal')));
    expect(ids(coachTips(m, live: false)), contains('longer_meal'));
  });

  test('shaky meal → steady-support nudge first', () {
    final tips =
        coachTips(meal([12, 12, 12], windows: 10, rhythmic: 5), live: true);
    expect(tips.first.id, 'steady_support');
  });

  test('shaking across recent meals → gentle doctor note in the summary', () {
    const b = PersonalBaseline(
        meals: 5, recentSteadyPct: [60, 70, 50, 95, 99]);
    final m = meal([12, 12, 12], windows: 10, rhythmic: 0);
    expect(coachTips(m, baseline: b, live: false).first.id, 'shaking_repeated');
    expect(ids(coachTips(m, baseline: b, live: true)),
        isNot(contains('shaking_repeated')));
  });

  test('never more than three tips', () {
    const b = PersonalBaseline(
        meals: 5, avgGapSec: 20, recentSteadyPct: [60, 70, 50]);
    final m = meal(
        [12, 12, 12, 12, 12, 12, 3, 3, 3, 3, 3, 3, 3, 3, 3],
        windows: 10,
        rhythmic: 6);
    expect(coachTips(m, baseline: b, live: false), hasLength(3));
  });
}
