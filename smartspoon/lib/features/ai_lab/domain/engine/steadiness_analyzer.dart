// steadiness_analyzer.dart — is the hand shaking rhythmically?
//
// Every second, a 2.56 s Hann-windowed FFT of the three gyro axes. Ordinary
// eating spreads its 4–12 Hz energy over many frequencies; a tremor puts it
// in one narrow line. A window is "rhythmic" when that line's share of the
// band exceeds what normal eaters reach (the reference in the model JSON).
//
// `share` is a RATIO, so on its own it cannot tell "a steady hand" from "no
// hand at all": a spoon lying on a table produces broadband sensor noise, a
// low share, and therefore a NOT-rhythmic window. Counting those as steady is
// what made the app report "Steady 100%" beside 0 bites while the spoon sat
// on the table. Every window therefore also carries [motionRmsDps], an
// absolute amplitude, and [active] — whether there was enough movement for
// the reading to mean anything. The rhythmic decision itself is unchanged, so
// this stays in parity with tools/ai_lab/train_bite_model.py.
//
// This is a steadiness measure, not a diagnosis. Must match
// tools/ai_lab/train_bite_model.py.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';

class SteadinessResult {
  const SteadinessResult({
    required this.n,
    required this.share,
    required this.hz,
    required this.rhythmic,
    required this.shakeIndex,
    required this.shaky,
    required this.motionRmsDps,
    required this.active,
  });

  /// Sample index (since reset) of the window's newest sample.
  final int n;

  /// Share of 4–12 Hz power in the strongest line (±1 bin).
  final double share;

  /// Frequency of that line.
  final double hz;
  final bool rhythmic;

  /// Share of this hand's motion that sits ABOVE the band voluntary eating
  /// occupies, as an amplitude ratio in 0..1:
  ///
  ///     shakeIndex = RMS(gyro, 2-15 Hz) / RMS(gyro, 0.3-15 Hz)
  ///
  /// [share] cannot see this. It is a ratio INSIDE 4-12 Hz, so it asks only
  /// whether that band's energy is concentrated at one frequency and has no
  /// amplitude term at all — measured on the shipped analyser, a hand thrown
  /// around at 195 deg/s scored 100% steady. This asks a different question:
  /// how much of the motion is faster than the task needs. Scooping and
  /// lifting are slow, so smooth eating stays low however vigorous, while
  /// tremor and deliberate shaking push it up.
  ///
  /// Measured over 861 windows of real eating (8 labelled sessions):
  ///     p50 0.36   p95 0.63   p99 0.85
  /// and on synthetic motion:
  ///     tremor  5 Hz 10 dps   1.00     shake 3 Hz 100 dps  0.90
  ///     tremor  6 Hz 20 dps   0.99     waving 1 Hz 200 dps 0.24
  final double shakeIndex;

  /// True when [shakeIndex] is above what this eater's own meals produce.
  ///
  /// Kept separate from [rhythmic] because the two catch different things: a
  /// narrowband line (pathological tremor) versus broadband fast motion
  /// (a shaking or unsteady hand). A window is unsteady if either fires.
  final bool shaky;

  /// Broadband RMS of the mean-removed gyro vector over the window, deg/s.
  ///
  /// Absolute, not a ratio, and in the same units the spoon sends (firmware
  /// packs 0.1 dps/LSB; the app divides by 10 in telemetry_session.dart). A
  /// spoon at rest on a table sits far below 1 deg/s — BMI270 gyro noise is
  /// ~0.007 deg/s/sqrt(Hz). A hand merely HOLDING a spoon already shows
  /// physiological tremor of roughly 1-3 deg/s, and actively eating is an
  /// order of magnitude more. Mean-removed so a constant bias cannot pass as
  /// motion, and broadband on purpose: lifting a spoon to the mouth is mostly
  /// well below the 4-12 Hz tremor band, but it is still proof the spoon is
  /// in a hand.
  final double motionRmsDps;

  /// Whether this window is evidence about a HAND at all.
  ///
  /// False means "not in use" — not "steady". An inactive window must not be
  /// counted in either direction, which is why steadyPctOf() divides by the
  /// ACTIVE window count.
  final bool active;
}

