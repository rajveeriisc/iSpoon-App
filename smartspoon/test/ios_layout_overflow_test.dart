// Cards must fit real iPhones, at the text sizes iOS users actually choose.
//
// Reported from the device: cards looked oversized and "not matched" on iOS.
// Two causes, both from fixed-height boxes wrapping text that scales:
//
//   - At the default text size a hard 152 px card held ~127 px of content,
//     so 25 px was dead space and the card read as too big.
//   - At the 1.6x scale main.dart clamps to, the same content needs ~158 px
//     and overflowed.
//
// iOS is where this shows first because an iPhone 14 is 390 dp wide and an
// SE/mini is 375 dp — narrower than most Android phones — and iOS users
// change Dynamic Type far more often than Android users change font size.
//
// Flutter reports an overflow by painting the yellow/black stripes AND
// throwing in debug, so takeException() is what catches it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/insights/presentation/widgets/summary_cards.dart';

/// Logical sizes of the phones this has to fit.
const _devices = <String, Size>{
  'iPhone SE / mini (375x667)': Size(375, 667),
  'iPhone 14 (390x844)': Size(390, 844),
  'iPhone 14 Pro Max (430x932)': Size(430, 932),
};

/// 1.0 is the iOS default; 1.6 is what main.dart clamps accessibility text to.
const _scales = <double>[1.0, 1.3, 1.6];

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required Size size,
  required double scale,
}) async {
  // MediaQuery below is what the widgets read, so the size and text scale are
  // set there. Touching tester.view as well only muddled it.
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(scale),
      ),
      child: MaterialApp(
        home: Scaffold(
          // A real screen scrolls, so vertical room is not the constraint —
          // the card's own fixed height was.
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('summary cards fit every iPhone at every allowed text size', () {
    for (final entry in _devices.entries) {
      for (final scale in _scales) {
        testWidgets('${entry.key} @ ${scale}x', (tester) async {
          await _pump(
            tester,
            const SummaryCards(totalBites: 247, paceBpm: 12.4),
            size: entry.value,
            scale: scale,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: 'overflowed on ${entry.key} at ${scale}x text',
          );
        });
      }
    }
  });

  testWidgets('the two cards stay the same height — "not matched" was the complaint',
      (tester) async {
    await _pump(
      tester,
      const SummaryCards(totalBites: 8, paceBpm: 123.4),
      size: const Size(390, 844),
      scale: 1.0,
    );
    // One card carries a unit line and the other does not, so without
    // IntrinsicHeight they would differ.
    final cards = tester.widgetList<InkWell>(find.byType(InkWell)).toList();
    expect(cards.length, greaterThanOrEqualTo(2));
    final h = [
      for (final e in find.byType(InkWell).evaluate().take(2))
        tester.getSize(find.byWidget(e.widget)).height,
    ];
    expect(h[0], closeTo(h[1], 0.5), reason: 'cards must match in height');
  });

  testWidgets('no dead space: the card is as tall as its content, not a fixed 152',
      (tester) async {
    await _pump(
      tester,
      const SummaryCards(totalBites: 247, paceBpm: 12.4),
      size: const Size(390, 844),
      scale: 1.0,
    );
    final height =
        tester.getSize(find.byType(IntrinsicHeight).first).height;
    // The old hard-coded box was 152 with ~127 of content in it.
    // Measured at 146 px for this content at the default text size, against
    // the old hard-coded 152.
    expect(height, lessThan(152.0),
        reason: 'still padded out to the old fixed height');
    expect(height, greaterThan(120.0), reason: 'sanity: not collapsed');
  });

  testWidgets('grows with the text instead of clipping it', (tester) async {
    await _pump(
      tester,
      const SummaryCards(totalBites: 247, paceBpm: 12.4),
      size: const Size(390, 844),
      scale: 1.0,
    );
    final small = tester.getSize(find.byType(IntrinsicHeight).first).height;

    await _pump(
      tester,
      const SummaryCards(totalBites: 247, paceBpm: 12.4),
      size: const Size(390, 844),
      scale: 1.6,
    );
    final large = tester.getSize(find.byType(IntrinsicHeight).first).height;

    expect(large, greaterThan(small),
        reason: 'a fixed height would have clipped rather than grown');
  });
}
