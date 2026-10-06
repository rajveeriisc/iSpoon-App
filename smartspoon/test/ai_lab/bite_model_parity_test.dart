// The phone must run the model the trainer scored. These tests replay the
// trainer's fixtures through the Dart engine and require the same features,
// probabilities, bites, hand and steadiness numbers.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/bite_features.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/eating_engine.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/handedness.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/imu_window.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/steadiness_analyzer.dart';

import 'ai_lab_fixtures.dart';

double _n(Object? v) => (v as num).toDouble();

void main() {
  final model = loadModel();
  final golden = loadGolden();

  for (final label in fixtureLabels) {
    final g = golden[label] as Map<String, dynamic>;
    final rows = loadFixture(g['file'] as String);

    group(label, () {
      test('features and probabilities match the trainer', () {
        final expected = {
          for (final d in g['decisions'] as List)
            (d as Map<String, dynamic>)['row'] as int: d,
        };
        final w = ImuWindow();
        var segStart = 0, checked = 0;
        for (var r = 0; r < rows.length; r++) {
          final s = rows[r];
          if (w.add(
              tsMs: s.ts, ax: s.ax, ay: s.ay, az: s.az,
              gx: s.gx, gy: s.gy, gz: s.gz)) {
            segStart = r;
          }
          final d = BiteFeatures.due(w);
          if (d == null) continue;
          final e = expected[segStart + d.t];
          if (e == null) continue;
          final ef = e['features'] as List;
          for (var i = 0; i < ef.length; i++) {
            expect(d.features[i], closeTo(_n(ef[i]), 1e-6),
                reason: 'row ${segStart + d.t} feature ${model.features[i]}');
          }
          expect(d.yaw, closeTo(_n(e['yaw']), 1e-6));
          expect(model.right.probability(d.features),
              closeTo(_n(e['pRight']), 1e-6));
          expect(
              model.neutral.probability(
                  BiteFeatures.forMode(d.features, HandMode.neutral)),
              closeTo(_n(e['pNeutral']), 1e-6));
          checked++;
        }
        expect(checked, (g['decisions'] as List).length);
      });

      test('auto-hand detector finds the same bites and hand', () {
        final engine = EatingEngine(model);
        for (final s in rows) {
          feedRow(engine, s);
        }
        expect(engine.detectedRows, (g['bitesAuto'] as List).cast<int>());
        expect(engine.voter.detected?.name, g['handAuto']);
      });

      test('right-hand detector finds the same bites', () {
        final engine = EatingEngine(model,
            voter: HandednessVoter(preference: HandPreference.right));
        for (final s in rows) {
          feedRow(engine, s);
        }
        expect(engine.detectedRows, (g['bitesRight'] as List).cast<int>());
      });

      test('steadiness windows match', () {
        final a = SteadinessAnalyzer(model.steadiness);
        final w = ImuWindow();
        var segStart = 0;
        final got = <List<double>>[];
        for (var r = 0; r < rows.length; r++) {
          final s = rows[r];
          if (w.add(
              tsMs: s.ts, ax: s.ax, ay: s.ay, az: s.az,
              gx: s.gx, gy: s.gy, gz: s.gz)) {
            a.reset();
            segStart = r;
          }
          final res = a.add(s.gx, s.gy, s.gz);
          if (res != null) {
            got.add([(segStart + res.n).toDouble(), res.share, res.hz]);
          }
        }
        final want = g['steadiness'] as List;
        expect(got.length, want.length);
        for (var i = 0; i < want.length; i++) {
          final e = want[i] as Map<String, dynamic>;
          expect(got[i][0], _n(e['row']));
          expect(got[i][1], closeTo(_n(e['share']), 1e-9));
          expect(got[i][2], closeTo(_n(e['hz']), 1e-9));
        }
      });
    });
  }
}
