// profile_page.dart — focused account, goals, preferences, and support.
import 'package:flutter/material.dart';
import 'package:smartspoon/core/widgets/bowl_spoon_icon.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:smartspoon/core/providers/theme_provider.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/features/auth/index.dart';
import 'package:smartspoon/features/devices/presentation/screens/add_device_screen.dart';
import 'package:smartspoon/features/insights/domain/services/unified_data_service.dart';
import 'package:smartspoon/features/notifications/application/notification_provider.dart';
import 'package:smartspoon/features/profile/presentation/screens/daily_bites_screen.dart';
import 'package:smartspoon/features/profile/presentation/screens/edit_profile_screen.dart';
import 'package:smartspoon/features/profile/presentation/screens/help_center_page.dart';
import 'package:smartspoon/features/profile/presentation/screens/privacy_policy_page.dart';
import 'package:smartspoon/features/profile/presentation/screens/privacy_settings_page.dart';
import 'package:smartspoon/features/profile/presentation/screens/terms_page.dart';
import 'package:smartspoon/features/profile/presentation/widgets/change_password_dialog.dart';
import 'package:smartspoon/features/profile/presentation/widgets/delete_account_dialog.dart';
import 'package:smartspoon/features/profile/presentation/widgets/feedback_modals.dart';
import 'package:smartspoon/features/profile/presentation/widgets/header_card.dart';
import 'package:smartspoon/features/profile/presentation/widgets/profile_redesign_widgets.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  void _openEditProfile(BuildContext context) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const EditProfileScreen(),
    );
  }

  void _openGoals(BuildContext context) => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const DailyBitesScreen()),
  );

  void _openDevices(BuildContext context) => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const AddDeviceScreen()),
  );

  Future<void> _logOut(BuildContext context) async {
    try {
      await AuthService.logout(clearUserData: true);
    } catch (_) {}
    try {
      await FirebaseAuthService().signOut();
    } catch (_) {}
    if (!context.mounted) return;
    context.read<UserProvider>().clear();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = context.watch<UnifiedDataService>();
    final user = context.watch<UserProvider>();
    final safeGoal = data.dailyBiteGoal > 0 ? data.dailyBiteGoal : 1;
    final progress = (data.totalBites / safeGoal).clamp(0.0, 1.0);
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceMd,
            AppTheme.spaceMd,
            AppTheme.spaceMd,
            112,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ProfileHeaderCard(
                displayName: user.name ?? 'Your Name',
                onTap: () => _openEditProfile(context),
              ),
              const SizedBox(height: AppTheme.spaceLg),
              const ProfileSectionHeader(title: 'Today'),
              const SizedBox(height: AppTheme.spaceSm),
              ProfileCard(
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _ProfileMetric(
                            label: 'Bites',
                            value: '${data.totalBites}',
                            icon: const BowlSpoonIcon(),
                          ),
                        ),
                        _MetricDivider(color: colors.outlineVariant),
                        Expanded(
                          child: _ProfileMetric(
                            label: 'Target',
                            value: '${data.dailyBiteGoal}',
                            icon: const Icon(Icons.track_changes_rounded),
                            onTap: () => _openGoals(context),
                          ),
                        ),
                        _MetricDivider(color: colors.outlineVariant),
                        Expanded(
                          child: _ProfileMetric(
                            label: 'Streak',
                            value: '${data.currentStreak}',
                            icon: const Icon(Icons.calendar_today_rounded),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppTheme.spaceMd),
                    ProfileProgressBar(progress: progress),
                    const SizedBox(height: AppTheme.spaceSm),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${(progress * 100).round()}% of today’s bite goal',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        TextButton(
                          onPressed: () => _openGoals(context),
                          child: const Text('Adjust goal'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppTheme.spaceLg),
              const ProfileSectionHeader(title: 'Preferences'),
              const SizedBox(height: AppTheme.spaceSm),
              ProfileCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.spaceMd,
                  vertical: AppTheme.spaceXs,
                ),
                child: Column(
                  children: [
                    SettingsRow(
                      icon: Icons.track_changes_rounded,
                      title: 'Daily bite goal',
                      onTap: () => _openGoals(context),
                    ),
                    SettingsRow(
                      icon: Icons.bluetooth_rounded,
                      title: 'My spoon',
                      onTap: () => _openDevices(context),
                    ),
                    Consumer<ThemeProvider>(
                      builder: (context, theme, _) => SettingsRow(
                        icon: Icons.dark_mode_outlined,
                        title: 'Dark mode',
                        trailing: Switch.adaptive(
                          value: theme.themeMode == ThemeMode.dark,
                          onChanged: (_) => theme.toggleTheme(),
                        ),
                      ),
                    ),
                    Consumer<NotificationProvider>(
                      builder: (context, notifications, _) {
                        bool enabled = user.notificationsEnabled ?? true;
                        bool isLoading = false;
                        try {
                          enabled =
                              notifications.preferences?.enabled ??
                              user.notificationsEnabled ??
                              true;
                          isLoading = notifications.loading;
                        } catch (_) {}

                        return SettingsRow(
                          icon: Icons.notifications_outlined,
                          title: 'Notifications',
                          trailing: isLoading
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Switch.adaptive(
                                  value: enabled,
                                  onChanged: (value) async {
                                    try {
                                      await notifications.toggleAllNotifications(
                                        value,
                                      );
                                    } catch (_) {}
                                    if (context.mounted) {
                                      context
                                              .read<UserProvider>()
                                              .notificationsEnabled =
                                          value;
                                    }
                                  },
                                ),
                        );
                      },
                    ),
                    SettingsRow(
                      icon: Icons.shield_outlined,
                      title: 'Privacy & security',
                      showBorder: false,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const PrivacySettingsPage(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppTheme.spaceLg),
              const ProfileSectionHeader(title: 'Support'),
              const SizedBox(height: AppTheme.spaceSm),
              ProfileCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.spaceMd,
                  vertical: AppTheme.spaceXs,
                ),
                child: Column(
                  children: [
                    SettingsRow(
                      icon: Icons.help_outline_rounded,
                      title: 'Help center',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const HelpCenterPage(),
                        ),
                      ),
                    ),
                    SettingsRow(
                      icon: Icons.chat_bubble_outline_rounded,
                      title: 'Send feedback',
                      showBorder: false,
                      onTap: () => FeedbackModals.showFeedbackModal(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppTheme.spaceLg),
              const ProfileSectionHeader(title: 'Legal'),
              const SizedBox(height: AppTheme.spaceSm),
              ProfileCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.spaceMd,
                  vertical: AppTheme.spaceXs,
                ),
                child: Column(
                  children: [
                    SettingsRow(
                      icon: Icons.privacy_tip_outlined,
                      title: 'Privacy policy',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const PrivacyPolicyPage(),
                        ),
                      ),
                    ),
                    SettingsRow(
                      icon: Icons.description_outlined,
                      title: 'Terms of service',
                      showBorder: false,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const TermsPage()),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppTheme.spaceLg),
              const ProfileSectionHeader(title: 'Account'),
              const SizedBox(height: AppTheme.spaceSm),
              ProfileCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.spaceMd,
                  vertical: AppTheme.spaceXs,
                ),
                child: Column(
                  children: [
                    if (FirebaseAuthService().hasPasswordProvider)
                      SettingsRow(
                        icon: Icons.lock_outline_rounded,
                        title: 'Change password',
                        onTap: () => ChangePasswordDialog.show(context),
                      ),
                    SettingsRow(
                      icon: Icons.logout_rounded,
                      title: 'Log out',
                      onTap: () => _logOut(context),
                    ),
                    SettingsRow(
                      icon: Icons.no_accounts_outlined,
                      title: 'Delete account',
                      isDestructive: true,
                      showBorder: false,
                      onTap: () => DeleteAccountDialog.show(
                        context,
                        onDeleted: () {
                          if (!context.mounted) return;
                          context.read<UserProvider>().clear();
                          Navigator.of(context).pushAndRemoveUntil(
                            MaterialPageRoute(
                              builder: (_) => const LoginScreen(),
                            ),
                            (route) => false,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppTheme.spaceLg),
              Center(
                child: Text(
                  'SmartSpoon  •  Version 1.0.0',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileMetric extends StatelessWidget {
  const _ProfileMetric({
    required this.label,
    required this.value,
    required this.icon,
    this.onTap,
  });

  final String label;
  final String value;
  final Widget icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTheme.spaceSm),
        child: Column(
          children: [
            IconTheme(
              data: IconThemeData(
                  size: 20, color: Theme.of(context).colorScheme.primary),
              child: icon,
            ),
            const SizedBox(height: AppTheme.spaceSm),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: AppTheme.spaceXs),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _MetricDivider extends StatelessWidget {
  const _MetricDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 64, color: color);
}
