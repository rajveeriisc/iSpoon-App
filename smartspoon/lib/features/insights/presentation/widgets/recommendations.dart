// recommendations.dart — renders what SuggestionEngine derived, and only that.
//
// This widget used to take TrendData, ignore it, and print two fixed
// sentences ("Great progress! Tremor decreased this week." and an eating-speed
// tip) whatever the person had done. It now renders a List<Suggestion> and
// has no sentences of its own, so there is nothing here that can be true for
// one person and false for another.
//
// Each row shows the measurement it came from. That is deliberate: a claim
// about someone's eating is only worth reading if they can check it, and it
// keeps the engine honest — a rule that cannot state its own evidence cannot
// reach the screen.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/card_layout.dart';

import '../../domain/suggestion_engine.dart';

class Recommendations extends StatelessWidget {
  const Recommendations({super.key, required this.suggestions, this.margin});

  final List<Suggestion> suggestions;

  /// Null means the standalone 5%-of-width inset. Callers that already sit
  /// inside a padded column pass EdgeInsets.zero — the inset used to be
  /// baked in, which is why this card could only ever live at the top level.
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // No suggestions is a real answer, not a layout to fill. An empty card
    // with a heading over nothing reads as a bug, so draw nothing at all.
    if (suggestions.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: margin ??
          EdgeInsets.symmetric(horizontal: CardLayout.gutterOf(context)),
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
            'From your meals',
            style: GoogleFonts.figtree(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          for (final s in suggestions) SuggestionRow(suggestion: s),
        ],
      ),
    );
  }
}

/// One suggestion: its kind as a leading interface icon, then title, body and
/// the measurement behind it.
///
/// Icons rather than glyphs typed into the string — a text glyph takes the
/// text font, so it varies by platform, ignores icon colour and size, and
/// reads as an emoji dropped into the interface rather than part of it.
class SuggestionRow extends StatelessWidget {
  const SuggestionRow({super.key, required this.suggestion});

  final Suggestion suggestion;

  /// Kind, not individual suggestion: a new rule in the engine must not need
  /// a matching case here, or the two drift apart and the UI silently decides
  /// what a suggestion means.
  static IconData iconFor(SuggestionKind kind) => switch (kind) {
        SuggestionKind.praise => Icons.check_circle_outline_rounded,
        SuggestionKind.nudge => Icons.adjust_rounded,
        SuggestionKind.observation => Icons.insights_rounded,
        SuggestionKind.learning => Icons.hourglass_empty_rounded,
      };

  /// The icon carries the distinction, not the colour. AppTheme deliberately
  /// resolves its decorative accents (honey, sageDeep, emerald) to one brand
  /// colour, so tinting four kinds four ways would produce four identical
  /// icons and a false promise that colour means something here. Only
  /// [AppTheme.success] is semantic, and only praise earns it.
  static Color colorFor(SuggestionKind kind) =>
      kind == SuggestionKind.praise ? AppTheme.success : AppTheme.primary;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final accent = colorFor(suggestion.kind);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 10),
            child: Icon(iconFor(suggestion.kind), size: 18, color: accent),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  suggestion.title,
                  style: GoogleFonts.figtree(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  suggestion.body,
                  style: GoogleFonts.figtree(
                    fontSize: 13,
                    height: 1.4,
                    color: onSurface.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  suggestion.evidence,
                  style: GoogleFonts.figtree(
                    fontSize: 11,
                    color: onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
