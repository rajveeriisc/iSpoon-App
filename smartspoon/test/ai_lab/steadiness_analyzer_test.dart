import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/steadiness_analyzer.dart';

import 'ai_lab_fixtures.dart';

void main() {
  final ref = loadModel().steadiness;

  List<SteadinessResult> run(double Function(int i) gx, {int n = 1200}) {
    final a = SteadinessAnalyzer(ref);
    final rng = math.Random(7);
    return [
      for (var i = 0; i < n; i++)
        a.add(gx(i) + rng.nextDouble() - 0.5, rng.nextDouble() - 0.5,
            rng.nextDouble() - 0.5),
    ].whereType<SteadinessResult>().toList();
  }

  test('a window every second once 256 samples are buffered', () {
    final out = run((_) => 0, n: 650);
    expect(out.map((r) => r.n), [300, 400, 500, 600]);
  });

  test('a 5 Hz, 20 deg/s tremor is flagged at its frequency', () {
    final out =
        run((i) => 20 * math.sqrt2 * math.sin(2 * math.pi * 5 * i / 100));
    expect(out, isNotEmpty);
    for (final r in out) {
      expect(r.rhythmic, isTrue);
      expect(r.hz, closeTo(5, 0.4));
    }
  });

  test('broadband noise is not rhythmic', () {
    final rng = math.Random(3);
    final out = run((_) => (rng.nextDouble() - 0.5) * 60);
    expect(out.where((r) => r.rhythmic), isEmpty);
  });
}
