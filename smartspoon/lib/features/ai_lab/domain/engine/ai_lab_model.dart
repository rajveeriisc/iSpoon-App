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

/// Where voluntary eating motion ends and tremor/shake begins, in Hz.
///
/// Swept against 861 windows of real eating from 8 labelled sessions, holding
/// the false-alarm rate at 1% (threshold = that eater's p99) and scoring
/// synthetic tremor and shaking:
///
///     low cut    3 Hz shake   5 Hz shake   5 Hz 10 dps tremor
///       2.0 Hz        95%          97%           100%
///       2.5 Hz        84%         100%           100%
///       3.0 Hz        55%         100%           100%
///       4.0 Hz         0%          95%            92%
///
/// 2.0 Hz is the only cut that catches a deliberate 3 Hz shake, which is what
/// a person does when they test the feature by hand.
const double kDefaultShakeLoHz = 2.0;

/// Upper edge. Above this is sensor noise, not hand motion.
const double kDefaultShakeHiHz = 15.0;

/// Default shake-index threshold: the 99th percentile of real eating, so one
/// window in a hundred of ordinary eating trips it.
///
/// Measured on one eater's 8 sessions. It should become per-person the way
/// pace already is — a brisker or shakier eater has a different baseline —
/// and more datasets from other people would be the thing that justifies a
/// different global default.
const double kDefaultShakeIndexThreshold = 0.849;

