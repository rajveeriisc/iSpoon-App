// card_layout.dart — the two measurements every card list on this app needs.
//
// Reported as cards being the wrong size and badly arranged, and the cause was
// that both numbers were guessed separately in each screen:
//
//   Home     fromLTRB(20, 10, 20, 100)
//   Mealsense fromLTRB(18, 20, 18, 110)
//   Suggestions card   horizontal: width * 0.05
//
// Three different gutters, none adapting to the device, and two different
// guesses at how much room the floating bottom nav takes. On an iPhone 14 the
// nav actually occupies 106 px (64 high + a 42 px bottom margin derived from
// the 34 px home-indicator inset), so Home's 100 px left the last card
// underneath it. On a device with no inset the nav needs only 80 px, so
// Mealsense's 110 px left 30 px of dead space.
//
// Both numbers now come from here, and the nav bar itself is built from the
// same height constant, so the clearance cannot drift away from the thing it
// is clearing.
import 'package:flutter/material.dart';

import 'package:smartspoon/core/theme/app_theme.dart';

/// Height of the floating bottom navigation bar.
///
/// Used both to build the bar and to work out how far a scrolling list has to
/// stop short of it. Those were separate literals before, which is how they
/// came to disagree.
const double kBottomNavHeight = 64.0;

/// The home indicator inset above which the nav bar stops using a flat margin
/// and starts following the system inset instead.
const double _kGestureBarInsetThreshold = 22.0;

abstract final class CardLayout {
  /// Horizontal inset for a column of cards, by device class.
  ///
  /// iOS widens its readable content margins on physically larger phones
  /// rather than holding one inset and letting the line length grow, which is
  /// why these step rather than scale. Every value is on the 4 pt grid; the
  /// previous `width * 0.05` produced 18.75 on an SE and 21.5 on a Pro Max,
  /// both off-grid and neither matching the 18 or 20 used elsewhere.
  static double gutterOf(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 380) return AppTheme.spaceMd; // 16 — SE, mini
    if (width < 430) return 20.0; // iPhone 13/14/15, most Android
    return AppTheme.spaceLg; // 24 — Plus, Pro Max
  }

  /// Bottom margin the floating nav bar sits in, matching _buildBottomNav.
  static double navBarMargin(BuildContext context) {
    final inset = MediaQuery.viewPaddingOf(context).bottom;
    return inset > _kGestureBarInsetThreshold
        ? inset + AppTheme.spaceSm
        : AppTheme.spaceMd;
  }

  /// Bottom padding a scrolling card list needs so its last card clears the
  /// floating nav bar, plus one grid step of breathing room so the card does
  /// not sit flush against it.
  static double listBottomInset(BuildContext context) =>
      kBottomNavHeight + navBarMargin(context) + AppTheme.spaceMd;

  /// Padding for a scrolling column of cards. [top] varies by screen because
  /// some have a header above them and some do not.
  static EdgeInsets listPadding(BuildContext context, {double top = 0}) {
    final gutter = gutterOf(context);
    return EdgeInsets.fromLTRB(
      gutter,
      top,
      gutter,
      listBottomInset(context),
    );
  }

  /// Gap between two cards in the same list. One value, so a list cannot mix
  /// 14 and 18 the way Mealsense did.
  static const double cardGap = AppTheme.spaceMd; // 16

  /// Gap between groups of cards, one tier up from [cardGap].
  static const double sectionGap = AppTheme.spaceLg; // 24
}
