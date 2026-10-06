// summary_cards.dart — top-of-dashboard headline stat cards.
//
// SummaryCards renders the primary at-a-glance tiles (total bites, eating pace),
// with optional tap callbacks to drill into detail pages. Presentational only —
// values are passed in by the dashboard.
import 'package:flutter/material.dart';
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
      child: SizedBox(
        height: 152,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _SummaryCard(
                title: 'Total Bites',
                value: totalBites.toString(),
                icon: Icons.restaurant_menu_rounded,
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
                icon: Icons.speed_rounded,
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
  final IconData icon;
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
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          mainAxisSize: MainAxisSize.min, // Prevent overflow
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
                  child: Icon(icon, color: color, size: 20), // Reduced from 22
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
            const Spacer(),
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