class SteadinessReference {
  const SteadinessReference({
    required this.fftSize,
    required this.hop,
    required this.bandLoHz,
    required this.bandHiHz,
    required this.rhythmicShareThreshold,
    this.minMotionRmsDps = kDefaultMinMotionRmsDps,
    this.shakeLoHz = kDefaultShakeLoHz,
    this.shakeHiHz = kDefaultShakeHiHz,
    this.shakeIndexThreshold = kDefaultShakeIndexThreshold,
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
      // Optional for the same reason as minMotionRmsDps: a model file written
      // before the shake index existed gets the documented defaults rather
      // than failing to parse.
      shakeLoHz: (j['shakeLoHz'] as num?)?.toDouble() ?? kDefaultShakeLoHz,
      shakeHiHz: (j['shakeHiHz'] as num?)?.toDouble() ?? kDefaultShakeHiHz,
      shakeIndexThreshold: (j['shakeIndexThreshold'] as num?)?.toDouble() ??
          kDefaultShakeIndexThreshold,
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

  /// Band used by SteadinessResult.shakeIndex, and the level above which a
  /// window counts as shaky.
  final double shakeLoHz;
  final double shakeHiHz;
  final double shakeIndexThreshold;

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


/// Thresholds for the bite-cycle phase machine (see BiteCycleTracker).
///
/// Thresholds for BiteMotionGate, under "motionGate" in the model JSON.
///
/// Both limits come from real bites only — 359 from eighteen ordinary
/// sessions on two spoons, plus 38 from two sessions eaten with a pronounced
/// tremor — and sit just above the largest value any of them produced:
///
///                           ordinary   with tremor   limit
///     quietest 200 ms        20.2        25.8         32 deg/s
///     mean over lookback    108.8        52.9        110 deg/s
///
/// The tremor sessions are why [maxQuietDps] is 32 and not 25. A hand with a
/// tremor does not come to rest in the mouth the way a steady one does, and
/// at 25 the gate refused a real bite from exactly the people this spoon is
/// for. Raising it cost nothing measurable: the same 4 of 25 non-eating
/// detections pass the stillness test at 26 and at 32, and all four fail the
/// mean test. A tremor markedly stronger than the recorded one is untested.
class MotionGateConfig {
  const MotionGateConfig({
    this.enforce = true,
    this.lookbackSamples = 500,
    this.quietSamples = 20,
    this.maxQuietDps = 32.0,
    this.maxMeanDps = 110.0,
  });

  factory MotionGateConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const MotionGateConfig();
    const d = MotionGateConfig();
    return MotionGateConfig(
      enforce: j['enforce'] as bool? ?? d.enforce,
      lookbackSamples:
          (j['lookbackSamples'] as num?)?.toInt() ?? d.lookbackSamples,
      quietSamples: (j['quietSamples'] as num?)?.toInt() ?? d.quietSamples,
      maxQuietDps: (j['maxQuietDps'] as num?)?.toDouble() ?? d.maxQuietDps,
      maxMeanDps: (j['maxMeanDps'] as num?)?.toDouble() ?? d.maxMeanDps,
    );
  }

  /// False counts every classifier hit, as before the gate existed.
  final bool enforce;

  /// History judged, in samples: 5 s at 100 Hz.
  ///
  /// Long enough to hold a whole bite including its stop in the mouth. Run
  /// through the engine on all eighteen eating sessions, 4 s lost 2 of 359
  /// real bites whose stop fell just outside it; 5 s lost none.
  final int lookbackSamples;

  /// Length of the still moment looked for (200 ms).
  final int quietSamples;

  final double maxQuietDps;
  final double maxMeanDps;
}

/// Lives under "biteCycle" in the model JSON so it travels with the model
/// rather than being hardcoded in logic — the same pattern as
/// [SteadinessReference.minMotionRmsDps]. Every field has a documented default
/// so a model file written before this existed still loads.
///
/// The initial values are read off the geometry of a spoon trip, NOT measured.
/// They are expected to change once real verdicts have been reviewed, which is
/// what [enforce] being false is for.
class BiteCycleConfig {
  const BiteCycleConfig({
    this.enforce = false,
    this.plateToleranceDeg = 15.0,
    this.deltaRiseDeg = 25.0,
    this.deltaMinDeg = 25.0,
    this.excursionFraction = 0.5,
    this.excursionRefTauCycles = 8.0,
    this.dwellMs = 200,
    this.dwellGyroDps = 25.0,
    this.burstGyroDps = 60.0,
    this.burstMinMs = 150,
    this.sustainedGyroDps = 40.0,
    this.returnDropDeg = 8.0,
    this.stillGyroDps = 15.0,
    this.plateTauSec = 10.0,
    this.plateReadyMs = 8000,
    this.loadTimeoutMs = 8000,
    this.liftTimeoutMs = 3000,
    this.mouthTimeoutMs = 4000,
    this.returnTimeoutMs = 5000,
    this.mouthWindowSamples = 60,
    this.mouthLagSamples = 200,
    this.verdictDeadlineSamples = 400,
  });

  factory BiteCycleConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const BiteCycleConfig();
    const d = BiteCycleConfig();
    double n(String k, double fallback) =>
        (j[k] as num?)?.toDouble() ?? fallback;
    int i(String k, int fallback) => (j[k] as num?)?.toInt() ?? fallback;
    return BiteCycleConfig(
      enforce: j['enforce'] as bool? ?? d.enforce,
      plateToleranceDeg: n('plateToleranceDeg', d.plateToleranceDeg),
      deltaRiseDeg: n('deltaRiseDeg', d.deltaRiseDeg),
      deltaMinDeg: n('deltaMinDeg', d.deltaMinDeg),
      excursionFraction: n('excursionFraction', d.excursionFraction),
      excursionRefTauCycles:
          n('excursionRefTauCycles', d.excursionRefTauCycles),
      dwellMs: i('dwellMs', d.dwellMs),
      dwellGyroDps: n('dwellGyroDps', d.dwellGyroDps),
      burstGyroDps: n('burstGyroDps', d.burstGyroDps),
      burstMinMs: i('burstMinMs', d.burstMinMs),
      sustainedGyroDps: n('sustainedGyroDps', d.sustainedGyroDps),
      returnDropDeg: n('returnDropDeg', d.returnDropDeg),
      stillGyroDps: n('stillGyroDps', d.stillGyroDps),
      plateTauSec: n('plateTauSec', d.plateTauSec),
      plateReadyMs: i('plateReadyMs', d.plateReadyMs),
      loadTimeoutMs: i('loadTimeoutMs', d.loadTimeoutMs),
      liftTimeoutMs: i('liftTimeoutMs', d.liftTimeoutMs),
      mouthTimeoutMs: i('mouthTimeoutMs', d.mouthTimeoutMs),
      returnTimeoutMs: i('returnTimeoutMs', d.returnTimeoutMs),
      mouthWindowSamples: i('mouthWindowSamples', d.mouthWindowSamples),
      mouthLagSamples: i('mouthLagSamples', d.mouthLagSamples),
      verdictDeadlineSamples:
          i('verdictDeadlineSamples', d.verdictDeadlineSamples),
    );
  }

  /// When false the tracker computes and logs verdicts but every proposal
  /// still counts, so bite totals are unchanged. Ships false on purpose: an
  /// untuned gate that silently undercounts meals is worse than the false
  /// positives it replaces.
  final bool enforce;

  /// Within this excursion the spoon counts as "at the plate".
  final double plateToleranceDeg;

  /// Coarse trigger for leaving the plate. Deliberately loose: it is read
  /// mid-swing, where the gravity estimate is contaminated by arm
  /// acceleration, so it decides only "something is moving away".
  final double deltaRiseDeg;

  /// ABSOLUTE floor for the dwell-mean excursion. A dwell below this is not a
  /// bite for anybody.
  ///
  /// Set from the separation measured against the motions being rejected:
  /// a wrist wiggle peaks around 10 degrees and stirring around 8, so 25
  /// clears both with wide margin. It is deliberately NOT the whole test —
  /// see [excursionFraction].
  final double deltaMinDeg;

  /// The real excursion test is relative to how far THIS person tilts the
  /// spoon: a dwell counts when it reaches this fraction of their running
  /// typical bite excursion.
  ///
  /// A fixed absolute angle cannot work across eaters, which the two real
  /// meals showed plainly — dwell-mean excursion ran 48.6-57.8 degrees for
  /// the brisk eater but 18.7-55.0 for the slow one, so the single 40 degree
  /// threshold that passed all 19 of the first eater's bites rejected 10 of
  /// the second eater's 21. Same reasoning as learning the plate pose instead
  /// of assuming one.
  final double excursionFraction;

  /// Time constant, in completed cycles, of the running excursion reference.
  final double excursionRefTauCycles;

  /// How long the spoon must be held still to call it a mouth dwell.
  final int dwellMs;
  final double dwellGyroDps;

  /// A gyro burst at plate attitude, i.e. collecting food.
  final double burstGyroDps;
  final int burstMinMs;

  /// Sustained rotation through the lift.
  final double sustainedGyroDps;

  /// Hysteresis below the dwell peak before the return is called, so low-pass
  /// noise cannot trigger it.
  final double returnDropDeg;

  /// Plate reference: learned only from samples quieter than this.
  final double stillGyroDps;
  final double plateTauSec;

  /// Until this has elapsed the reference is unconverged, so the tracker
  /// emits phases but never rejects a proposal.
  final int plateReadyMs;

  final int loadTimeoutMs;
  final int liftTimeoutMs;
  final int mouthTimeoutMs;
  final int returnTimeoutMs;

  /// How far AFTER a mouth dwell has ended a proposal may still bind to it.
  final int mouthWindowSamples;

  /// How long after a proposal the mouth dwell may still begin.
  ///
  /// Deliberately much larger than [mouthWindowSamples], because the two
  /// directions are not symmetric: a dwell can only be CONFIRMED [dwellMs]
  /// after it starts, and a gentle eater decelerates slowly, so the machine
  /// enters `mouth` well after the kinematic moment the model fired on.
  /// Measured on the two real meals, the brisk eater needed at most 4 samples
  /// of slack while the slow eater needed up to 159 — with the original
  /// symmetric 60 this cost 11 of that eater's 21 true bites.
  final int mouthLagSamples;

  /// A deferred verdict is decided by this many samples after the proposal,
  /// whatever the machine is doing.
  final int verdictDeadlineSamples;
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
    this.biteCycle = const BiteCycleConfig(),
    this.motionGate = const MotionGateConfig(),
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
        biteCycle:
            BiteCycleConfig.fromJson(j['biteCycle'] as Map<String, dynamic>?),
        motionGate: MotionGateConfig.fromJson(
            j['motionGate'] as Map<String, dynamic>?),
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

  /// Phase-machine thresholds. Defaults apply when the model file has no
  /// "biteCycle" object.
  final BiteCycleConfig biteCycle;

  /// Stillness-and-agitation check applied to every proposed bite.
  final MotionGateConfig motionGate;
}
