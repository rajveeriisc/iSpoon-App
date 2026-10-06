// ai_lab_card.dart — shared building blocks for the AI Lab cards.
import 'package:flutter/material.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';

const Color kSteadyGreen = Color(0xFF16A34A);
const Color kShakeAmber = Color(0xFFF59E0B);
const Color kShakeRed = Color(0xFFDC2626);

Color steadinessColor(double pct) => pct >= kSteadyFromPct
    ? kSteadyGreen
    : pct >= kShakyBelowPct
        ? kShakeAmber
        : kShakeRed;

String steadinessLabel(double pct) => pct >= kSteadyFromPct
    ? 'Steady'
    : pct >= kShakyBelowPct
        ? 'Mostly steady'
        : 'Frequent rhythmic shaking';

/// Dot colour for one bite from the share of rhythmic windows around it.
Color biteColor(double rhythmicShare) => rhythmicShare == 0
    ? kSteadyGreen
    : rhythmicShare <= 0.34
        ? kShakeAmber
        : kShakeRed;

String mmss(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

String gapText(double? s) => s == null ? '—' : secs(s);

Color mutedText(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);

class AiLabCard extends StatelessWidget {
  const AiLabCard({
    super.key,
    required this.child,
    this.title,
    this.icon,
    this.trailing,
    this.padding = const EdgeInsets.all(18),
  });

  final Widget child;
  final String? title;
  final IconData? icon;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: dark ? AppTheme.darkSurface : AppTheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: dark ? AppTheme.darkBorder : AppTheme.line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.18 : 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Row(children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(title!,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
              ?trailing,
            ]),
            const SizedBox(height: 12),
          ],
          child,
        ],
      ),
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.value, required this.label, this.color});

  final String value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value,
              style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: color ?? theme.colorScheme.onSurface)),
        ),
        const SizedBox(height: 2),
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: mutedText(context), fontSize: 11)),
      ],
    );
  }
}
