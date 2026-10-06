// Shared loaders for the AI Lab tests. The fixtures and golden file are
// written by tools/ai_lab/train_bite_model.py; see tools/ai_lab/README.md.
import 'dart:convert';
import 'dart:io';

import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/eating_engine.dart';

class FixtureRow {
  const FixtureRow(this.ts, this.ax, this.ay, this.az, this.gx, this.gy,
      this.gz, this.mark);
  final int ts;
  final double ax, ay, az, gx, gy, gz;
  final bool mark;
}

const fixtureLabels = ['typical_eater', 'slow_eater'];

List<FixtureRow> loadFixture(String file) {
  final text = utf8.decode(
      gzip.decode(File('test/fixtures/ai_lab/$file').readAsBytesSync()));
  return [
    for (final line in const LineSplitter().convert(text).skip(1))
      if (line.isNotEmpty)
        () {
          final c = line.split(',');
          return FixtureRow(
            int.parse(c[0]),
            double.parse(c[1]),
            double.parse(c[2]),
            double.parse(c[3]),
            double.parse(c[4]),
            double.parse(c[5]),
            double.parse(c[6]),
            c[7] == '1',
          );
        }(),
  ];
}

Map<String, dynamic> loadGolden() =>
    jsonDecode(File('test/fixtures/ai_lab/parity_golden.json')
        .readAsStringSync()) as Map<String, dynamic>;

AiLabModel loadModel() =>
    AiLabModel.parse(File(AiLabModel.assetPath).readAsStringSync());

void feedRow(EatingEngine e, FixtureRow s) => e.feed(
    tsMs: s.ts, ax: s.ax, ay: s.ay, az: s.az, gx: s.gx, gy: s.gy, gz: s.gz);

/// Like [feedRow] but hands back what the engine reported, for tests that
/// need to count emitted bites rather than just drive the stream.
EngineUpdate feedRowUpdate(EatingEngine e, FixtureRow s) => e.feed(
      tsMs: s.ts,
      ax: s.ax,
      ay: s.ay,
      az: s.az,
      gx: s.gx,
      gy: s.gy,
      gz: s.gz,
    );
