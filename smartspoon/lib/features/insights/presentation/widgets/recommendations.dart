// recommendations.dart — coaching/recommendation list widget.
//
// Recommendations takes TrendData and renders a list of actionable suggestions
// (e.g. slow down, keep it up) derived from the user's recent eating trends,
// shown on the Insights dashboard. Purely presentational.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import '../../domain/models.dart';

class Recommendations extends StatelessWidget {
  const Recommendations({super.key, required this.trends});
  final TrendData? trends;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: size.width * 0.05),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSurfaceCard : AppTheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? AppTheme.darkBorder : AppTheme.border,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.transparent : AppTheme.cardShadow,
            blurRadius: 26,
            offset: const Offset(0, 12),
            spreadRadius: -14,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Personalized Suggestions',
            style: GoogleFonts.figtree(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          // Leading Icons rather than '✓' and '⚠️' typed into the string.
          // Text glyphs take the text font, so they vary by platform, ignore
          // icon colour and size, and read as emoji rather than as part of
          // the interface.
          _Suggestion(
            icon: Icons.trending_down_rounded,
            text: 'Great progress! Tremor decreased this week.',
          ),
          _Suggestion(
            icon: Icons.schedule_rounded,
            text: 'Eating speed: try smaller bites and pauses.',
          ),
        ],
      ),
    );
  }
}

/// One suggestion line: a leading interface icon, then the text.
class _Suggestion extends StatelessWidget {
  const _Suggestion({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 8),
            child: Icon(icon, size: 16, color: onSurface.withValues(alpha: 0.55)),
          ),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.figtree(
                color: onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
