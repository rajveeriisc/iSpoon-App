import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/handedness.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_profile_store.dart';

MealSummary summary(int i, {double gap = 10, double? steady = 95}) =>
    MealSummary(
      start: DateTime(2026, 9, 1).add(Duration(hours: i)),
      bites: 20,
      durationMin: 12,
      meanGapSec: gap,
      steadyPct: steady,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('learns with an EWMA and keeps the last 20 meals, newest first',
      () async {
    final store = AiLabProfileStore();
    await store.load();
    await store.recordMeal('spoon-1', summary(0, gap: 10));
    await store.recordMeal('spoon-1', summary(1, gap: 20));
    final p = store.profileFor('spoon-1');
    expect(p.mealCount, 2);
    expect(p.avgGapSec, closeTo(10 + 0.2 * (20 - 10), 1e-9));
    expect(p.recent.first.meanGapSec, 20);

    for (var i = 2; i < 25; i++) {
      await store.recordMeal('spoon-1', summary(i));
    }
    expect(store.profileFor('spoon-1').recent, hasLength(20));
    expect(store.profileFor('spoon-1').mealCount, 25);
  });

  test('unmeasured values do not drag the averages', () async {
    final store = AiLabProfileStore();
    await store.load();
    await store.recordMeal('k', summary(0, steady: 90));
    await store.recordMeal('k', summary(1, steady: null));
    expect(store.profileFor('k').avgSteadyPct, 90);
  });

  test('survives a restart, including hand settings', () async {
    final a = AiLabProfileStore();
    await a.load();
    await a.recordMeal('k', summary(0));
    await a.setHandPreference('k', HandPreference.left);
    await a.setDetectedHand('k', Hand.right);

    final b = AiLabProfileStore();
    await b.load();
    final p = b.profileFor('k');
    expect(p.mealCount, 1);
    expect(p.handPreference, HandPreference.left);
    expect(p.detectedHand, Hand.right);
    expect(p.recent.single.bites, 20);
  });

  test('tolerates older or partial saved data', () async {
    SharedPreferences.setMockInitialValues({
      AiLabProfileStore.prefsKey: jsonEncode({
        'k': {'spoonKey': 'k', 'mealCount': 2, 'handPreference': 'sideways'},
      }),
    });
    final store = AiLabProfileStore();
    await store.load();
    final p = store.profileFor('k');
    expect(p.mealCount, 2);
    expect(p.handPreference, HandPreference.auto);
    expect(p.recent, isEmpty);
    expect(p.baseline.canCompare, isFalse);
  });

  test('an unknown spoon gets an empty profile', () async {
    final store = AiLabProfileStore();
    await store.load();
    expect(store.profileFor('new').mealCount, 0);
  });
}
