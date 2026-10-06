// bite_detector.dart — decision probabilities → bites, in real time.
//
// Each decision's probability comes from the weights for the current hand
// mode. A bite is the peak of the 3-decision moving average: it must reach
// the model threshold, be at least as high as both neighbours, and come at
// least 1.8 s after the previous bite. The peak is confirmed two decisions
// (0.2 s) after it, so a bite is reported ~1.7 s after the mouth.
import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/bite_features.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/handedness.dart';

class DetectedBite {
  const DetectedBite({
    required this.t,
    required this.probability,
    required this.yaw,
    this.decidedHand,
  });

  /// Sample index (since the window's last reset) of the mouth moment.
  final int t;

  /// Smoothed probability at the peak.
  final double probability;
  final double yaw;

  /// Set when this bite's vote decided the hand.
  final Hand? decidedHand;
}

class BiteDetector {
  BiteDetector({required this.model, required this.voter});

  final AiLabModel model;
  final HandednessVoter voter;

  // The last five probabilities and decisions; index k of the current
  // segment lives at k - _base.
  final List<double> _p = [];
  final List<BiteDecision> _d = [];
  int _base = 0;
  int _k = -1;
  int _lastBite = -1000000000;

  /// Probability of the most recent decision (for diagnostics).
  double get lastProbability => _p.isEmpty ? 0 : _p.last;

  void reset() {
    _p.clear();
    _d.clear();
    _base = 0;
    _k = -1;
    _lastBite = -1000000000;
  }

  double _pAt(int k) => _p[k - _base];

  DetectedBite? add(BiteDecision decision) {
    final mode = voter.mode;
    final weights = mode == HandMode.neutral ? model.neutral : model.right;
    _p.add(weights.probability(BiteFeatures.forMode(decision.features, mode)));
    _d.add(decision);
    _k++;
    if (_p.length > 5) {
      _p.removeAt(0);
      _d.removeAt(0);
      _base++;
    }
    final i = _k - 2;
    if (i < 2) return null;
    final s = (_pAt(i - 1) + _pAt(i) + _pAt(i + 1)) / 3.0;
    if (s >= model.threshold &&
        s >= (_pAt(i - 2) + _pAt(i - 1) + _pAt(i)) / 3.0 &&
        s >= (_pAt(i) + _pAt(i + 1) + _pAt(i + 2)) / 3.0 &&
        i - _lastBite > model.minGapDecisions) {
      _lastBite = i;
      final d = _d[i - _base];
      final decided = voter.vote(d.yaw);
      return DetectedBite(
        t: d.t,
        probability: s,
        yaw: d.yaw,
        decidedHand: decided,
      );
    }
    return null;
  }
}
