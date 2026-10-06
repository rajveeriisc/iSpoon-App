import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/handedness.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/meal_tracker.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_profile_store.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_view_data.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/ai_lab_view.dart';

import 'ai_lab_fixtures.dart';

class _NoActions implements AiLabActions {
  final _gyro = ValueNotifier<List<double>>(const [10, 40, 80, 30]);
  @override
  ValueListenable<List<double>> get liveGyro => _gyro;
  @override
  void cancelRecording() {}
  @override
  void finishMeal() {}
  @override
  void markBite() {}
  @override
  Future<String?> saveRecording() async => null;
  @override
  void setHandPreference(HandPreference preference) {}
  @override
  void startRecording() {}
  @override
  void undoMark() {}
}

void main() {
  final model = loadModel();
  final now = DateTime(2026, 9, 11, 13, 5);
  final start = now.subtract(const Duration(minutes: 2));
  final bites = [
    for (var i = 0; i < 12; i++)
      BiteEvent(
        time: start.add(Duration(seconds: 4 + i * 9)),
        probability: 0.8,
        rhythmicShare: i == 5 ? 0.34 : (i == 9 ? 1 : 0),
      ),
  ];
  final metrics = MealMetrics.from(
    biteTimes: [for (final b in bites) b.time],
    start: start,
    end: now,
    windows: 110,
    rhythmicWindows: 6,
    rhythmHz: 5.1,
  );
  final profile = AiLabProfile(spoonKey: 'k', mealCount: 4, avgGapSec: 7.5, avgGapCv: 0.3,
      avgBites: 18, avgDurationMin: 11, recent: [
    for (var i = 0; i < 6; i++)
      MealSummary(
          start: now.subtract(Duration(hours: 5 * (i + 1))),
          bites: 15 + i,
          durationMin: 9 + i.toDouble(),
          meanGapSec: 6.0 + i,
          steadyPct: 100.0 - i * 6),
  ]);

  final states = <String, AiLabViewData>{
    'waiting': AiLabViewData(now: now, ready: true, model: model),
    'eating': AiLabViewData(
      now: now,
      ready: true,
      streaming: true,
      spoonName: 'iSpoon Pro with a rather long name',
      phase: MealPhase.eating,
      mealStart: start,
      bites: bites,
      metrics: metrics,
      tips: coachTips(metrics, baseline: profile.baseline, live: true),
      rhythmicNow: true,
      profile: profile,
      model: model,
      detectedHand: Hand.right,
      handMode: HandMode.right,
    ),
    'finished': AiLabViewData(
      now: now,
      ready: true,
      streaming: true,
      phase: MealPhase.finished,
      mealStart: start,
      mealEnd: bites.last.time,
      bites: bites,
      metrics: metrics,
      tips: coachTips(metrics, baseline: profile.baseline, live: false),
      profile: profile,
      model: model,
    ),
  };

  for (final brightness in Brightness.values) {
    for (final entry in states.entries) {
      testWidgets('${entry.key} renders at 360 px (${brightness.name})', (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(360, 800);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness, useMaterial3: true),
          home: Scaffold(body: AiLabView(data: entry.value, actions: _NoActions())),
        ));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(find.text('AI coach'), findsOneWidget);
        expect(find.text('Hand steadiness'), findsOneWidget);
        switch (entry.key) {
          case 'waiting':
            expect(find.text('Waiting for your spoon'), findsOneWidget);
          case 'eating':
            expect(find.text('Eating now'), findsOneWidget);
            expect(find.text('12'), findsOneWidget);
            expect(find.text('Bite timeline'), findsOneWidget);
            expect(find.text('Now: shaking'), findsOneWidget);
          case 'finished':
            expect(find.text('Meal finished'), findsOneWidget);
            expect(find.text('Recent meals'), findsOneWidget);
        }

        // The collapsed "Model & data" section opens without overflow too.
        await tester.ensureVisible(find.text('Model & data'));
        await tester.tap(find.text('Model & data'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        expect(find.text('Eating hand'), findsOneWidget);
      });
    }
  }
}
