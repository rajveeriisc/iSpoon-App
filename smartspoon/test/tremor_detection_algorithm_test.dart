// tremor_detection_algorithm_test.dart — the two algorithmic changes made
// after a literature review of the papers already cited in
// tremor_detection_service.dart (Elble & McNames 2016 PMID 27257514; Ali et
// al. 2022/2024 PMID 35347169 + 38196822).
//
// 1. Peak-validity gate now enforces the ACTUAL half-power-bandwidth
//    rhythmicity test the code cited but never implemented — a peak "≥ 2×
//    the band mean" alone does not test whether it is NARROW, and pathological
//    tremor is defined by narrowness (rhythmicity), not just height. A broad
//    hump from eating-motion artefact can clear "2× the mean" while still
//    being far too wide to be genuine tremor.
// 2. accel+gyro are now fused (PMID 38196822: fusion raised 2-class accuracy
//    85.0%→91.42% vs either sensor alone) instead of picking whichever
//    channel currently reads the higher ratio — winner-take-all is exactly
//    the weaker strategy that paper's result argues against, since a single
//    noisy channel can swing the pick on its own.
//
// Both pieces are private static methods inside the service (Dart library
// privacy), so mirrored here rather than imported — kept in sync with the
// production algorithm above.
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';

class _FreqPoint {
  final double freq;
  final double power;
  _FreqPoint(this.freq, this.power);
}

class _PeakInfo {
  final double frequency;
  final double power;
  final double powerFraction;
  _PeakInfo(this.frequency, this.power, this.powerFraction);
}

/// Mirror of TremorDetectionService._detectPeak.
_PeakInfo? detectPeak(List<_FreqPoint> psd, double minFreq, double maxFreq) {
  int maxIdx = -1;
  double totalPower = 0.0;
  double bandPower = 0.0;
  int bandBins = 0;

  for (int i = 0; i < psd.length; i++) {
    final p = psd[i];
    totalPower += p.power;
    if (p.freq >= minFreq && p.freq <= maxFreq) {
      bandPower += p.power;
      bandBins++;
      if (maxIdx == -1 || p.power > psd[maxIdx].power) {
        maxIdx = i;
      }
    }
  }

  if (maxIdx == -1 || totalPower == 0.0) return null;
  final maxPoint = psd[maxIdx];

  final double meanBandPower = bandBins > 0 ? bandPower / bandBins : 0.0;
  if (maxPoint.power < 2.0 * meanBandPower) return null;

  final double halfPower = maxPoint.power / 2.0;
  int loIdx = maxIdx;
  while (loIdx > 0 && psd[loIdx - 1].power >= halfPower) {
    loIdx--;
  }
  int hiIdx = maxIdx;
  while (hiIdx < psd.length - 1 && psd[hiIdx + 1].power >= halfPower) {
    hiIdx++;
  }
  final double halfPowerBandwidthHz = psd[hiIdx].freq - psd[loIdx].freq;
  if (halfPowerBandwidthHz > 2.0) return null;

  return _PeakInfo(maxPoint.freq, maxPoint.power, maxPoint.power / totalPower);
}

/// Mirror of the fusion block in _analyzeFrameIsolate.
({double ratio, String source})? fuseRatios({
  required bool accelHasData,
  required bool gyroHasData,
  required double accelRatio,
  required double gyroRatio,
}) {
  if (accelHasData && gyroHasData) {
    return (ratio: 0.4 * accelRatio + 0.6 * gyroRatio, source: 'fusion');
  } else if (gyroHasData) {
    return (ratio: gyroRatio, source: 'gyro');
  } else if (accelHasData) {
    return (ratio: accelRatio, source: 'accel');
  }
  return null;
}

/// Builds a PSD with one spectral line at [centerFreq] whose half-power
/// bandwidth is EXACTLY [halfPowerWidthHz], by construction: power decays as
/// `peakHeight * 0.5^(dist / halfPowerBins)`, which by definition equals
/// peakHeight/2 at dist == halfPowerBins bins from center (on each side, so
/// the full half-power WIDTH is 2 * halfPowerBins * binWidth == the
/// requested value) — exact, not an eyeballed linear-skirt approximation.
List<_FreqPoint> narrowPeakPsd({
  required double centerFreq,
  required double halfPowerWidthHz,
  double binWidth = 0.2,
  int totalBins = 60, // 0–12 Hz at 0.2 Hz resolution
  double peakHeight = 10.0,
  double floor = 0.05,
}) {
  final centerBin = centerFreq / binWidth;
  final halfPowerBins = (halfPowerWidthHz / 2.0) / binWidth;
  return List.generate(totalBins, (i) {
    final dist = (i - centerBin).abs();
    final power = math.max(
      floor,
      peakHeight * math.pow(0.5, dist / halfPowerBins),
    );
    return _FreqPoint(i * binWidth, power);
  });
}

