// Two reported failures, measured against the real recordings:
//
//   1. "I shake my hand a lot but the card still says stable, near 90."
//   2. "I rotate my hand fully / wave it in the air and it still detects."
//
// Both are about what the shipped model actually gates on. The bite-cycle
// tracker — the part that checks a bite looked like scoop, lift, mouth,
// return — is configured enforce:false, so it computes a verdict and the
// engine ignores it. Only the probability classifier at threshold 0.35
// decides. This measures what that costs and what enabling the gate would
// buy, using the 8 labelled sessions on disk plus synthetic non-eating motion.
//
// The recordings live outside the repo, so the real-meal part skips when they
// are absent rather than failing CI.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/eating_engine.dart';

import 'ai_lab_fixtures.dart';

const _dir = '/Users/beeslabrajveer/Desktop/bites';

class _Row {
  _Row(this.ts, this.ax, this.ay, this.az, this.gx, this.gy, this.gz, this.mark);
  final int ts;
  final double ax, ay, az, gx, gy, gz;
  final bool mark;
}

List<_Row> _readCsv(File f) {
  final lines = f.readAsLinesSync();
  if (lines.length < 2) return const [];
  final head = lines.first.split(',');
  int c(String n) => head.indexOf(n);
  final iTs = c('timestamp_ms'),
      iAx = c('accelX'),
      iAy = c('accelY'),
      iAz = c('accelZ'),
      iGx = c('gyroX'),
      iGy = c('gyroY'),
      iGz = c('gyroZ'),
      iMark = c('user_bite_mark');
  final out = <_Row>[];
  for (final l in lines.skip(1)) {
    final p = l.split(',');
    if (p.length <= iGz) continue;
    final m = iMark >= 0 && iMark < p.length
        ? (double.tryParse(p[iMark]) ?? 0) > 0
        : false;
    out.add(_Row(
      int.tryParse(p[iTs]) ?? 0,
      double.tryParse(p[iAx]) ?? 0,
      double.tryParse(p[iAy]) ?? 0,
      double.tryParse(p[iAz]) ?? 0,
      double.tryParse(p[iGx]) ?? 0,
      double.tryParse(p[iGy]) ?? 0,
      double.tryParse(p[iGz]) ?? 0,
      m,
    ));
  }
  return out;
}

/// Replays [rows] and reports what the engine counted and what the (ignored)
/// cycle gate decided.
({int counted, int cycleAccepted, int cycleRejected, Map<String, int> reasons})
    _replay(AiLabModel model, List<_Row> rows) {
  final e = EatingEngine(model);
  var counted = 0, acc = 0, rej = 0;
  final reasons = <String, int>{};
  for (final r in rows) {
    final u = e.feed(
        tsMs: r.ts, ax: r.ax, ay: r.ay, az: r.az, gx: r.gx, gy: r.gy, gz: r.gz);
    if (u.bite != null) counted++;
    for (final o in u.cycleOutcomes) {
      if (o.accepted) {
        acc++;
      } else {
        rej++;
        final k = o.reason?.name ?? 'unknown';
        reasons[k] = (reasons[k] ?? 0) + 1;
      }
    }
  }
  return (counted: counted, cycleAccepted: acc, cycleRejected: rej, reasons: reasons);
}

final _rng = math.Random(7);
double _n(double a) => (_rng.nextDouble() * 2 - 1) * a;

/// Non-eating motion: the spoon held and shaken/waved, gravity rotating with
/// it but never completing a scoop-lift-mouth-return cycle.
List<_Row> _synthetic({
  required double hz,
  required double dps,
  required int seconds,
}) {
  final out = <_Row>[];
  for (var i = 0; i < seconds * 100; i++) {
    final t = i / 100.0;
    final ph = 2 * math.pi * hz * t;
    final s = dps * math.sin(ph) + _n(dps * 0.3);
    // Gravity swings with the wrist but returns to where it started, so there
    // is no sustained new plate pose and no mouth dwell.
    final tilt = 0.5 * math.sin(ph);
    out.add(_Row(
      i * 10,
      tilt + _n(0.05),
      -0.33 + tilt * 0.5 + _n(0.05),
      0.92 - tilt.abs() * 0.3 + _n(0.05),
      s,
      s * 0.7 + _n(dps * 0.2),
      s * 0.4 + _n(dps * 0.2),
      false,
    ));
  }
  return out;
}

void main() {
  final model = loadModel();

  test('the shipped model ignores its own cycle gate', () {
    expect(model.biteCycle.enforce, isFalse,
        reason: 'if this is now true, the numbers below are stale');
  });

  test('non-eating motion: what the engine counts vs what the gate would say',
      () {
    // ignore: avoid_print
    print('\n  SYNTHETIC NON-EATING MOTION (no scoop-lift-mouth-return)\n'
        '  case                         counted  gate-accept  gate-reject');
    final cases = {
      'hard shake 3 Hz 100 dps': _synthetic(hz: 3, dps: 100, seconds: 60),
      'fast shake 5 Hz 120 dps': _synthetic(hz: 5, dps: 120, seconds: 60),
      'waving 1 Hz 200 dps': _synthetic(hz: 1, dps: 200, seconds: 60),
      'slow rotation 0.5 Hz 80 dps': _synthetic(hz: 0.5, dps: 80, seconds: 60),
    };
    for (final e in cases.entries) {
      final r = _replay(model, e.value);
      // ignore: avoid_print
      print('  ${e.key.padRight(28)} ${r.counted.toString().padLeft(7)}  '
          '${r.cycleAccepted.toString().padLeft(11)}  '
          '${r.cycleRejected.toString().padLeft(11)}'
          '${r.reasons.isEmpty ? '' : '   ${r.reasons}'}');
    }
  });

  test('real labelled meals: does the gate agree with the ground truth?', () {
    final dir = Directory(_dir);
    if (!dir.existsSync()) {
      // ignore: avoid_print
      print('  (no recordings at $_dir — skipping)');
      return;
    }
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.csv'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    // ignore: avoid_print
    print('\n  REAL MEALS (user_bite_mark = ground truth)\n'
        '  session               truth  counted  gate-accept  gate-reject');
    var tTruth = 0, tCount = 0, tAcc = 0, tRej = 0;
    final allReasons = <String, int>{};
    for (final f in files) {
      final rows = _readCsv(f);
      if (rows.isEmpty) continue;
      final truth = rows.where((r) => r.mark).length;
      final r = _replay(model, rows);
      tTruth += truth;
      tCount += r.counted;
      tAcc += r.cycleAccepted;
      tRej += r.cycleRejected;
      r.reasons.forEach((k, v) => allReasons[k] = (allReasons[k] ?? 0) + v);
      // ignore: avoid_print
      print('  ${f.path.split('/').last.substring(14, 33)}  '
          '${truth.toString().padLeft(5)}  ${r.counted.toString().padLeft(7)}  '
          '${r.cycleAccepted.toString().padLeft(11)}  '
          '${r.cycleRejected.toString().padLeft(11)}');
    }
    // ignore: avoid_print
    print('  ${'TOTAL'.padRight(19)}  ${tTruth.toString().padLeft(5)}  '
        '${tCount.toString().padLeft(7)}  ${tAcc.toString().padLeft(11)}  '
        '${tRej.toString().padLeft(11)}');
    // ignore: avoid_print
    print('  reject reasons on REAL meals: $allReasons\n');
  });
}