class SteadinessAnalyzer {
  SteadinessAnalyzer(this.ref, {this.sampleRateHz = 100})
      : _fft = FFT(ref.fftSize),
        _kLo = (ref.bandLoHz * ref.fftSize / sampleRateHz).ceil(),
        _kHi = (ref.bandHiHz * ref.fftSize / sampleRateHz).floor(),
        // Shake bands. 2.0 Hz is where voluntary eating motion ends and
        // tremor begins: swept against the real sessions, a 2.0 Hz cut caught
        // 95% of a 3 Hz shake and 100% of a 5 Hz 10 deg/s tremor at a 1%
        // false-alarm rate, while 3.0 Hz caught only 55% of the shake and
        // 4.0 Hz missed it entirely.
        _kShakeLo = (ref.shakeLoHz * ref.fftSize / sampleRateHz).ceil(),
        _kShakeHi = (ref.shakeHiHz * ref.fftSize / sampleRateHz).floor(),
        // 0.3 Hz rather than DC: the mean is already removed, and the lowest
        // bins hold drift rather than motion.
        _kFloorLo = (0.3 * ref.fftSize / sampleRateHz).ceil(),
        _hann = Float64List.fromList([
          for (var k = 0; k < ref.fftSize; k++)
            0.5 * (1.0 - math.cos(2.0 * math.pi * k / (ref.fftSize - 1))),
        ]),
        _x = Float64List(ref.fftSize),
        _y = Float64List(ref.fftSize),
        _z = Float64List(ref.fftSize);

  final SteadinessReference ref;
  final int sampleRateHz;
  final FFT _fft;
  final int _kLo;
  final int _kHi;
  final int _kShakeLo;
  final int _kShakeHi;
  final int _kFloorLo;
  final Float64List _hann;
  final Float64List _x, _y, _z;
  int _count = 0;

  void reset() => _count = 0;

  SteadinessResult? add(double gx, double gy, double gz) {
    final size = ref.fftSize;
    final slot = _count % size;
    _x[slot] = gx;
    _y[slot] = gy;
    _z[slot] = gz;
    final n = _count;
    _count++;
    if (n < size - 1 || n % ref.hop != 0) return null;

    final power = Float64List(size ~/ 2 + 1);
    // Summed across all three axes, so sqrt(sumSq/size) is the RMS of the
    // mean-removed gyro VECTOR. Taken before the Hann taper: the taper is for
    // spectral leakage and would scale the amplitude down by its own factor.
    var sumSq = 0.0;
    for (final axis in [_x, _y, _z]) {
      // Oldest sample first.
      final w = Float64List(size);
      var sum = 0.0;
      for (var k = 0; k < size; k++) {
        w[k] = axis[(n - size + 1 + k) % size];
        sum += w[k];
      }
      final mean = sum / size;
      for (var k = 0; k < size; k++) {
        final centred = w[k] - mean;
        sumSq += centred * centred;
        w[k] = centred * _hann[k];
      }
      final spec = _fft.realFft(w);
      for (var k = 0; k <= size ~/ 2; k++) {
        final c = spec[k];
        power[k] += c.x * c.x + c.y * c.y;
      }
    }
    var best = 0, total = 0.0;
    for (var k = _kLo; k <= _kHi; k++) {
      total += power[k];
      if (power[k] > power[_kLo + best]) best = k - _kLo;
    }
    var line = 0.0;
    for (var k = math.max(_kLo, _kLo + best - 1);
        k <= math.min(_kHi, _kLo + best + 1);
        k++) {
      line += power[k];
    }
    final share = total > 0 ? line / total : 0.0;
    final motionRmsDps = math.sqrt(sumSq / size);

    // Reuses `power`, which is already the Hann-tapered spectrum summed over
    // the three axes, so the shake index costs a pass over the bins rather
    // than another FFT.
    var fast = 0.0, all = 0.0;
    for (var k = _kFloorLo; k <= _kShakeHi; k++) {
      all += power[k];
      if (k >= _kShakeLo) fast += power[k];
    }
    final shakeIndex = all > 0 ? math.sqrt(fast / all) : 0.0;

    return SteadinessResult(
      n: n,
      share: share,
      hz: (_kLo + best) * sampleRateHz / size,
      rhythmic: share > ref.rhythmicShareThreshold,
      shakeIndex: shakeIndex,
      shaky: shakeIndex > ref.shakeIndexThreshold,
      motionRmsDps: motionRmsDps,
      active: motionRmsDps >= ref.minMotionRmsDps,
    );
  }
}
