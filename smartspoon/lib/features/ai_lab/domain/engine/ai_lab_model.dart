// ai_lab_model.dart — the trained AI Lab model.
//
// Loaded from assets/models/ai_lab_model.json, which
// tools/ai_lab/train_bite_model.py writes. Nothing here is tuned by hand: to
// change a weight or threshold, retrain and replace the JSON.
import 'dart:convert';
import 'dart:math' as math;

List<double> _doubles(Object? v) =>
    (v as List).map((e) => (e as num).toDouble()).toList(growable: false);

/// One logistic-regression weight set over the 13 bite features.
class BiteWeights {
  const BiteWeights({
    required this.mean,
    required this.scale,
    required this.coef,
    required this.intercept,
  });

  factory BiteWeights.fromJson(Map<String, dynamic> j) => BiteWeights(
        mean: _doubles(j['mean']),
        scale: _doubles(j['scale']),
        coef: _doubles(j['coef']),
        intercept: (j['intercept'] as num).toDouble(),
      );

  final List<double> mean;
  final List<double> scale;
  final List<double> coef;
  final double intercept;

  /// Probability that the decision described by [x] is a bite.
  double probability(List<double> x) {
    var z = 0.0;
    for (var i = 0; i < coef.length; i++) {
      z += ((x[i] - mean[i]) / scale[i]) * coef[i];
    }
    return 1.0 / (1.0 + math.exp(-(z + intercept)));
  }
}

/// Normal-eater reference for hand steadiness.
/// Default motion floor for a steadiness window to count as evidence, deg/s.
///
/// Chosen from the physics rather than tuning: BMI270 gyro noise is about
/// 0.007 deg/s/sqrt(Hz), so a spoon resting on a table sits well below
/// 1 deg/s, while a hand simply holding a spoon already shows ~1-3 deg/s of
/// physiological tremor and active eating is an order of magnitude above
/// that. 1.0 deg/s therefore separates "not in use" from "in a hand" with
/// wide margin on both sides. Override per model with "minMotionRmsDps".
const double kDefaultMinMotionRmsDps = 1.0;

class SteadinessReference {
  const SteadinessReference({
    required this.fftSize,
    required this.hop,
    required this.bandLoHz,
    required this.bandHiHz,
    required this.rhythmicShareThreshold,
    this.minMotionRmsDps = kDefaultMinMotionRmsDps,
    required this.normalSteadyPctMin,
    required this.normalSteadyPctMedian,
    required this.syntheticDetection,
  });

  factory SteadinessReference.fromJson(Map<String, dynamic> j) {
    final band = _doubles(j['bandHz']);
    return SteadinessReference(
      fftSize: (j['fftSize'] as num).toInt(),
      hop: (j['hop'] as num).toInt(),
      bandLoHz: band[0],
      bandHiHz: band[1],
      rhythmicShareThreshold: (j['rhythmicShareThreshold'] as num).toDouble(),
      // Optional: older model files predate the motion gate and get the
      // documented default rather than a hard failure.
      minMotionRmsDps: (j['minMotionRmsDps'] as num?)?.toDouble() ??
          kDefaultMinMotionRmsDps,
      normalSteadyPctMin: (j['normalSteadyPctMin'] as num).toDouble(),
      normalSteadyPctMedian: (j['normalSteadyPctMedian'] as num).toDouble(),
      syntheticDetection: {
        for (final e in ((j['syntheticDetection'] as Map?) ?? const {}).entries)
          e.key as String: (e.value as num).toDouble(),
      },
    );
  }

  final int fftSize;
  final int hop;
  final double bandLoHz;
  final double bandHiHz;

  /// A window is rhythmic when the strongest line holds more than this share
  /// of the 4–12 Hz gyro power.
  final double rhythmicShareThreshold;

  /// Least broadband gyro RMS (deg/s) for a window to count as evidence about
  /// a hand. Below this the spoon is not being held, so the window is neither
  /// steady nor shaky — it is nothing. See SteadinessResult.motionRmsDps.
  final double minMotionRmsDps;

  /// Steady % of the least and the typical normal eater in the training set.
  final double normalSteadyPctMin;
  final double normalSteadyPctMedian;

  /// Share of windows flagged when a synthetic tremor was added to normal
  /// meals, e.g. {'5Hz_20dps': 0.79}.
  final Map<String, double> syntheticDetection;
}

/// Held-out accuracy recorded by the training script.
class ModelEvaluation {
  const ModelEvaluation({
    required this.method,
    required this.f1,
    required this.recall,
    required this.precision,
  });

  factory ModelEvaluation.fromJson(Map<String, dynamic> j) => ModelEvaluation(
        method: j['method'] as String? ?? '',
        f1: (j['f1'] as num).toDouble(),
        recall: (j['recall'] as num).toDouble(),
        precision: (j['precision'] as num).toDouble(),
      );

  final String method;
  final double f1;
  final double recall;
  final double precision;
}

class AiLabModel {
  const AiLabModel({
    required this.version,
    required this.trainedOn,
    required this.people,
    required this.bites,
    required this.features,
    required this.threshold,
    required this.minGapDecisions,
    required this.votesToDecide,
    required this.right,
    required this.neutral,
    required this.evaluation,
    required this.steadiness,
  });

  factory AiLabModel.fromJson(Map<String, dynamic> j) => AiLabModel(
        version: (j['version'] as num).toInt(),
        trainedOn: j['trainedOn'] as String? ?? '',
        people: (j['people'] as num).toInt(),
        bites: (j['bites'] as num).toInt(),
        features: (j['features'] as List).cast<String>(),
        threshold: (j['threshold'] as num).toDouble(),
        minGapDecisions: (j['minGapDecisions'] as num).toInt(),
        votesToDecide: (j['votesToDecide'] as num).toInt(),
        right: BiteWeights.fromJson(j['right'] as Map<String, dynamic>),
        neutral: BiteWeights.fromJson(j['neutral'] as Map<String, dynamic>),
        evaluation:
            ModelEvaluation.fromJson(j['evaluation'] as Map<String, dynamic>),
        steadiness: SteadinessReference.fromJson(
            j['steadiness'] as Map<String, dynamic>),
      );

  static AiLabModel parse(String json) =>
      AiLabModel.fromJson(jsonDecode(json) as Map<String, dynamic>);

  static const String assetPath = 'assets/models/ai_lab_model.json';

  final int version;
  final String trainedOn;
  final int people;
  final int bites;
  final List<String> features;
  final double threshold;
  final int minGapDecisions;
  final int votesToDecide;

  /// Weights for a right hand; a left hand uses the same weights on
  /// mirrored features.
  final BiteWeights right;

  /// Hand-neutral weights, used until the hand is known.
  final BiteWeights neutral;
  final ModelEvaluation evaluation;
  final SteadinessReference steadiness;
}