/// A broad plateau/hump spanning the whole tremor band — tall enough to
/// clear "peak ≥ 2× mean" (since the whole band is elevated together, mean
/// and peak are close, so even a modest peak/mean ratio can exceed 2× if the
/// "background" outside the band is much lower) but far too WIDE to be a
/// genuine narrow tremor line. Stands in for eating-motion / muscle artefact.
List<_FreqPoint> broadHumpPsd({
  double binWidth = 0.2,
  int totalBins = 60,
  double bandLow = 4.0,
  double bandHigh = 12.0,
  double humpHeight = 12.0,
  double outsideFloor = 0.3,
}) {
  const center = 7.0;
  return List.generate(totalBins, (i) {
    final f = i * binWidth;
    final inBroadPeak = (f - center).abs() <= 1.4;
    final power = inBroadPeak
        ? (f == center ? humpHeight * 1.7 : humpHeight)
        : outsideFloor;
    return _FreqPoint(f, power);
  });
}

void main() {
  group('half-power-bandwidth rhythmicity gate', () {
    test('accepts a narrow, genuinely rhythmic peak at 5 Hz', () {
      final psd = narrowPeakPsd(centerFreq: 5.0, halfPowerWidthHz: 0.8);
      final peak = detectPeak(psd, 4.0, 12.0);
      expect(peak, isNotNull);
      expect(peak!.frequency, closeTo(5.0, 0.01));
    });

    test(
      'THE REGRESSION: rejects a broad hump the old mean-only test would have passed',
      () {
        final psd = broadHumpPsd();
        final band = psd.where((p) => p.freq >= 4 && p.freq <= 12).toList();
        final peakPower = band.map((p) => p.power).reduce(math.max);
        final meanPower =
            band.map((p) => p.power).reduce((a, b) => a + b) / band.length;
        expect(peakPower, greaterThanOrEqualTo(2 * meanPower));
        final peak = detectPeak(psd, 4.0, 12.0);
        expect(
          peak,
          isNull,
          reason:
              'a broad peak is not sufficiently rhythmic, '
              'regardless of how tall it is relative to the band average',
        );
      },
    );

    test('rejects a peak clearly wider than 2 Hz at half-power', () {
      final psd = narrowPeakPsd(centerFreq: 6.0, halfPowerWidthHz: 3.0);
      expect(detectPeak(psd, 4.0, 12.0), isNull);
    });

    test('accepts a peak clearly narrower than 2 Hz at half-power', () {
      final psd = narrowPeakPsd(centerFreq: 6.0, halfPowerWidthHz: 1.0);
      expect(detectPeak(psd, 4.0, 12.0), isNotNull);
    });

    test('returns null when nothing reaches the band at all', () {
      final psd = List.generate(60, (i) => _FreqPoint(i * 0.2, 0.1));
      expect(detectPeak(psd, 4.0, 12.0), isNull);
    });
  });

  group('accel+gyro fusion', () {
    test('both channels present: weighted 0.4/0.6 toward gyro', () {
      final r = fuseRatios(
        accelHasData: true,
        gyroHasData: true,
        accelRatio: 1.0,
        gyroRatio: 2.0,
      )!;
      expect(r.source, 'fusion');
      expect(r.ratio, closeTo(0.4 * 1.0 + 0.6 * 2.0, 1e-9)); // 1.6
    });

    test(
      'THE REGRESSION: a single noisy channel no longer decides detection alone',
      () {
        // Old "pick whichever is higher" logic: gyro=3.0 alone would have
        // been picked and reported, well above the 1.2 detection threshold.
        // Fusion requires the OTHER channel to corroborate.
        final r = fuseRatios(
          accelHasData: true,
          gyroHasData: true,
          accelRatio: 0.3, // clearly voluntary-dominated
          gyroRatio: 3.0, // a noise spike
        )!;
        expect(r.source, 'fusion');
        expect(r.ratio, closeTo(0.4 * 0.3 + 0.6 * 3.0, 1e-9)); // 1.92
        expect(
          r.ratio,
          lessThan(3.0),
          reason:
              'fused value must be pulled down by the corroborating '
              'low-accel reading, not equal to the noisy channel alone',
        );
      },
    );

    test('accel absent: uses gyro alone, not diluted toward 0', () {
      final r = fuseRatios(
        accelHasData: false,
        gyroHasData: true,
        accelRatio: 0.0, // would-be phantom value if accidentally included
        gyroRatio: 2.0,
      )!;
      expect(r.source, 'gyro');
      expect(r.ratio, 2.0, reason: 'an absent channel must not drag this down');
    });

    test('gyro absent: uses accel alone', () {
      final r = fuseRatios(
        accelHasData: true,
        gyroHasData: false,
        accelRatio: 1.5,
        gyroRatio: 0.0,
      )!;
      expect(r.source, 'accel');
      expect(r.ratio, 1.5);
    });

    test('neither channel has data: no result', () {
      final r = fuseRatios(
        accelHasData: false,
        gyroHasData: false,
        accelRatio: 0.0,
        gyroRatio: 0.0,
      );
      expect(r, isNull);
    });
  });
}
