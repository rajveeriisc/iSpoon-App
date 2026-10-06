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
    return SteadinessResult(
      n: n,
      share: share,
      hz: (_kLo + best) * sampleRateHz / size,
      rhythmic: share > ref.rhythmicShareThreshold,
      motionRmsDps: motionRmsDps,
      active: motionRmsDps >= ref.minMotionRmsDps,
    );
  }
}
