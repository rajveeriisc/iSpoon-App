// The numbers every screen shows come through AiLabService: UnifiedDataService
// reads its bite total and its steadiness. This replays a real recorded meal
// through the service and checks what the rest of the app would receive.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartspoon/ble/models/runtime_models.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_service.dart';
import 'package:smartspoon/features/insights/domain/services/unified_data_service.dart';

import 'ai_lab_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a recorded meal reaches the app as bites and a steady reading',
      () async {
    SharedPreferences.setMockInitialValues({});
    final service = AiLabService();
    await service.start();
    addTearDown(service.dispose);

    expect(service.detectedBiteCountOrNull, isNull,
        reason: 'no sensor data yet must not look like a real zero');

    final rows = loadFixture('typical_eater.csv.gz');
    for (var i = 0; i < rows.length; i += 10) {
      service.debugFeed([
        for (final r in rows.skip(i).take(10))
          McuSensorData(
            accelX: r.ax, accelY: r.ay, accelZ: r.az,
            gyroX: r.gx, gyroY: r.gy, gyroZ: r.gz,
            temperature: 37,
            deviceId: 'test-spoon',
            timestamp: DateTime.fromMillisecondsSinceEpoch(r.ts),
          ),
      ]);
    }

    // The recording holds 20 tapped bites.
    expect(service.detectedBiteCount, inInclusiveRange(18, 22));
    expect(service.detectedBiteCountOrNull, service.detectedBiteCount);
    expect(service.lastBiteAt, isNotNull);

    // Steadiness: this is an ordinary eater, so the app should read "steady".
    expect(service.recentWindowCount, greaterThanOrEqualTo(30));
    expect(service.mealWindowCount, greaterThanOrEqualTo(30));
    expect(service.mealSteadyPct, greaterThanOrEqualTo(90),
        reason: 'the meal figure is what the AI Lab page shows');

    // What the other screens read must be the SAME meal figure, not the
    // jumpier rolling minute (86.7 % here) — otherwise Home and AI Lab
    // disagree in front of the user.
    final tremor = UnifiedDataService.aiLabTremorResult(
      steadyPct: service.mealSteadyPct,
      rhythmHz: service.mealRhythmHz,
      windowCount: service.mealWindowCount,
      at: service.lastWindowAt,
    );
    expect((100 - tremor.score / 3 * 100), closeTo(service.mealSteadyPct!, 1e-6));
    expect(tremor.measured, isTrue);
    expect(tremor.detected, isFalse, reason: 'normal eating is not a tremor');
    expect(tremor.score, lessThan(0.5));
    expect(tremor.confidence, greaterThanOrEqualTo(0.5),
        reason: 'a full meal is trustworthy enough to store per bite');
  });
}
