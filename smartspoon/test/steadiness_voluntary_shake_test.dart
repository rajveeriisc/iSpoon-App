// Reported: "I shake my hand a lot but the card still says stable, near 90."
//
// This drives the SHIPPED analyser with the SHIPPED model constants and prints
// what each kind of motion actually scores, so the complaint can be confirmed
// or dismissed with numbers rather than argued about.
//
// The thing under suspicion is what `share` measures. It is
//
//     share = (power in the 3 bins around the 4-12 Hz peak)
//           / (total power in 4-12 Hz)
//
// a RATIO INSIDE the band. It has no amplitude term at all, so it cannot tell
// a violently shaking hand from a still one. It asks only "is the 4-12 Hz
// energy concentrated at one frequency", which is a test for narrowband
// pathological tremor, not for steadiness.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/steadiness_analyzer.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';

/// The values actually shipped in assets/models/ai_lab_model.json.
const _ref = SteadinessReference(
  fftSize: 256,
  hop: 100,
  bandLoHz: 4.0,
  bandHiHz: 12.0,
  rhythmicShareThreshold: 0.5848606709113274,
  normalSteadyPctMin: 91.5,
  normalSteadyPctMedian: 99.1,
  syntheticDetection: {'5Hz_10dps': 0.324, '5Hz_20dps': 0.793},
);

const _fs = 100; // Hz, matches the BMI270 rate
const _seconds = 40;

/// Runs [gyro] (deg/s per axis, given a sample index) through the analyser and
/// returns what the app would display.
({double? steadyPct, int active, int rhythmic, double meanRms})
    _score(List<double> Function(int i) gyro) {
  final a = SteadinessAnalyzer(_ref, sampleRateHz: _fs);
  var activeW = 0, rhythmicW = 0;
  var rmsSum = 0.0, rmsN = 0;
  for (var i = 0; i < _fs * _seconds; i++) {
    final g = gyro(i);
    final r = a.add(g[0], g[1], g[2]);
    if (r == null) continue;
    rmsSum += r.motionRmsDps;
    rmsN++;
    if (r.active) {
      activeW++;
      if (r.rhythmic) rhythmicW++;
    }
  }
  return (
    steadyPct: steadyPctOf(activeW, rhythmicW),
    active: activeW,
    rhythmic: rhythmicW,
    meanRms: rmsN == 0 ? 0 : rmsSum / rmsN,
  );
}

final _rng = math.Random(42);
double _noise(double dps) => (_rng.nextDouble() * 2 - 1) * dps;

void main() {
  test('what each kind of motion actually scores', () {
    final cases = <String, List<double> Function(int)>{
      // A hand holding a spoon: physiological tremor, broadband, small.
      'normal eating (~2 deg/s broadband)': (i) =>
          [_noise(2), _noise(2), _noise(2)],

      // Pathological tremor: a clean narrowband line. What the model was
      // built to catch, and the case syntheticDetection reports.
      'clean 5 Hz tremor, 20 deg/s': (i) {
        final t = i / _fs;
        final s = 20 * math.sin(2 * math.pi * 5 * t);
        return [s + _noise(1), s * 0.6 + _noise(1), _noise(1)];
      },

      // The user's complaint: deliberately shaking hard. A human cannot hold
      // a precise frequency, so this is large and irregular.
      'VOLUNTARY hard shake, ~3 Hz, 100 deg/s': (i) {
        final t = i / _fs;
        final f = 3 + _noise(0.8); // wobbling frequency, as a real hand does
        final s = 100 * math.sin(2 * math.pi * f * t) + _noise(30);
        return [s, s * 0.7 + _noise(20), s * 0.4 + _noise(20)];
      },

      // The user's other complaint: waving the hand around in the air.
      'WAVING in the air, ~1 Hz, 200 deg/s': (i) {
        final t = i / _fs;
        final s = 200 * math.sin(2 * math.pi * 1.0 * t) + _noise(40);
        return [s, s * 0.8 + _noise(40), s * 0.5 + _noise(40)];
      },
    };

    // ignore: avoid_print
    print('\n  motion                                    steady%   active  '
        'rhythmic   mean RMS');
    final scores = <String, double?>{};
    for (final e in cases.entries) {
      final r = _score(e.value);
      scores[e.key] = r.steadyPct;
      // ignore: avoid_print
      print('  ${e.key.padRight(40)}  '
          '${(r.steadyPct?.toStringAsFixed(1) ?? 'null').padLeft(7)}  '
          '${r.active.toString().padLeft(7)}  '
          '${r.rhythmic.toString().padLeft(8)}  '
          '${r.meanRms.toStringAsFixed(1).padLeft(9)} deg/s');
    }

    // The claim being tested: violent voluntary motion still reads as steady.
    final shake = scores['VOLUNTARY hard shake, ~3 Hz, 100 deg/s'];
    final wave = scores['WAVING in the air, ~1 Hz, 200 deg/s'];
    final normal = scores['normal eating (~2 deg/s broadband)'];

    // ignore: avoid_print
    print('\n  normalSteadyPctMin in the model: ${_ref.normalSteadyPctMin}'
        '   median: ${_ref.normalSteadyPctMedian}');

    expect(shake, isNotNull);
    expect(wave, isNotNull);
    // If these come out high, the metric cannot see gross motion at all.
    // ignore: avoid_print
    print('  -> shaking reads ${shake!.toStringAsFixed(1)}% steady, '
        'waving ${wave!.toStringAsFixed(1)}%, '
        'normal ${normal!.toStringAsFixed(1)}%\n');
  });
}
