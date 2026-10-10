// bite_motion_gate.dart — is the motion around a proposed bite eating at all?
//
// The bite classifier scores the shape of one lift. Waving, rotating or
// shaking the spoon contains lifts of that shape, and on two recordings of
// deliberate non-eating movement it reported 25 bites in 91 seconds, most at
// a probability of 1.00 — so no threshold on the classifier separates them.
//
// Two things about the surrounding seconds do, and both are physical:
//
//   stillness  A bite ends with the spoon held in the mouth. Across 359 real
//              bites from two spoons the quietest 200 ms near each one was
//              under 19 deg/s for 99.5% of them. Arbitrary movement has no
//              such stop: its quietest 200 ms had a median of 55-58 deg/s.
//
//   agitation  Eating is intermittent — scoop, lift, hold, lower, pause — so
//              the mean rotation rate over the bite's few seconds stayed
//              under 111 deg/s for 99.5% of real bites. Continuous movement
//              never dropped below 117.
//
// A bite is kept only when both hold. Both limits are set from the eating
// recordings alone, at roughly their 99.5th percentile; the non-eating
// recordings were not used to choose them and are the test.
import 'dart:typed_data';

import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';

class MotionGateVerdict {
  const MotionGateVerdict({
    required this.accepted,
    required this.quietDps,
    required this.meanDps,
    required this.samples,
  });

  final bool accepted;

  /// Lowest mean rotation rate over any [MotionGateConfig.quietSamples] run
  /// in the lookback.
  final double quietDps;

  /// Mean rotation rate over the whole lookback.
  final double meanDps;

  /// How much history the verdict rests on.
  final int samples;
}

class BiteMotionGate {
  BiteMotionGate(this.config)
      : _mag = Float64List(config.lookbackSamples);

  final MotionGateConfig config;
  final Float64List _mag;
  int _count = 0;

  void reset() => _count = 0;

  /// Feed one gyro sample's magnitude, deg/s.
  void add(double gyroMagDps) {
    _mag[_count % _mag.length] = gyroMagDps;
    _count++;
  }

  /// Judges the lookback ending at the newest sample.
  ///
  /// With less than a full quiet-run of history there is nothing to judge,
  /// and the bite is let through: a stream that has only just (re)started
  /// should not have its first bite thrown away for lack of evidence.
  MotionGateVerdict evaluate() {
    final n = _count < _mag.length ? _count : _mag.length;
    final run = config.quietSamples;
    if (n < run) {
      return MotionGateVerdict(
          accepted: true, quietDps: 0, meanDps: 0, samples: n);
    }
    // Oldest-first walk of the ring, with a sliding sum for the quiet run.
    final start = _count - n;
    var total = 0.0, window = 0.0, quiet = double.infinity;
    for (var i = 0; i < n; i++) {
      final v = _mag[(start + i) % _mag.length];
      total += v;
      window += v;
      if (i >= run) window -= _mag[(start + i - run) % _mag.length];
      if (i >= run - 1) {
        final m = window / run;
        if (m < quiet) quiet = m;
      }
    }
    final mean = total / n;
    return MotionGateVerdict(
      accepted: quiet <= config.maxQuietDps && mean <= config.maxMeanDps,
      quietDps: quiet,
      meanDps: mean,
      samples: n,
    );
  }
}
