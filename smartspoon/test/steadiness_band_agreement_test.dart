// One set of steadiness bands for every screen.
//
// Home and Insights classify from the 0-3 index; AI Lab classifies from the
// steady percentage. They used to carry independent numbers — index 0.6/1.4
// against 90%/75% — which are NOT the same cut: 0.6 is 80% steady and 1.4 is
// 53% steady. The same reading therefore got different verdicts depending on
// which screen you were looking at: 82% was "Mostly steady" on AI Lab and
// "Steady hand" on Home; 74% was red "Frequent rhythmic shaking" on AI Lab and
// merely "Some shake" on Home.
//
// The index thresholds are now derived from the percentage bands, so this test
// fails the moment anyone re-hardcodes either side.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/ai_lab_card.dart';
import 'package:smartspoon/features/devices/domain/services/tremor_detection_service.dart';
import 'package:smartspoon/features/insights/domain/models.dart';

/// The index the app stores for a given steadiness percentage.
/// Mirrors UnifiedDataService.aiLabTremorResult: score = shakeShare * 3.
double indexFor(double steadyPct) => 3.0 * (100.0 - steadyPct) / 100.0;

/// What the index-based screens (Home, Insights) call this reading.
/// `<=` mirrors production: the percentage side is inclusive and the index
/// runs the other way, so the boundary has to be inclusive here too.
String indexBand(double index) => index <= TremorMetrics.moderateThreshold
    ? 'steady'
    : index <= TremorMetrics.highThreshold
        ? 'middle'
        : 'worst';

/// What the percentage-based screen (AI Lab) calls the same reading.
String pctBand(double pct) => pct >= kSteadyFromPct
    ? 'steady'
    : pct >= kShakyBelowPct
        ? 'middle'
        : 'worst';

void main() {
  test('the two threshold owners agree with each other', () {
    expect(TremorMetrics.moderateThreshold, TremorResult.moderateThreshold);
    expect(TremorMetrics.highThreshold, TremorResult.highThreshold);
  });

  test('index thresholds are the percentage bands, expressed as an index', () {
    expect(TremorMetrics.moderateThreshold, closeTo(indexFor(kSteadyFromPct), 1e-9));
    expect(TremorMetrics.highThreshold, closeTo(indexFor(kShakyBelowPct), 1e-9));
    // The concrete values, so a silent change is visible in the diff.
    expect(TremorMetrics.moderateThreshold, closeTo(0.30, 1e-9));
    expect(TremorMetrics.highThreshold, closeTo(0.75, 1e-9));
  });

  test('every percentage lands in the same band on both scales', () {
    // Includes the two readings that used to disagree.
    for (var pct = 0; pct <= 100; pct++) {
      final p = pct.toDouble();
      expect(indexBand(indexFor(p)), pctBand(p),
          reason: '$pct% must mean the same thing on every screen');
    }
  });

  test('the AI Lab wording follows those same bands', () {
    expect(steadinessLabel(95), 'Steady');
    expect(steadinessLabel(90), 'Steady');
    expect(steadinessLabel(85), 'Mostly steady');
    expect(steadinessLabel(82), 'Mostly steady');
    expect(steadinessLabel(75), 'Mostly steady');
    expect(steadinessLabel(74), 'Frequent rhythmic shaking');
    expect(steadinessLabel(50), 'Frequent rhythmic shaking');
  });

  test('the readings that used to disagree now agree', () {
    for (final pct in [85.0, 82.0, 76.0, 74.0, 60.0]) {
      expect(indexBand(indexFor(pct)), pctBand(pct), reason: '$pct%');
    }
  });
}
