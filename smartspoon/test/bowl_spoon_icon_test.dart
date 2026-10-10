// The bowl-and-spoon glyph is painted, not taken from the icon font, so these
// check the things a CustomPainter can silently get wrong: that it paints at
// all, that it stays inside its box, and that it follows IconTheme the way a
// real Icon does — the "Bite" button and the phase chip both rely on that
// rather than passing a colour.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/bowl_spoon_icon.dart';

void main() {
  testWidgets('paints without error and honours its size', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: BowlSpoonIcon(size: 32))),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(BowlSpoonIcon)), const Size(32, 32));
  });

  testWidgets('inherits IconTheme colour when none is given', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: IconTheme(
          data: IconThemeData(color: Color(0xFF123456)),
          child: Scaffold(body: Center(child: BowlSpoonIcon())),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    // A CustomPaint's painter is where the resolved colour lands; comparing
    // two painters tells us the inherited and explicit paths agree.
    final inherited = tester
        .widget<CustomPaint>(find.descendant(
            of: find.byType(BowlSpoonIcon), matching: find.byType(CustomPaint)))
        .painter;
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(child: BowlSpoonIcon(color: Color(0xFF123456))),
      ),
    ));
    final explicit = tester
        .widget<CustomPaint>(find.descendant(
            of: find.byType(BowlSpoonIcon), matching: find.byType(CustomPaint)))
        .painter;
    // shouldRepaint compares colour, so equal colours mean no repaint needed.
    expect(explicit!.shouldRepaint(inherited!), isFalse,
        reason: 'IconTheme colour was not picked up');
  });

  testWidgets('scales down to a chip-sized 15px without throwing',
      (tester) async {
    // The phase chip in live_meal_card draws it at 15.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: BowlSpoonIcon(size: 15))),
    ));
    expect(tester.takeException(), isNull);
  });
}
