// ai_lab_view_data.dart — everything the AI Lab page shows, as one immutable
// value, plus the actions it can trigger. The page never talks to the engine
// directly, which is what lets a widget test render any state.
import 'package:flutter/foundation.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/handedness.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/meal_tracker.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_profile_store.dart';

class RecorderView {
  const RecorderView({
    this.recording = false,
    this.marks = 0,
    this.seconds = 0,
    this.savedCount = 0,
    this.lastSavedPath,
  });

  final bool recording;
  final int marks;
  final double seconds;
  final int savedCount;
  final String? lastSavedPath;
}

class AiLabViewData {
  const AiLabViewData({
    required this.now,
    this.ready = false,
    this.error,
    this.streaming = false,
    this.spoonName,
    this.phase = MealPhase.idle,
    this.mealStart,
    this.mealEnd,
    this.bites = const [],
    this.metrics,
    this.tips = const [],
    this.rhythmicNow = false,
    this.profile,
    this.model,
    this.handPreference = HandPreference.auto,
    this.detectedHand,
    this.handMode = HandMode.neutral,
    this.recorder = const RecorderView(),
  });

  final DateTime now;

  /// False until the model asset has loaded.
  final bool ready;
  final String? error;

  /// IMU samples arrived in the last few seconds.
  final bool streaming;
  final String? spoonName;
  final MealPhase phase;

  /// Current meal, or the finished meal while [phase] is finished.
  final DateTime? mealStart;
  final DateTime? mealEnd;
  final List<BiteEvent> bites;
  final MealMetrics? metrics;
  final List<CoachTip> tips;

  /// The latest steadiness window was rhythmic.
  final bool rhythmicNow;
  final AiLabProfile? profile;
  final AiLabModel? model;
  final HandPreference handPreference;
  final Hand? detectedHand;
  final HandMode handMode;
  final RecorderView recorder;

  bool get inMeal => phase == MealPhase.eating || phase == MealPhase.paused;

  Duration? get sinceLastBite =>
      bites.isEmpty ? null : now.difference(bites.last.time);
}

abstract class AiLabActions {
  void finishMeal();
  void setHandPreference(HandPreference preference);
  void startRecording();
  void markBite();
  void undoMark();
  void cancelRecording();
  Future<String?> saveRecording();

  /// Recent gyro magnitudes (deg/s) for the raw sensor chart.
  ValueListenable<List<double>> get liveGyro;
}
