// "I rotate my hand fully / wave it in the air and it still detects."
//
// Two recordings of deliberate non-eating movement — 91 seconds, no bites —
// produced 25 counted bites, most at a classifier probability of 1.00. The
// classifier judges the shape of one lift, and arbitrary movement contains
// lifts of that shape, so nothing about its threshold could fix this.
//
// BiteMotionGate asks a different question of the seconds around each
// proposed bite: was there a still moment (the spoon in the mouth), and was
// the movement intermittent rather than continuous. Its limits were set from
// 359 real bites alone; these recordings were not used to choose them.
//
// The non-eating recordings are checked in as fixtures. The eighteen eating
// sessions are too large for that, so the real-meal half of this runs when
// they are present on disk and the two bundled real meals cover it otherwise.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/bite_motion_gate.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/eating_engine.dart';

import 'ai_lab_fixtures.dart';

AiLabModel _model({required bool gate}) {
  final j = jsonDecode(File(AiLabModel.assetPath).readAsStringSync())
      as Map<String, dynamic>;
  (j['motionGate'] as Map<String, dynamic>)['enforce'] = gate;
  return AiLabModel.parse(jsonEncode(j));
}

List<List<double>> _rows(String csv) {
  final lines = const LineSplitter().convert(csv);
  final h = lines.first.split(',');
  final iT = h.indexOf('timestamp_ms'),
      iA = h.indexOf('accelX'),
      iG = h.indexOf('gyroX');
  return [
    for (final l in lines.skip(1))
      if (l.split(',').length > iG + 2)
        () {
          final p = l.split(',');
          return [
            double.parse(p[iT]),
            for (var k = 0; k < 3; k++) double.parse(p[iA + k]),
            for (var k = 0; k < 3; k++) double.parse(p[iG + k]),
          ];
        }(),
  ];
}

List<List<double>> _gz(String name) => _rows(utf8.decode(
    gzip.decode(File('test/fixtures/ai_lab/$name').readAsBytesSync())));

({int bites, int refused}) _count(AiLabModel m, List<List<double>> rows) {
  final e = EatingEngine(m);
  var n = 0;
  for (final p in rows) {
    final u = e.feed(
        tsMs: p[0].toInt(),
        ax: p[1], ay: p[2], az: p[3],
        gx: p[4], gy: p[5], gz: p[6]);
    if (u.bite != null) n++;
  }
  return (bites: n, refused: e.motionGateRejections);
}

void main() {
  test('the shipped model enforces the gate', () {
    expect(loadModel().motionGate.enforce, isTrue);
  });

  group('real non-eating movement no longer counts as bites', () {
    for (final f in ['non_eating_1.csv.gz', 'non_eating_2.csv.gz']) {
      test(f, () {
        final rows = _gz(f);
        final before = _count(_model(gate: false), rows);
        final after = _count(_model(gate: true), rows);
        // ignore: avoid_print
        print('  $f  ${rows.length ~/ 100}s  '
            'without gate ${before.bites} bites, with gate ${after.bites} '
            '(${after.refused} refused)');
        expect(before.bites, greaterThanOrEqualTo(10),
            reason: 'sanity: this recording is what fooled the classifier');
        expect(after.bites, 0);
      });
    }
  });

  group('real meals lose nothing to it', () {
    for (final label in fixtureLabels) {
      test('bundled $label', () {
        final golden = loadGolden();
        final rows = loadFixture(
            (golden[label] as Map<String, dynamic>)['file'] as String);
        int run(AiLabModel m) {
          final e = EatingEngine(m);
          var n = 0;
          for (final r in rows) {
            if (feedRowUpdate(e, r).bite != null) n++;
          }
          return n;
        }

        expect(run(_model(gate: true)), run(_model(gate: false)));
      });
    }

    test('all labelled sessions on disk, 20 marked bites each', () {
      final dir = Directory('/Users/beeslabrajveer/Desktop/bites');
      if (!dir.existsSync()) return;
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.split('/').last.startsWith('spoon_session'))
          .toList();
      var off = 0, on = 0;
      var worst = 0;
      for (final f in files) {
        final rows = _rows(f.readAsStringSync());
        final a = _count(_model(gate: false), rows).bites;
        final b = _count(_model(gate: true), rows).bites;
        off += a;
        on += b;
        worst = math.max(worst, a - b);
      }
      // ignore: avoid_print
      print('  ${files.length} sessions, ${files.length * 20} marked bites: '
          'counted $off without the gate, $on with it');
      expect(worst, lessThanOrEqualTo(1),
          reason: 'no single meal may lose more than one bite to the gate');
      expect(on, greaterThanOrEqualTo((off * 0.99).floor()));
    });
  });

  group('the gate on its own', () {
    BiteMotionGate gate() => BiteMotionGate(const MotionGateConfig());

    test('a still moment inside moderate movement is accepted', () {
      final g = gate();
      for (var i = 0; i < 500; i++) {
        // Moving at 80 deg/s with a 300 ms stop at the mouth.
        g.add(i >= 300 && i < 330 ? 4.0 : 80.0);
      }
      final v = g.evaluate();
      expect(v.accepted, isTrue);
      expect(v.quietDps, lessThan(10));
    });

    test('continuous movement with no stop is refused', () {
      final g = gate();
      for (var i = 0; i < 500; i++) {
        g.add(70.0); // gentle enough to pass the mean, but it never stops
      }
      final v = g.evaluate();
      expect(v.accepted, isFalse);
      expect(v.quietDps, closeTo(70, 0.01));
    });

    test('vigorous movement is refused even if it pauses once', () {
      final g = gate();
      for (var i = 0; i < 500; i++) {
        g.add(i >= 200 && i < 225 ? 3.0 : 200.0);
      }
      expect(g.evaluate().accepted, isFalse);
    });

    test('a stream that has only just started is not penalised', () {
      final g = gate();
      for (var i = 0; i < 10; i++) {
        g.add(300.0);
      }
      expect(g.evaluate().accepted, isTrue,
          reason: 'ten samples is not evidence of anything');
    });

    test('reset forgets the previous stream', () {
      final g = gate();
      for (var i = 0; i < 500; i++) {
        g.add(300.0);
      }
      g.reset();
      expect(g.evaluate().samples, 0);
    });
  });
}
