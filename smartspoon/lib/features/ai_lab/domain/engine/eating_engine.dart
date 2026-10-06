// eating_engine.dart — one spoon's IMU stream in, meals and bites out.
//
// Pure Dart (no Flutter), so the whole pipeline can be replayed from a CSV in
// a test exactly as it runs on the phone.
import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/bite_detector.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/bite_features.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/handedness.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/imu_window.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/meal_tracker.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/steadiness_analyzer.dart';

/// What one [EatingEngine.feed] call changed.
class EngineUpdate {
  const EngineUpdate({this.bite, this.window, this.decidedHand});

  static const none = EngineUpdate();

  final BiteEvent? bite;
  final SteadinessResult? window;
  final Hand? decidedHand;

  bool get changed => bite != null || window != null || decidedHand != null;
}

class EatingEngine {
  EatingEngine(
    this.model, {
    HandednessVoter? voter,
    MealTracker? tracker,
  })  : voter = voter ?? HandednessVoter(votesToDecide: model.votesToDecide),
        tracker = tracker ?? MealTracker() {
    _detector = BiteDetector(model: model, voter: this.voter);
    _steadiness = SteadinessAnalyzer(model.steadiness);
  }

  final AiLabModel model;
  final HandednessVoter voter;
  final MealTracker tracker;
  final ImuWindow _window = ImuWindow();
  late final BiteDetector _detector;
  late final SteadinessAnalyzer _steadiness;

  /// Rhythmic flags of the last three steadiness windows, for per-bite colour.
  final List<bool> _recentWindows = [];

  /// Samples fed since construction; with [segmentStart], maps a window index
  /// back to a stream position (used by the replay tests).
  int _fed = 0;
  int _segmentStart = 0;
  int get samplesFed => _fed;

  /// Stream position of each detected bite (diagnostics / tests).
  final List<int> detectedRows = [];

  /// Probability of the latest decision.
  double get lastProbability => _detector.lastProbability;

  EngineUpdate feed({
    required int tsMs,
    required double ax,
    required double ay,
    required double az,
    required double gx,
    required double gy,
    required double gz,
  }) {
    final row = _fed++;
    if (_window.add(
        tsMs: tsMs, ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz)) {
      _detector.reset();
      _steadiness.reset();
      _recentWindows.clear();
      _segmentStart = row;
    }

    final window = _steadiness.add(gx, gy, gz);
    if (window != null) {
      tracker.onWindow(
        rhythmic: window.rhythmic,
        active: window.active,
        hz: window.hz,
      );
      // Only ACTIVE windows colour a bite: a window with no movement in it
      // says nothing about the hand that took the bite.
      if (window.active) {
        _recentWindows.add(window.rhythmic);
        if (_recentWindows.length > 3) _recentWindows.removeAt(0);
      }
    }

    BiteEvent? bite;
    Hand? decided;
    final decision = BiteFeatures.due(_window);
    if (decision != null) {
      final hit = _detector.add(decision);
      if (hit != null) {
        detectedRows.add(_segmentStart + hit.t);
        decided = hit.decidedHand;
        final rhythmic = _recentWindows.where((r) => r).length;
        bite = BiteEvent(
          time: DateTime.fromMillisecondsSinceEpoch(_window.timestampMs(hit.t)),
          probability: hit.probability,
          rhythmicShare:
              _recentWindows.isEmpty ? 0 : rhythmic / _recentWindows.length,
        );
        tracker.onBite(bite);
      }
    }
    if (bite == null && window == null && decided == null) {
      return EngineUpdate.none;
    }
    return EngineUpdate(bite: bite, window: window, decidedHand: decided);
  }

  /// Advances meal timeouts; returns a meal that just ended.
  MealRecord? tick(DateTime now) => tracker.tick(now);

  /// Ends the running meal (user tap or spoon change).
  MealRecord? finish(DateTime now, MealEndReason reason) =>
      tracker.finish(now, reason);

  /// Forget the stream (spoon changed); meal history in [tracker] is kept.
  void resetStream() {
    _window.clear();
    _detector.reset();
    _steadiness.reset();
    _recentWindows.clear();
    _segmentStart = _fed;
  }
}
