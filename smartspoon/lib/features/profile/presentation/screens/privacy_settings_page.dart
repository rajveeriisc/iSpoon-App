// privacy_settings_page.dart — privacy & background-monitoring controls.
//
// Lets the user toggle background BLE monitoring (start/stop
// SmartSpoonBleService), manage notification preferences, and control
// data/sync-related privacy options. Persists choices to SharedPreferences and
// coordinates with the sync service.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/geometric_background.dart';
import 'package:smartspoon/features/devices/domain/services/smart_spoon_ble_service.dart';
import 'package:smartspoon/features/notifications/application/notification_provider.dart';
import 'package:smartspoon/core/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PrivacySettingsPage extends StatefulWidget {
  const PrivacySettingsPage({super.key});

  @override
  State<PrivacySettingsPage> createState() => _PrivacySettingsPageState();
}

class _PrivacySettingsPageState extends State<PrivacySettingsPage> {
  // Data Collection — gates InsightsDashboard's personalized AI insight
  // cards (see insights_dashboard.dart's _personalizedRecsEnabled). This is
  // the only toggle in this section with a real system behind it; a
  // "Share Usage Analytics" toggle was removed because this app has no
  // analytics/telemetry SDK anywhere for it to control.
  bool _personalizedRecs = true;

  // Background Tracking
  bool _backgroundTracking = false;

  // Restore my data
  bool _isRestoring = false;

  @override
  void initState() {
    super.initState();
    _loadAllSettings();
  }

  Future<void> _loadAllSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _personalizedRecs = prefs.getBool('privacy_personalized_recs') ?? true;
      _backgroundTracking =
          prefs.getBool('background_tracking_enabled') ?? false;
    });
  }

  Future<void> _toggleBackgroundTracking(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('background_tracking_enabled', value);
    setState(() {
      _backgroundTracking = value;
    });

    if (value) {
      await SmartSpoonBleService().startBackgroundMonitoring();
    } else {
      await SmartSpoonBleService().stopBackgroundMonitoring();
    }
  }

  /// Manually force a re-pull of meal/bite history from the backend.
  /// Useful if a user suspects their local history is missing data
  /// (e.g. they restored from a backup or auto-restore failed silently).
  Future<void> _restoreMyData() async {
    if (_isRestoring) return;
    setState(() => _isRestoring = true);

    try {
      final result = await SyncService().restoreFromCloud();
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.userMessage,
            style: GoogleFonts.figtree(color: Colors.white),
          ),
          backgroundColor: result.isFailure
              ? Colors.redAccent
              : AppTheme.sageDeep,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
    } finally {
      if (mounted) setState(() => _isRestoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: Theme.of(context).brightness == Brightness.dark
                  ? AppTheme.darkBackgroundGradient
                  : AppTheme.backgroundGradient,
            ),
          ),
          const GeometricBackground(),
          SafeArea(
            child: Column(
              children: [
                _buildAppBar(context),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSectionHeader('DATA COLLECTION'),
                        const SizedBox(height: 12),
                        _buildSettingsCard([
                          _buildToggleRow(
                            icon: Icons.recommend_outlined,
                            title: 'Personalized Recommendations',
                            subtitle: 'Get tailored meal and health tips',
                            value: _personalizedRecs,
                            onChanged: (v) =>
                                setState(() => _personalizedRecs = v),
                          ),
                        ]),

                        const SizedBox(height: 24),
                        _buildSectionHeader('NOTIFICATIONS'),
                        const SizedBox(height: 12),
                        _buildSettingsCard([
                          Consumer<NotificationProvider>(
                            builder: (context, notifProvider, _) {
                              final isEnabled =
                                  notifProvider.preferences?.enabled ?? true;
                              return _buildToggleRow(
                                icon: Icons.notifications_outlined,
                                title: 'Push Notifications',
                                subtitle: 'Get real-time alerts on your device',
                                value: isEnabled,
                                onChanged: (v) async {
                                  await notifProvider.toggleAllNotifications(v);
                                },
                              );
                            },
                          ),
                        ]),

                        const SizedBox(height: 24),
                        _buildSectionHeader('DEVICE TRACKING'),
                        const SizedBox(height: 12),
                        _buildSettingsCard([
                          _buildToggleRow(
                            icon: Icons.bluetooth_connected_rounded,
                            title: '24/7 Background Tracking',
                            subtitle:
                                'Allow i-Spoon to track data while closed',
                            value: _backgroundTracking,
                            onChanged: _toggleBackgroundTracking,
                          ),
                        ]),

                        const SizedBox(height: 24),
                        _buildSectionHeader('ACCOUNT SECURITY'),
                        const SizedBox(height: 12),
                        _buildSettingsCard([
                          _buildActionRow(
                            icon: Icons.cloud_download_outlined,
                            title: 'Restore My Data',
                            subtitle:
                                'Re-sync your meal & bite history from the cloud',
                            loading: _isRestoring,
                            onTap: _restoreMyData,
                          ),
                        ]),

                        const SizedBox(height: 32),

                        // Save button
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              gradient: AppTheme.primaryGradient,
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.caramel.withValues(
                                    alpha: 0.3,
                                  ),
                                  blurRadius: 12,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: () async {
                                  final prefs =
                                      await SharedPreferences.getInstance();
                                  await prefs.setBool(
                                    'privacy_personalized_recs',
                                    _personalizedRecs,
                                  );
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Privacy settings saved',
                                        style: GoogleFonts.figtree(
                                          color: Colors.white,
                                        ),
                                      ),
                                      backgroundColor: AppTheme.sageDeep,
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      margin: const EdgeInsets.all(16),
                                    ),
                                  );
                                },
                                child: Center(
                                  child: Text(
                                    'Save Settings',
                                    style: GoogleFonts.figtree(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onPrimary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new,
              color: Theme.of(context).colorScheme.onSurface,
              size: 20,
            ),
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Text(
              'Privacy Settings',
              textAlign: TextAlign.center,
              style: AppTheme.serif(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: GoogleFonts.figtree(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        color: AppTheme.caramel,
        letterSpacing: 1.8,
      ),
    );
  }

  Widget _buildSettingsCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
        ),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }

  Widget _buildToggleRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: AppTheme.caramel.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AppTheme.caramel, size: 18),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.figtree(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: GoogleFonts.figtree(
                    fontSize: 12,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  /// A tappable settings row (no switch) — used for one-off actions like
  /// "Restore My Data". Shows a small spinner in place of the chevron while
  /// [loading] is true, and disables tapping in that state.
  Widget _buildActionRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool loading = false,
  }) {
    return InkWell(
      onTap: loading ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: AppTheme.caramel.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: AppTheme.caramel, size: 18),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.figtree(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: GoogleFonts.figtree(
                      fontSize: 12,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            if (loading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                Icons.chevron_right_rounded,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.4),
              ),
          ],
        ),
      ),
    );
  }
}
