// profile_quick_actions.dart — 4-pill quick-action row under profile header.
//
// Applies Appllama design laws: pill shape (shape-lock), one accent (primary
// cyan), 4pt grid spacing, press states (scale 0.95 + haptic), and semantic
// icons (Material icons, no emoji in chrome).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartspoon/core/theme/app_theme.dart';

class ProfileQuickActions extends StatelessWidget {
  final VoidCallback onEditProfile;
  final VoidCallback onGoals;
  final VoidCallback onDevices;
  final VoidCallback onShare;

  const ProfileQuickActions({
    super.key,
    required this.onEditProfile,
    required this.onGoals,
    required this.onDevices,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ActionPill(
            icon: Icons.edit_rounded,
            label: 'Edit',
            onTap: onEditProfile,
            isPrimary: true,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ActionPill(
            icon: Icons.track_changes_rounded,
            label: 'Goals',
            onTap: onGoals,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ActionPill(
            icon: Icons.bluetooth_rounded,
            label: 'Devices',
            onTap: onDevices,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ActionPill(
            icon: Icons.ios_share_rounded,
            label: 'Share',
            onTap: onShare,
          ),
        ),
      ],
    );
  }
}

class _ActionPill extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isPrimary;

  const _ActionPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isPrimary = false,
  });

  @override
  State<_ActionPill> createState() => _ActionPillState();
}

class _ActionPillState extends State<_ActionPill> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Primary pill: filled with primary color. Others: outlined.
    final bgColor = widget.isPrimary
        ? AppTheme.primary
        : (isDark ? AppTheme.darkSurface : AppTheme.surface);

    final borderColor = widget.isPrimary
        ? Colors.transparent
        : (isDark ? AppTheme.darkBorder : AppTheme.border);

    final iconColor = widget.isPrimary
        ? Colors.white
        : (isDark ? AppTheme.darkTextSecondary : AppTheme.primary);

    final textColor = widget.isPrimary
        ? Colors.white
        : (isDark ? AppTheme.darkTextSecondary : AppTheme.textSecondary);

    return GestureDetector(
      onTapDown: (_) {
        setState(() => _pressed = true);
        HapticFeedback.lightImpact();
      },
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: _pressed
                ? (widget.isPrimary
                    ? AppTheme.primary.withValues(alpha: 0.88)
                    : (isDark
                        ? AppTheme.darkCreamElevated
                        : AppTheme.oat))
                : bgColor,
            borderRadius: BorderRadius.circular(999), // pill — shape lock
            border: Border.all(color: borderColor, width: 1),
            boxShadow: widget.isPrimary && !isDark
                ? [
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 0.25),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 20, color: iconColor),
              const SizedBox(height: 4),
              Text(
                widget.label,
                style: GoogleFonts.figtree(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
