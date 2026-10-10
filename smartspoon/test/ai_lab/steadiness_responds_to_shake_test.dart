// "I shake my hand a lot but the card still says stable, near 90."
//
// The shipped metric could not see it. `share` is a ratio INSIDE 4-12 Hz —
// it asks whether that band's energy sits at one frequency, and has no
// amplitude term — so a hand thrown around at 195 deg/s scored 100% steady
// while a clean 5 Hz tremor scored 0%. Correct for a tremor screener, wrong
// for something the interface calls steadiness.
//
// shakeIndex measures what the old one could not: the share of motion faster
// than the task needs. These drive the real analyser with the real shipped
// constants and pin both directions — it has to fire on shaking AND stay
// quiet on vigorous ordinary eating, because a metric that flags real meals
// is no more useful than one that flags nothing.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/steadiness_analyzer.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';

import 'ai_lab_fixtures.dart';

const _fs = 100;
final _rng = math.Random(11);
double _n(double a) => (_rng.nextDouble() * 2 - 1) * a;

/// Runs a motion through the analyser and returns the steady % the app shows.
({double? steadyPct, double meanShake, double meanRms}) _run(
  List<double> Function(int) gyro, {
  int seconds = 40,
}) {
  final a = SteadinessAnalyzer(loadModel().steadiness, sampleRateHz: _fs);
  var active = 0, unsteady = 0;
  var shakeSum = 0.0, rmsSum = 0.0, n = 0;
  for (var i = 0; i < _fs * seconds; i++) {
    final g = gyro(i);
    final r = a.add(g[0], g[1], g[2]);
    if (r == null) continue;
    shakeSum += r.shakeIndex;
    rmsSum += r.motionRmsDps;
    n++;
    if (r.active) {
      active++;
      // Same rule the engine applies.
      if (r.rhythmic || r.shaky) unsteady++;
    }
  }
  return (
    steadyPct: steadyPctOf(active, unsteady),
    meanShake: n == 0 ? 0 : shakeSum / n,
    meanRms: n == 0 ? 0 : rmsSum / n,
  );
}

/// Sustained oscillation at [hz], the way a hand shakes — the frequency
/// wanders because a person cannot hold one.
List<double> Function(int) _shake(double hz, double dps) => (i) {
      final t = i / _fs;
      final f = hz + _n(hz * 0.2);
      final s = dps * math.sin(2 * math.pi * f * t) + _n(dps * 0.25);
      return [s, s * 0.7 + _n(dps * 0.2), s * 0.4 + _n(dps * 0.2)];
    };

/// Ordinary eating: slow, large, aperiodic scoop-lift-return motion. Measured
/// from the real sessions at a median 52 deg/s broadband, so this is NOT a
/// gentle signal — it is the case a naive amplitude threshold would flag.
List<double> Function(int) _eating() => (i) {
      final t = i / _fs;
      // One bite cycle every ~3.5 s, plus the wrist roll within it.
      final c = 70 * math.sin(2 * math.pi * 0.29 * t) +
          35 * math.sin(2 * math.pi * 0.58 * t + 1.1) +
          12 * math.sin(2 * math.pi * 1.1 * t + 0.4);
      return [c + _n(6), c * 0.8 + _n(6), c * 0.5 + _n(6)];
    };

void main() {
  test('vigorous ORDINARY eating still reads as steady', () {
    final r = _run(_eating());
    // ignore: avoid_print
    print('  eating      rms=${r.meanRms.toStringAsFixed(0)} dps  '
        'shakeIndex=${r.meanShake.toStringAsFixed(2)}  '
        'steady=${r.steadyPct?.toStringAsFixed(0)}%');
    expect(r.meanRms, greaterThan(30),
        reason: 'sanity: this must be vigorous motion, not a still hand');
    expect(r.steadyPct, isNotNull);
    expect(r.steadyPct!, greaterThanOrEqualTo(85.0),
        reason: 'flagging ordinary eating would make the number useless');
  });

  group('shaking now moves the number', () {
    final cases = {
      'hard shake 3 Hz 100 dps': _shake(3, 100),
      'fast shake 5 Hz 120 dps': _shake(5, 120),
      'fine tremor 6 Hz 20 dps': _shake(6, 20),
      'small tremor 5 Hz 10 dps': _shake(5, 10),
    };
    cases.forEach((name, g) {
      test(name, () {
        final r = _run(g);
        // ignore: avoid_print
        print('  ${name.padRight(26)} rms=${r.meanRms.toStringAsFixed(0)} dps  '
            'shakeIndex=${r.meanShake.toStringAsFixed(2)}  '
            'steady=${r.steadyPct?.toStringAsFixed(0)}%');
        expect(r.steadyPct, isNotNull);
        // The whole complaint: this used to come back ~100.
        expect(r.steadyPct!, lessThan(50.0),
            reason: 'shaking still reads as steady');
      });
    });
  });

  test('the old metric genuinely could not see amplitude', () {
    // Pinning the reason, so nobody re-derives steadiness from `share` alone.
    final ref = loadModel().steadiness;
    final a = SteadinessAnalyzer(ref, sampleRateHz: _fs);
    SteadinessResult? last;
    final g = _shake(3, 150);
    for (var i = 0; i < _fs * 20; i++) {
      final v = g(i);
      final r = a.add(v[0], v[1], v[2]);
      if (r != null) last = r;
    }
    expect(last, isNotNull);
    expect(last!.motionRmsDps, greaterThan(80),
        reason: 'sanity: the hand is moving hard');
    expect(last.rhythmic, isFalse,
        reason: 'the narrowband test is blind to this — that was the bug');
    expect(last.shaky, isTrue, reason: 'the new test must catch it');
  });
}
