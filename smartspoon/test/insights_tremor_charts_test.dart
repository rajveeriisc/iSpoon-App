import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/insights/domain/models.dart';
import 'package:smartspoon/features/insights/presentation/widgets/tremor_charts.dart';

void main() {
  testWidgets('TremorCharts shows current level and formatted metrics', (
    tester,
  ) async {
    const metrics = TremorMetrics(
      currentMagnitude: 0.42,
      peakFrequencyHz: 5.1,
      confidence: 0.82,
      sampleDurationSeconds: 46,
      level: TremorLevel.low,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TremorCharts(metrics: metrics)),
      ),
    );

    expect(find.text('Movement pattern'), findsOneWidget);
    expect(find.text('Repeated hand motion while eating'), findsOneWidget);
    expect(find.text('No repeated rhythm'), findsOneWidget);
    // Sample size, stated as such — not a quality grade. 46 s measured.
    expect(find.text('46s OF MOVEMENT'), findsOneWidget);
    expect(find.text('Measured over 46s of movement'), findsOneWidget);
    // The useful numbers: how much of the measured time was steady, and the
    // rhythm itself — not a vague "Found".
    expect(find.text('Steady time'), findsOneWidget);
    expect(find.text('86'), findsOneWidget, reason: '0.42 of 3 shaky → 86 %');
    expect(find.text('Repeated rhythm'), findsOneWidget);
    expect(find.text('5.1'), findsOneWidget);
    // Was 'Reading quality 82%'. confidence is active-seconds/10, i.e.
    // sample size, so the card now states the seconds of movement instead of
    // grading the signal it never checked.
    expect(find.text('Measured over 46s of movement'), findsOneWidget);
    expect(
      find.text('Measured by Mealsense over 46 s: '
          'index 0.42 / 3, rhythm 5.1 Hz'),
      findsOneWidget,
    );
  });

  testWidgets('TremorCharts renders optional history action', (tester) async {
    var tapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TremorCharts(onViewHistory: () => tapped = true)),
      ),
    );

    await tester.tap(find.text('View History'));
    await tester.pump();

    expect(tapped, isTrue);
  });

  testWidgets('TremorCharts does not present missing data as steady', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TremorCharts(
            metrics: TremorMetrics(
              isMeasured: false,
              currentMagnitude: 0,
              peakFrequencyHz: 0,
              level: TremorLevel.low,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Collecting a steady sample'), findsOneWidget);
    expect(find.text('NO REPEATED RHYTHM'), findsNothing);
  });
}
