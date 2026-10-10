// eating_engine.dart — one spoon's IMU stream in, meals and bites out.
//
// Pure Dart (no Flutter), so the whole pipeline can be replayed from a CSV in
// a test exactly as it runs on the phone.
import 'dart:collection';

import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';
import 'dart:math' as math;

import 'package:smartspoon/features/ai_lab/domain/engine/bite_cycle_tracker.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/bite_detector.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/bite_motion_gate.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/bite_features.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/handedness.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/imu_window.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/meal_tracker.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/steadiness_analyzer.dart';

/// What one [EatingEngine.feed] call changed.
class EngineUpdate {
  const EngineUpdate({
    this.bite,
    this.window,
    this.decidedHand,
    this.cycleOutcomes = const [],
  });

  static const none = EngineUpdate();

  final BiteEvent? bite;
  final SteadinessResult? window;
  final Hand? decidedHand;

  /// Cycle verdicts that resolved on this sample. In shadow mode these are
  /// informational only — the bite was already counted.
  final List<BiteCycleOutcome> cycleOutcomes;

  bool get changed =>
      bite != null ||
      window != null ||
      decidedHand != null ||
      cycleOutcomes.isNotEmpty;
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
    _cycle = BiteCycleTracker(model.biteCycle);
  }

  final AiLabModel model;
  final HandednessVoter voter;
  final MealTracker tracker;
  final ImuWindow _window = ImuWindow();
  late final BiteDetector _detector;
  late final SteadinessAnalyzer _steadiness;
  late final BiteCycleTracker _cycle;
  late final BiteMotionGate _motionGate = BiteMotionGate(model.motionGate);

  /// Classifier hits the motion gate refused, since the engine was created.
  int motionGateRejections = 0;

  /// The most recent refusal, for diagnostics.
  MotionGateVerdict? lastMotionGateRejection;

  /// Where in the eating cycle the spoon is, for the live phase chip.
  /// Distinct from `tracker.phase`, which is the MEAL phase.
  BitePhase get cyclePhase => _cycle.phase;

  /// Absolute excursion from the learned resting pose, degrees.
  double get excursionDeg => _cycle.deltaDeg;

  /// True once the per-meal plate reference has converged.
  bool get calibrated => _cycle.plateReady;

  /// This person's running typical bite excursion, degrees. Null until the
  /// first qualifying dwell.
  double? get excursionReferenceDeg => _cycle.excursionReferenceDeg;

  /// The excursion a dwell must reach right now to count.
  double get effectiveDeltaMinDeg => _cycle.effectiveDeltaMinDeg;

  /// Resolved cycle verdicts this meal, oldest first.
  List<BiteCycleOutcome> get cycleLog => _cycle.log;

  /// Proposals held back waiting on a verdict, keyed by proposal index.
  /// Only populated when [BiteCycleConfig.enforce] is true.
  final Map<int, BiteEvent> _held = {};

  /// Accepted bites waiting to be reported, at most one per fed sample.
  final Queue<BiteEvent> _ready = Queue();

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
      _cycle.reset();
      _motionGate.reset();
      _recentWindows.clear();
      _held.clear();
      _ready.clear();
      _segmentStart = row;
    }
    _cycle.add(_window, _window.newest);
    _motionGate.add(math.sqrt(gx * gx + gy * gy + gz * gz));

    final window = _steadiness.add(gx, gy, gz);
    if (window != null) {
      // A window is unsteady if EITHER test fires, because they catch
      // different things and each is blind to the other's case:
      //
      //   rhythmic  a narrowband line in 4-12 Hz — pathological tremor. Blind
      //             to amplitude, so a hand shaken hard scores perfectly
      //             steady, which is exactly what was reported.
      //   shaky     motion above 2 Hz as a share of all motion — an unsteady
      //             hand however it shakes. Blind to a small, very pure
      //             tremor line riding on ordinary eating.
      //
      // Measured on 8 labelled sessions, the two together flag about 2% of
      // real eating windows and catch 95-100% of synthetic tremor and shake.
      final unsteady = window.rhythmic || window.shaky;
      tracker.onWindow(
        rhythmic: unsteady,
        active: window.active,
        hz: window.hz,
      );
      // Only ACTIVE windows colour a bite: a window with no movement in it
      // says nothing about the hand that took the bite.
      if (window.active) {
        _recentWindows.add(unsteady);
        if (_recentWindows.length > 3) _recentWindows.removeAt(0);
      }
    }

    BiteEvent? bite;
    Hand? decided;
    final decision = BiteFeatures.due(_window);
    if (decision != null) {
      var hit = _detector.add(decision);
      if (hit != null && model.motionGate.enforce) {
        // The classifier judges one lift; this judges whether the seconds
        // around it were eating at all. See bite_motion_gate.dart.
        final v = _motionGate.evaluate();
        if (!v.accepted) {
          motionGateRejections++;
          lastMotionGateRejection = v;
          hit = null;
        }
      }
      if (hit != null) {
        detectedRows.add(_segmentStart + hit.t);
        decided = hit.decidedHand;
        final rhythmic = _recentWindows.where((r) => r).length;
        final proposed = BiteEvent(
          time: DateTime.fromMillisecondsSinceEpoch(_window.timestampMs(hit.t)),
          probability: hit.probability,
          rhythmicShare:
              _recentWindows.isEmpty ? 0 : rhythmic / _recentWindows.length,
        );
        final verdict = _cycle.propose(hit.t);

        if (!model.biteCycle.enforce) {
          // Shadow mode: count exactly as before, immediately. The verdict is
          // logged when it resolves and changes nothing, latency included.
          bite = proposed;
          tracker.onBite(proposed);
        } else if (verdict == null) {
          // Deferred — the cycle has not come back yet.
          _held[hit.t] = proposed;
        } else if (verdict.accepted) {
          bite = proposed;
          tracker.onBite(proposed);
        }
      }
    }

    // Verdicts that landed on this sample. When enforcing, an accepted one
    // releases the bite it was holding.
    final outcomes = _cycle.drainResolved();
    if (model.biteCycle.enforce) {
      for (final o in outcomes) {
        final heldBite = _held.remove(o.t);
        if (heldBite != null && o.accepted) _ready.add(heldBite);
      }
      if (bite == null && _ready.isNotEmpty) {
        bite = _ready.removeFirst();
        tracker.onBite(bite);
      }
    }

    if (bite == null &&
        window == null &&
        decided == null &&
        outcomes.isEmpty) {
      return EngineUpdate.none;
    }
    return EngineUpdate(
      bite: bite,
      window: window,
      decidedHand: decided,
      cycleOutcomes: outcomes,
    );
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
    _cycle.reset();
    _recentWindows.clear();
    _held.clear();
    _ready.clear();
    _segmentStart = _fed;
  }
}
