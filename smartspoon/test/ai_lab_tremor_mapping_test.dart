// The tremor index every screen shows is now derived from the AI Lab
// steadiness measure. This pins that mapping: an unmeasured reading must never
// look like a calm one, and a reading too short to trust must not be written
// to the database as if it were.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/insights/domain/services/unified_data_service.dart';

void main() {
  final at = DateTime(2026, 9, 15, 12);

  test('no steadiness data yet is unmeasured, not steady', () {
    final r = UnifiedDataService.aiLabTremorResult(
        steadyPct: null, rhythmHz: null, windowCount: 0, at: null);
    expect(r.measured, isFalse);
    expect(r.detected, isFalse);
    expect(r.score, 0);
  });

  test('a fully steady minute scores zero and is not flagged', () {
    final r = UnifiedDataService.aiLabTremorResult(
        steadyPct: 100, rhythmHz: null, windowCount: 60, at: at);
    expect(r.measured, isTrue);
    expect(r.detected, isFalse);
    expect(r.score, 0);
    expect(r.timestamp, at);
  });

  test('shaking maps onto the 0-3 scale the UI and database use', () {
    final half = UnifiedDataService.aiLabTremorResult(
        steadyPct: 50, rhythmHz: 5.2, windowCount: 60, at: at);
    expect(half.score, closeTo(1.5, 1e-9));
    expect(half.detected, isTrue);
    expect(half.frequency, 5.2);

    final constant = UnifiedDataService.aiLabTremorResult(
        steadyPct: 0, rhythmHz: 6, windowCount: 60, at: at);
    expect(constant.score, 3);
  });

  test('just past the AI Lab page threshold flags, just under does not', () {
    expect(
        UnifiedDataService.aiLabTremorResult(
                steadyPct: 74, rhythmHz: 5, windowCount: 60, at: at)
            .detected,
        isTrue);
    expect(
        UnifiedDataService.aiLabTremorResult(
                steadyPct: 76, rhythmHz: 5, windowCount: 60, at: at)
            .detected,
        isFalse);
  });

  test('confidence grows with the movement the reading is based on', () {
    final short = UnifiedDataService.aiLabTremorResult(
        steadyPct: 60, rhythmHz: 5, windowCount: 4, at: at);
    expect(short.confidence, lessThan(0.5), reason: 'DB write needs >= 0.5');

    // 5 s is enough to show AND to store: waiting 30 s left the first half
    // minute of every meal with no reading anywhere.
    final fiveSeconds = UnifiedDataService.aiLabTremorResult(
        steadyPct: 60, rhythmHz: 5, windowCount: 5, at: at);
    expect(fiveSeconds.confidence, greaterThanOrEqualTo(0.5));

    final full = UnifiedDataService.aiLabTremorResult(
        steadyPct: 60, rhythmHz: 5, windowCount: 40, at: at);
    expect(full.confidence, 1.0);
  });
}
