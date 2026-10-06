// header_card.dart — premium profile header card (Appllama design rewrite).
//
// Appllama principles applied:
//  • One accent locked: primary cyan (#0E7490) for all interactive elements.
//  • Shape lock: card → radiusLg (20dp), badge pill → 999 (fully rounded),
//    avatar → circle.
//  • Spacing rhythm: 4pt grid — xs=4, sm=8, md=16, lg=24.
//  • No AI-default styling: no purple/indigo gradient, no glassmorphism
//    everywhere, no sparkles.
//  • Press state: AnimatedScale 0.97 on the whole card (it's a tap target).
//  • Native feel: real identity data and an explicit edit affordance.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/network_avatar.dart';
import 'package:smartspoon/features/auth/index.dart';

class ProfileHeaderCard extends StatefulWidget {
  const ProfileHeaderCard({super.key, required this.displayName, this.onTap});
  final String displayName;
  final VoidCallback? onTap;

  @override
  State<ProfileHeaderCard> createState() => _ProfileHeaderCardState();
}

class _ProfileHeaderCardState extends State<ProfileHeaderCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return GestureDetector(
      onTapDown: (_) {
        setState(() => _pressed = true);
        HapticFeedback.selectionClick();
      },
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: Consumer<UserProvider>(
          builder: (context, user, child) => _buildCard(context, isDark, user),
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context, bool isDark, UserProvider user) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSurfaceCard : AppTheme.surface,
        borderRadius: BorderRadius.circular(
          AppTheme.radiusLg,
        ), // 20dp — shape lock
        border: Border.all(
          color: isDark ? AppTheme.darkBorder : AppTheme.border,
        ),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: AppTheme.primary.withValues(alpha: 0.08),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                  spreadRadius: -8,
                ),
                BoxShadow(
                  color: AppTheme.cardShadow,
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spaceMd), // md=16
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.primary, width: 2),
              ),
              child: NetworkAvatar(
                radius: 30,
                avatarUrl: user.avatarUrl,
                displayName: user.name,
              ),
            ),

            const SizedBox(width: AppTheme.spaceMd), // 16
            // ── Name + email + badge ──────────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Display name — Large Title hierarchy
                  Text(
                    widget.displayName.isNotEmpty
                        ? widget.displayName
                        : 'Your Name',
                    style: AppTheme.serif(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? AppTheme.darkTextPrimary
                          : AppTheme.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),

                  const SizedBox(height: AppTheme.spaceXs), // 4
                  // Email — Footnote hierarchy
                  if (user.email?.isNotEmpty == true)
                    Text(
                      user.email!,
                      style: GoogleFonts.figtree(
                        fontSize: 12,
                        color: isDark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),

            const SizedBox(width: AppTheme.spaceSm), // 8
            // ── Edit indicator ───────────────────────────────────────────
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.09),
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.18),
                  width: 1,
                ),
              ),
              child: Icon(
                Icons.edit_rounded,
                size: 16,
                color: AppTheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
