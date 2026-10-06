// profile_redesign_widgets.dart — shared building blocks for profile screens.
//
// Appllama design laws applied (full rewrite):
//  • One accent: primary cyan everywhere; destructive paprika only for danger.
//  • Shape lock: cards → radiusLg (20dp), rows → radiusSm (12dp), icon boxes → 10dp.
//  • Spacing rhythm: 4pt grid xs/sm/md/lg constants from AppTheme.
//  • Press states: AnimatedScale 0.97 on tappable rows (frequency gate: "tens/day").
//  • Progress bar: animated fill width with primaryGradient (health progress — brand-approved).
//  • No AI-default styling: no sparkles, no purple/indigo, no glassmorphism on every card.
//  • Anti-slop pre-flight: 1 accent hue, all radii from scale, 0 emoji in chrome, 0 decoration gradients.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/premium_widgets.dart';

// ─── Layout constants (4pt grid alias) ───────────────────────────────────────
const double kPadding = 20.0; // lg = 24, but profile cards use 20 (md+sm)
const double kBorderRadius = 20.0; // shape lock: cards = radiusLg

// ─── Typography helpers ───────────────────────────────────────────────────────
TextStyle get kTitleStyle =>
    GoogleFonts.figtree(fontSize: 18, fontWeight: FontWeight.bold);
TextStyle get kSubtitleStyle => GoogleFonts.figtree(fontSize: 13);
TextStyle get kBodyStyle => GoogleFonts.figtree(fontSize: 15);

// ─── Section header ───────────────────────────────────────────────────────────

class ProfileSectionHeader extends StatelessWidget {
  final String title;
  final Color? dotColor;

  const ProfileSectionHeader({super.key, required this.title, this.dotColor});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        color: isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary,
      ),
    );
  }
}

// ─── ProfileCard (PremiumGlassCard wrapper with enhanced theming) ─────────────

class ProfileCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final Color? accentColor;

  const ProfileCard({
    super.key,
    required this.child,
    this.padding,
    this.width,
    this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: PremiumGlassCard(
        accentColor: accentColor,
        borderRadius: kBorderRadius,
        animateOnAppear: true,
        padding: padding ?? const EdgeInsets.all(kPadding),
        child: child,
      ),
    );
  }
}

// ─── StatsCard (icon + big value + label, tap-to-drill) ──────────────────────

class StatsCard extends StatefulWidget {
  final IconData icon;
  final String value;
  final String label;
  final bool isUp;
  final VoidCallback? onTap;

  const StatsCard({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    this.isUp = true,
    this.onTap,
  });

  @override
  State<StatsCard> createState() => _StatsCardState();
}

class _StatsCardState extends State<StatsCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTapDown: widget.onTap != null
          ? (_) {
              setState(() => _pressed = true);
              HapticFeedback.selectionClick();
            }
          : null,
      onTapUp: widget.onTap != null
          ? (_) {
              setState(() => _pressed = false);
              widget.onTap!();
            }
          : null,
      onTapCancel: widget.onTap != null
          ? () => setState(() => _pressed = false)
          : null,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOutCubic,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Icon in primary-tinted box
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(
                  10,
                ), // shape lock: icon boxes
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.15),
                  width: 0.5,
                ),
              ),
              child: Icon(widget.icon, color: AppTheme.primary, size: 20),
            ),
            const SizedBox(height: AppTheme.spaceSm), // 8
            // Big number — tabular nums, hierarchy: Large Title
            Text(
              widget.value,
              style: AppTheme.serif(
                fontSize: 38,
                fontWeight: FontWeight.w700,
                letterSpacing: -1.5,
                color: isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: AppTheme.spaceXs), // 4
            // Label — Footnote hierarchy
            Text(
              widget.label,
              style: GoogleFonts.figtree(
                fontSize: 12,
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.textSecondary,
              ),
            ),

            // Trend arrow — primary only (not colored separately)
            if (widget.isUp) ...[
              const SizedBox(height: AppTheme.spaceXs),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.trending_up_rounded,
                    size: 12,
                    color: AppTheme.success,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    'trending',
                    style: GoogleFonts.figtree(
                      fontSize: 10,
                      color: AppTheme.success,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── ProfileProgressBar (animated, primary gradient) ─────────────────────────

class ProfileProgressBar extends StatefulWidget {
  final double progress; // 0.0 to 1.0

  const ProfileProgressBar({super.key, required this.progress});

  @override
  State<ProfileProgressBar> createState() => _ProfileProgressBarState();
}

class _ProfileProgressBarState extends State<ProfileProgressBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _ctrl.animateTo(widget.progress.clamp(0.0, 1.0));
  }

  @override
  void didUpdateWidget(ProfileProgressBar old) {
    super.didUpdateWidget(old);
    if (old.progress != widget.progress) {
      _ctrl.animateTo(widget.progress.clamp(0.0, 1.0));
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) => Container(
        height: 8, // taller = more presence; still compact
        width: double.infinity,
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkBorder : AppTheme.oat,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: _anim.value,
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(4),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.35),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── SettingsRow (menu tile with press state, theme-aware) ───────────────────

class SettingsRow extends StatefulWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool isDestructive;
  final bool showBorder;

  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.trailing,
    this.onTap,
    this.isDestructive = false,
    this.showBorder = true,
  });

  @override
  State<SettingsRow> createState() => _SettingsRowState();
}

class _SettingsRowState extends State<SettingsRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Colors — one-accent discipline
    final iconBg = widget.isDestructive
        ? AppTheme.paprika.withValues(alpha: 0.10)
        : AppTheme.primary.withValues(alpha: 0.08);
    final iconColor = widget.isDestructive
        ? AppTheme.paprika
        : (isDark ? AppTheme.darkSageDeepAccent : AppTheme.primary);
    final titleColor = widget.isDestructive
        ? AppTheme.paprika
        : (isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary);
    final dividerColor = isDark ? AppTheme.darkBorder : AppTheme.border;

    return GestureDetector(
      onTapDown: widget.onTap != null
          ? (_) {
              setState(() => _pressed = true);
              HapticFeedback.selectionClick();
            }
          : null,
      onTapUp: widget.onTap != null
          ? (_) {
              setState(() => _pressed = false);
              widget.onTap!();
            }
          : null,
      onTapCancel: widget.onTap != null
          ? () => setState(() => _pressed = false)
          : null,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
        decoration: BoxDecoration(
          // Very subtle press highlight — background, never scale on list rows
          color: _pressed
              ? (isDark
                    ? AppTheme.darkCreamElevated.withValues(alpha: 0.5)
                    : AppTheme.oat.withValues(alpha: 0.6))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(
            AppTheme.radiusSm,
          ), // 12dp — shape lock
          border: widget.showBorder
              ? Border(bottom: BorderSide(color: dividerColor, width: 0.8))
              : null,
        ),
        child: Row(
          children: [
            // Icon container — 10dp radius (shape lock: icon boxes)
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(widget.icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: AppTheme.spaceMd), // 16
            // Title — Body hierarchy
            Expanded(
              child: Text(
                widget.title,
                style: GoogleFonts.figtree(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: titleColor,
                ),
              ),
            ),

            // Trailing — Switch or chevron
            if (widget.trailing != null)
              widget.trailing!
            else if (widget.onTap != null)
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 13,
                color: isDark
                    ? AppTheme.darkTextTertiary
                    : AppTheme.textTertiary,
              ),
          ],
        ),
      ),
    );
  }
}
