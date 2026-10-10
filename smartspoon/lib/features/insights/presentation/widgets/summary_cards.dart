// summary_cards.dart — top-of-dashboard headline stat cards.
//
// SummaryCards renders the primary at-a-glance tiles (total bites, eating pace),
// with optional tap callbacks to drill into detail pages. Presentational only —
// values are passed in by the dashboard.
import 'package:flutter/material.dart';
import 'package:smartspoon/core/widgets/bowl_spoon_icon.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartspoon/core/theme/app_theme.dart';

class SummaryCards extends StatelessWidget {
  const SummaryCards({
    super.key,
    required this.totalBites,
    required this.paceBpm,
    this.onTotalBitesTap,
    this.onPaceTap,
  });

  final int totalBites;
  final double paceBpm;
  final VoidCallback? onTotalBitesTap;
  final VoidCallback? onPaceTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Summary cards: total bites, eating pace',
      // Sized to its own content rather than a fixed 152.
      //
      // Measured content height against the old hard-coded 152:
      //
      //   text scale 1.0 -> 146 px   (fits, 6 px spare)
      //   text scale 1.3 -> 164 px   (overflowed by 12)
      //   text scale 1.6 -> 183 px   (overflowed by 31)
      //
      // main.dart clamps accessibility text to 1.6x, so every user above the
      // default size was clipping. iOS shows it first: Dynamic Type is
      // changed far more often there, and an iPhone SE/mini is 375 dp wide
      // against 390 on a 14 and more on most Android phones.
      //
      // The "// Reduced from 28" and "// Prevent overflow" comments below are
      // the scars of that — the type was shrunk to fit a box that was the
      // wrong size to begin with, which is why it also read as mismatched.
      //
      // IntrinsicHeight makes both cards as tall as the taller one's content,
      // so they stay matched at any text size, on any screen width.
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _SummaryCard(
                title: 'Total Bites',
                value: totalBites.toString(),
                icon: const BowlSpoonIcon(),
                color: AppTheme.primary,
                onTap: onTotalBitesTap,
              ),
            ),
            const SizedBox(width: AppTheme.spaceSm),
            Expanded(
              child: _SummaryCard(
                title: 'Eating Pace',
                value: paceBpm.toStringAsFixed(1),
                unit: 'bites/min',
                icon: const Icon(Icons.speed_rounded),
                color: AppTheme.primary,
                onTap: onPaceTap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.title,
    required this.value,
    this.unit,
    required this.icon,
    required this.color,
    this.onTap,
  });

  final String title;
  final String value;
  final String? unit;
  final Widget icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      child: Container(
        padding: const EdgeInsets.all(AppTheme.spaceMd),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkSurface : AppTheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          border: Border.all(
            color: isDark ? AppTheme.darkBorder : AppTheme.border,
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: isDark ? Colors.transparent : AppTheme.cardShadow,
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          // spaceBetween keeps the icon at the top and the figures at the
          // bottom, as before. mainAxisSize.min is gone: under IntrinsicHeight
          // the column is given the card's height, and asking it to shrink at
          // the same time is contradictory.
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(8), // Reduced from 10
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  // IconTheme rather than Icon(): the glyph may be a
                  // painted BowlSpoonIcon, and both it and Icon take their
                  // size and colour from here.
                  child: IconTheme(
                    data: IconThemeData(color: color, size: 20),
                    child: icon,
                  ),
                ),
                if (onTap != null)
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 14,
                    color: Theme.of(context).colorScheme.onSurface.withValues(
                      alpha: isDark ? 0.35 : 0.3,
                    ),
                  ),
              ],
            ),
            // Was a Spacer(). Spacer is an Expanded, and Expanded under
            // IntrinsicHeight asserts, because intrinsic measurement needs an
            // unbounded child height. spaceBetween already does the job.
            const SizedBox(height: AppTheme.spaceSm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: GoogleFonts.figtree(
                    fontSize: 24, // Reduced from 28
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                    height: 1.1,
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    unit!,
                    style: GoogleFonts.figtree(
                      fontSize: 12, // Reduced from 13
                      fontWeight: FontWeight.w500,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: GoogleFonts.figtree(
                fontSize: 13, // Reduced from 14
                fontWeight: FontWeight.w500,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
