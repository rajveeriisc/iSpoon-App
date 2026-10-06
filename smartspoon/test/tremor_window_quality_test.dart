import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/ble/models/runtime_models.dart';
import 'package:smartspoon/features/devices/domain/services/tremor_detection_service.dart';

List<McuSensorData> _samples({
  double frequencyHz = 0,
  bool addPacketGaps = false,
  bool addImpact = false,
}) {
  final start = DateTime(2026, 1, 1);
  var elapsedMs = 0;
  return List.generate(500, (i) {
    if (i > 0) elapsedMs += addPacketGaps && i % 10 == 0 ? 40 : 10;
    final oscillation = frequencyHz == 0
        ? 0.0
        : 0.05 * math.sin(2 * math.pi * frequencyHz * i / 100);
    return McuSensorData(
      accelX: oscillation,
      accelY: 0,
      accelZ: addImpact && i == 250 ? 9.0 : 1.0,
      gyroX: 0,
      gyroY: 0,
      gyroZ: 0,
      temperature: 30,
      timestamp: start.add(Duration(milliseconds: elapsedMs)),
    );
  });
}

void main() {
  test('clean 5 Hz window produces a measured rhythmic result', () {
    final result = TremorDetectionService.analyzeSamplesForTest(
      _samples(frequencyHz: 5),
    );

    expect(result.measured, isTrue);
    expect(result.detected, isTrue);
    expect(result.frequency, closeTo(5, 0.5));
    expect(result.confidence, greaterThanOrEqualTo(0.5));
    expect(result.windowDurationMs, 5000);
  });

  test('clean still window is measured low, not missing', () {
    final result = TremorDetectionService.analyzeSamplesForTest(_samples());

    expect(result.measured, isTrue);
    expect(result.detected, isFalse);
    expect(result.score, 0);
  });

  test('packet gaps make the measurement unavailable', () {
    final result = TremorDetectionService.analyzeSamplesForTest(
      _samples(frequencyHz: 5, addPacketGaps: true),
    );

    expect(result.measured, isFalse);
  });

  test('impact-contaminated window is rejected instead of scored', () {
    final result = TremorDetectionService.analyzeSamplesForTest(
      _samples(frequencyHz: 5, addImpact: true),
    );

    expect(result.measured, isFalse);
  });
}
