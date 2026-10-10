// Cards must clear the floating bottom nav, on every phone.
//
// Reported as cards looking wrongly sized and arranged. The measurable part of
// that was two numbers guessed in two places: the nav bar was 64 high with a
// margin derived from the home-indicator inset, while the lists above it
// padded a flat 100 (Home) or 110 (Mealsense). On an iPhone 14 the nav
// occupies 106, so Home's last card went underneath it; with no inset the nav
// needs 80, so Mealsense wasted 30.
//
// These pin the relationship rather than the numbers: whatever the nav bar
// takes, the list must stop at least that far short of the bottom.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/card_layout.dart';

/// Logical size and bottom view padding of the phones this has to fit.
const _devices = <String, (Size, double)>{
  'iPhone SE (375x667, no indicator)': (Size(375, 667), 0),
  'iPhone 13 mini (375x812)': (Size(375, 812), 34),
  'iPhone 14 (390x844)': (Size(390, 844), 34),
  'iPhone 14 Pro Max (430x932)': (Size(430, 932), 34),
  'Android, gesture nav (412x915)': (Size(412, 915), 24),
  'Android, 3-button nav (412x870)': (Size(412, 870), 0),
};

Future<T> _measure<T>(
  WidgetTester tester,
  Size size,
  double bottomInset,
  T Function(BuildContext) read,
) async {
  late T out;
  await tester.pumpWidget(MediaQuery(
    data: MediaQueryData(
      size: size,
      viewPadding: EdgeInsets.only(bottom: bottomInset),
      padding: EdgeInsets.only(bottom: bottomInset),
    ),
    child: MaterialApp(
      home: Builder(builder: (context) {
        out = read(context);
        return const SizedBox.shrink();
      }),
    ),
  ));
  return out;
}

void main() {
  group('a list always stops short of the nav bar', () {
    for (final e in _devices.entries) {
      final (size, inset) = e.value;
      testWidgets(e.key, (tester) async {
        final bottom =
            await _measure(tester, size, inset, CardLayout.listBottomInset);
        final navMargin =
            await _measure(tester, size, inset, CardLayout.navBarMargin);
        final occupied = kBottomNavHeight + navMargin;

        expect(bottom, greaterThan(occupied),
            reason: 'the last card would sit under the nav bar');
        // And not absurdly more — dead space was the other half of the bug.
        expect(bottom - occupied, lessThanOrEqualTo(AppTheme.spaceLg),
            reason: 'too much dead space below the last card');
      });
    }
  });

  testWidgets('the old hardcoded 100 really was too small on an iPhone 14',
      (tester) async {
    final navMargin = await _measure(
        tester, const Size(390, 844), 34, CardLayout.navBarMargin);
    // 64 + (34 + 8) = 106 > 100. This is the bug, pinned so nobody
    // "simplifies" the clearance back to a literal.
    expect(kBottomNavHeight + navMargin, greaterThan(100.0));
  });

  group('gutters step by device class and stay on the 4pt grid', () {
    for (final e in _devices.entries) {
      final (size, inset) = e.value;
      testWidgets(e.key, (tester) async {
        final g = await _measure(tester, size, inset, CardLayout.gutterOf);
        expect(g % 4, 0, reason: '$g is off the 4pt grid');
        expect(g, inInclusiveRange(16.0, 24.0));
      });
    }

    testWidgets('a bigger phone never gets a smaller gutter', (tester) async {
      final se = await _measure(
          tester, const Size(375, 667), 0, CardLayout.gutterOf);
      final mid = await _measure(
          tester, const Size(390, 844), 34, CardLayout.gutterOf);
      final max = await _measure(
          tester, const Size(430, 932), 34, CardLayout.gutterOf);
      expect(mid, greaterThanOrEqualTo(se));
      expect(max, greaterThanOrEqualTo(mid));
    });
  });

  test('card and section gaps are one tier apart on the grid', () {
    expect(CardLayout.cardGap % 4, 0);
    expect(CardLayout.sectionGap % 4, 0);
    expect(CardLayout.sectionGap, greaterThan(CardLayout.cardGap));
  });
}
