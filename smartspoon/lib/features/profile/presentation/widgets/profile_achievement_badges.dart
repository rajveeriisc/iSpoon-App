// profile_achievement_badges.dart — horizontal scrollable achievement badges strip.
//
// Shows milestone badges (locked / unlocked) based on UnifiedDataService stats.
// Applies Appllama design laws: one accent color (primary cyan), shape lock
// (circular badges, 10dp icon boxes), 4pt spacing grid, and no emoji in chrome.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/features/insights/domain/services/unified_data_service.dart';

// ─── Data model ─────────────────────────────────────────────────────────────

class _Badge {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final bool Function(UnifiedDataService d) isUnlocked;

  const _Badge({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.isUnlocked,
  });
}

const _badges = [
  _Badge(
    icon: Icons.local_dining_rounded,
    title: 'First Meal',
    subtitle: 'Logged your first meal',
    color: AppTheme.primary,
    isUnlocked: _hasAnyBites,
  ),
  _Badge(
    icon: Icons.local_fire_department_rounded,
    title: '7-Day Streak',
    subtitle: 'Active 7 days in a row',
    color: Color(0xFFE88A1A),
    isUnlocked: _streak7,
  ),
  _Badge(
    icon: Icons.track_changes_rounded,
    title: 'Goal Crusher',
    subtitle: 'Hit 100% daily target',
    color: AppTheme.accentGreen,
    isUnlocked: _hitGoal,
  ),
  _Badge(
    icon: Icons.star_rounded,
    title: 'Mindful Eater',
    subtitle: '30-day streak',
    color: Color(0xFF7B5CF0),
    isUnlocked: _streak30,
  ),
  _Badge(
    icon: Icons.emoji_events_rounded,
    title: 'Champion',
    subtitle: 'All goals complete',
    color: Color(0xFFC97824),
    isUnlocked: _champion,
  ),
];

bool _hasAnyBites(UnifiedDataService d) => d.totalBites > 0;
bool _streak7(UnifiedDataService d) => d.currentStreak >= 7;
bool _hitGoal(UnifiedDataService d) =>
    d.dailyBiteGoal > 0 && d.totalBites >= d.dailyBiteGoal;
bool _streak30(UnifiedDataService d) => d.currentStreak >= 30;
bool _champion(UnifiedDataService d) =>
    _streak7(d) && _hitGoal(d) && d.currentStreak >= 14;

// ─── Widget ──────────────────────────────────────────────────────────────────

class ProfileAchievementBadges extends StatelessWidget {
  const ProfileAchievementBadges({super.key});

  @override
  Widget build(BuildContext context) {
    final d = context.watch<UnifiedDataService>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      height: 108,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 0),
        clipBehavior: Clip.none,
        itemCount: _badges.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final badge = _badges[i];
          final unlocked = badge.isUnlocked(d);
          return _BadgeTile(
            badge: badge,
            unlocked: unlocked,
            isDark: isDark,
          );
        },
      ),
    );
  }
}

class _BadgeTile extends StatefulWidget {
  final _Badge badge;
  final bool unlocked;
  final bool isDark;

  const _BadgeTile({
    required this.badge,
    required this.unlocked,
    required this.isDark,
  });

  @override
  State<_BadgeTile> createState() => _BadgeTileState();
}

class _BadgeTileState extends State<_BadgeTile>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  late final AnimationController _shimmer;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.unlocked) _shimmer.repeat(reverse: true);
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.unlocked
        ? widget.badge.color
        : (widget.isDark ? AppTheme.darkBorder : AppTheme.border);

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOutCubic,
        child: SizedBox(
          width: 80,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Badge circle
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.isDark
                      ? AppTheme.darkSurface
                      : AppTheme.surface,
                  border: Border.all(
                    color: widget.unlocked
                        ? color.withValues(alpha: 0.6)
                        : (widget.isDark
                            ? AppTheme.darkBorder
                            : AppTheme.border),
                    width: widget.unlocked ? 2 : 1,
                  ),
                  boxShadow: widget.unlocked && !widget.isDark
                      ? [
                          BoxShadow(
                            color: color.withValues(alpha: 0.18),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : null,
                ),
                child: widget.unlocked
                    ? Icon(widget.badge.icon, color: color, size: 28)
                    : Icon(
                        Icons.lock_outline_rounded,
                        color: widget.isDark
                            ? AppTheme.darkTextTertiary
                            : AppTheme.textTertiary,
                        size: 22,
                      ),
              ),
              const SizedBox(height: 8),
              // Badge label
              Text(
                widget.badge.title,
                style: GoogleFonts.figtree(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: widget.unlocked
                      ? (widget.isDark
                          ? AppTheme.darkTextPrimary
                          : AppTheme.textPrimary)
                      : (widget.isDark
                          ? AppTheme.darkTextTertiary
                          : AppTheme.textTertiary),
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
