// help_center_page.dart — help & support hub screen.
//
// Entry point for user support: links to the FAQ page, contact/support options,
// and external help resources (opened via url_launcher). Reached from the
// profile menu.
import 'package:flutter/material.dart';
import 'package:smartspoon/core/widgets/bowl_spoon_icon.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/geometric_background.dart';
import 'package:smartspoon/features/profile/presentation/widgets/profile_redesign_widgets.dart';
import 'package:smartspoon/features/profile/presentation/screens/faq_page.dart';

class HelpCenterPage extends StatelessWidget {
  const HelpCenterPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
           // Background
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
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          'How can we help you?',
                          style: AppTheme.serif(
                            fontSize: 24,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _buildHelpOption(
                        context,
                        icon: const Icon(Icons.question_answer_outlined),
                        title: 'FAQ',
                        subtitle: 'Common questions & answers',
                        onTap: () {
                           Navigator.push(
                            context,
                            MaterialPageRoute(builder: (context) => const FaqPage()),
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      _buildHelpOption(
                        context,
                        icon: const Icon(Icons.email_outlined),
                        title: 'Email Support',
                        subtitle: 'Get a response within 24 hours',
                        onTap: () async {
                          final uri = Uri(
                            scheme: 'mailto',
                            path: 'support@i-spoon.app',
                            query: 'subject=i-Spoon Support Request&body=Hi i-Spoon team,%0A%0A',
                          );
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri);
                          } else if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('No email app found. Email us at support@i-spoon.app')),
                            );
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      _buildHelpOption(
                        context,
                        icon: const Icon(Icons.book_outlined),
                        title: 'User Guide',
                        subtitle: 'Learn how to use i-Spoon',
                        onTap: () => _showUserGuide(context),
                      ),
                      const SizedBox(height: 30),
                      Divider(color: Theme.of(context).dividerColor),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showUserGuide(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final bg = isDark ? AppTheme.darkSurfaceCard : AppTheme.surface;
        final textColor = isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary;
        final subColor = isDark ? AppTheme.darkTextSecondary : AppTheme.textSecondary;

        final steps = [
          ('1. Connect your Spoon', const Icon(Icons.bluetooth), 'Tap the + button on the home screen, turn on Bluetooth, and select your i-Spoon device from the list.'),
          ('2. Start a Meal', const BowlSpoonIcon(), 'Once connected, tap "Start Meal" on the home screen. The app will begin tracking your bites automatically.'),
          ('3. Track Bites', const Icon(Icons.track_changes), 'Every bite is detected by the IMU sensor. Your live bite count and eating speed appear in real time.'),
          ('4. Monitor Temperature', const Icon(Icons.thermostat), 'The spoon\'s temperature sensor shows food temperature in °C. An alert fires if food is too hot (>60°C).'),
          ('5. View Insights', const Icon(Icons.bar_chart), 'After your meal, go to the Insights tab to see bite history, tremor analysis, and daily summaries.'),
          ('6. Set Daily Goals', const Icon(Icons.flag), 'Go to Profile → Daily Target to set per-meal bite goals. Your progress is shown on the Profile page.'),
          ('7. Sync Data', const Icon(Icons.cloud_upload), 'Data syncs automatically every 5 minutes when online. You can also pull-to-refresh on any screen.'),
        ];

        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          builder: (_, controller) => Container(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? AppTheme.darkBorder : AppTheme.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'User Guide',
                  style: AppTheme.serif(
                    fontSize: 20, fontWeight: FontWeight.w600, color: textColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Getting started with i-Spoon',
                  style: GoogleFonts.figtree(fontSize: 13, color: subColor),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView.separated(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                    itemCount: steps.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 12),
                    itemBuilder: (_, i) {
                      final (title, icon, desc) = steps[i];
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isDark ? AppTheme.darkCreamElevated : AppTheme.oat,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isDark ? AppTheme.darkBorder : AppTheme.border,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: AppTheme.caramel.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: IconTheme(
                                data: const IconThemeData(
                                    color: AppTheme.caramel, size: 20),
                                child: icon,
                              ),
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
                                      fontWeight: FontWeight.bold,
                                      color: textColor,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    desc,
                                    style: GoogleFonts.figtree(
                                      fontSize: 13,
                                      color: subColor,
                                      height: 1.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAppBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
             icon: Icon(Icons.arrow_back_ios_new, color: Theme.of(context).colorScheme.onSurface, size: 20),
             onPressed: () => Navigator.pop(context),
          ),
          Text(
            'Help Center',
            style: AppTheme.serif(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 40), // Balance
        ],
      ),
    );
  }

  Widget _buildHelpOption(
    BuildContext context, {
    required Widget icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ProfileCard(
      accentColor: AppTheme.caramel,
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.caramel.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: IconTheme(
                    data: const IconThemeData(
                        color: AppTheme.caramel, size: 24),
                    child: icon,
                  ),
                ),
                 const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.figtree(
                          fontWeight: FontWeight.bold, 
                          fontSize: 16,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: GoogleFonts.figtree(
                          color: AppTheme.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios, size: 16, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3)),
              ],
            ),
          ),
        ),
      ),
    );
  }

}
