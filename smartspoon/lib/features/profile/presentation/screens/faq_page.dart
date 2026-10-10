// faq_page.dart — frequently-asked-questions screen.
//
// A mostly-static, expandable Q&A list about using the spoon and app, with
// links (via url_launcher) to external help resources. Reached from the profile
// help section.
import 'package:flutter/material.dart';
import 'package:smartspoon/core/widgets/bowl_spoon_icon.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/geometric_background.dart';
import 'package:smartspoon/features/profile/presentation/widgets/profile_redesign_widgets.dart';

// ── Data model ───────────────────────────────────────────────────────────────

class _FaqEntry {
  final String category;
  final Widget icon;
  final String question;
  final String answer;

  const _FaqEntry({
    required this.category,
    required this.icon,
    required this.question,
    required this.answer,
  });
}

const List<_FaqEntry> _allFaqs = [
  // Device
  _FaqEntry(
    category: 'Device',
    icon: const Icon(Icons.bluetooth_rounded),
    question: 'How do I connect my spoon?',
    answer:
        'Make sure Bluetooth is on and the spoon is powered on. Go to the Home tab → tap the + icon → select your device from the scan list. The app will connect and start receiving data automatically.',
  ),
  _FaqEntry(
    category: 'Device',
    icon: const Icon(Icons.bluetooth_disabled_rounded),
    question: 'My spoon won\'t appear in the scan list. What do I do?',
    answer:
        '1. Make sure the spoon is charged and powered on.\n2. Keep the spoon within 1 metre of your phone.\n3. Turn Bluetooth off and on again.\n4. Restart the app and try scanning again.\n5. If it still doesn\'t appear, restart the spoon by pressing its power button for 5 seconds.',
  ),
  _FaqEntry(
    category: 'Device',
    icon: const Icon(Icons.battery_alert_rounded),
    question: 'How do I know if the spoon is low on battery?',
    answer:
        'The battery level is shown on the device details screen. When battery falls below 15%, the app will show a low-battery alert and the heater will be automatically disabled to preserve power.',
  ),
  _FaqEntry(
    category: 'Device',
    icon: const Icon(Icons.thermostat_rounded),
    question: 'How does the food temperature sensor work?',
    answer:
        'The spoon tip contains a temperature sensor that reads the temperature of food on contact. The reading appears in real time on the Home screen. An alert fires if the food exceeds 60°C to prevent burns.',
  ),
  _FaqEntry(
    category: 'Device',
    icon: const Icon(Icons.local_fire_department_rounded),
    question: 'What if the heater doesn\'t turn on?',
    answer:
        'Check the following:\n• Battery must be above 15%\n• Heater must be enabled in Settings → Device → Heater\n• The food temperature must be below your activation threshold (default 15°C)\nIf it still doesn\'t work, reconnect the device.',
  ),

  // Eating
  _FaqEntry(
    category: 'Eating',
    icon: const BowlSpoonIcon(),
    question: 'How does bite detection work?',
    answer:
        'Motion sensors in the handle follow the spoon 100 times a second. The spoon recognises the shape of a bite — lifting from the plate, pausing at your mouth, and coming back down — and counts it there and then, sending the total to your phone as you eat.',
  ),
  _FaqEntry(
    category: 'Eating',
    icon: const Icon(Icons.speed_rounded),
    question: 'How is eating speed calculated?',
    answer:
        'Your pace is how many bites you take per minute, averaged over the last few minutes so it does not jump about. Most people eat at somewhere between 10 and 20 bites a minute.',
  ),
  _FaqEntry(
    category: 'Eating',
    icon: const Icon(Icons.warning_amber_rounded),
    question: 'What does the "Eating Too Fast" alert mean?',
    answer:
        'When your eating speed exceeds 25 bites/min, an alert appears at the top of the screen. Eating slowly (20+ minutes per meal) helps with digestion and lets your body signal fullness in time. Try to pause between bites.',
  ),
  _FaqEntry(
    category: 'Eating',
    icon: const Icon(Icons.flag_rounded),
    question: 'How do I set my daily bite goal?',
    answer:
        'Go to Profile → Daily Target. You can set separate goals for Breakfast, Lunch, Dinner, and Snacks. The total is shown as your Daily Target on the Profile page with a progress bar.',
  ),
  _FaqEntry(
    category: 'Eating',
    icon: const Icon(Icons.device_thermostat_rounded),
    question: 'How do I change the temperature units?',
    answer:
        'Currently the app displays temperature in Celsius (°C). Fahrenheit support is planned for a future update.',
  ),

  // Data
  _FaqEntry(
    category: 'Data',
    icon: const Icon(Icons.cloud_sync_rounded),
    question: 'When does my data sync to the cloud?',
    answer:
        'Everything is saved on your phone first, so nothing is lost when you are offline. It uploads on its own in the background — after a meal, and again overnight. All data is stored locally on your device first so nothing is lost if you\'re offline.',
  ),
  _FaqEntry(
    category: 'Data',
    icon: const Icon(Icons.people_rounded),
    question: 'Can I track multiple users?',
    answer:
        'Yes. Each user needs their own account. Log out from Profile → Log Out, then sign in with a different account. Each account has its own meals, bite history, and goals.',
  ),
  _FaqEntry(
    category: 'Data',
    icon: const Icon(Icons.insights_rounded),
    question: 'What does the movement index mean?',
    answer:
        'The movement index is a 0–3 eating-movement trend calculated from a clean 4-second accelerometer and gyroscope sample while you use the spoon. It describes repeated rhythmic movement—not overall coordination or steadiness. Lower values mean no clear repeated rhythm was found; higher values mean a stronger repeated rhythm. Compare your own results across several meals rather than treating one reading as a diagnosis. Sensor quality, ordinary eating motion, and how the spoon is held can affect the result.',
  ),
  _FaqEntry(
    category: 'Data',
    icon: const Icon(Icons.delete_forever_rounded),
    question: 'How do I delete my data?',
    answer:
        'Use Profile → Delete account to request removal of your account and cloud data. You can also remove local app data from your phone’s system storage settings.',
  ),

  // Troubleshooting
  _FaqEntry(
    category: 'Troubleshooting',
    icon: const Icon(Icons.refresh_rounded),
    question: 'The app shows 0 bites even though I\'m eating. Why?',
    answer:
        'Make sure:\n1. The spoon is connected (blue indicator on Home screen)\n2. A meal session is active (tap Start Meal)\n3. The IMU is initialised — you\'ll see a "Calibrating" status briefly on first use\n4. Hold the spoon naturally — unusually slow or very small movements may not be detected',
  ),
  _FaqEntry(
    category: 'Troubleshooting',
    icon: const Icon(Icons.notifications_off_rounded),
    question: 'I\'m not receiving notifications. What should I check?',
    answer:
        'Check these in order:\n1. Profile → Settings → Notifications is ON\n2. Phone Settings → i-Spoon → Notifications are allowed\n3. Battery optimization is disabled for i-Spoon (Android: Settings → Battery → i-Spoon → Unrestricted)\n4. Quiet hours in Privacy Settings are not blocking your time slot',
  ),
];

// ── Page ─────────────────────────────────────────────────────────────────────

class FaqPage extends StatefulWidget {
  const FaqPage({super.key});

  @override
  State<FaqPage> createState() => _FaqPageState();
}

class _FaqPageState extends State<FaqPage> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  String _selectedCategory = 'All';

  static const _categories = [
    'All',
    'Device',
    'Eating',
    'Data',
    'Troubleshooting',
  ];

  List<_FaqEntry> get _filtered {
    return _allFaqs.where((faq) {
      final matchesCategory =
          _selectedCategory == 'All' || faq.category == _selectedCategory;
      final q = _searchQuery.toLowerCase();
      final matchesSearch =
          q.isEmpty ||
          faq.question.toLowerCase().contains(q) ||
          faq.answer.toLowerCase().contains(q);
      return matchesCategory && matchesSearch;
    }).toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final filtered = _filtered;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: isDark
                  ? AppTheme.darkBackgroundGradient
                  : AppTheme.backgroundGradient,
            ),
          ),
          const GeometricBackground(),

          SafeArea(
            child: Column(
              children: [
                // ── App bar ──────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.arrow_back_ios_new,
                          color: Theme.of(context).colorScheme.onSurface,
                          size: 20,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Text(
                        'FAQ',
                        style: AppTheme.serif(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        '${filtered.length} Q',
                        style: GoogleFonts.figtree(
                          fontSize: 12,
                          color: AppTheme.caramel,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Search bar ───────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) => setState(() => _searchQuery = v),
                    style: GoogleFonts.figtree(
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Search questions…',
                      hintStyle: GoogleFonts.figtree(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.4),
                        fontSize: 14,
                      ),
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.4),
                      ),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: isDark
                          ? AppTheme.darkSurfaceCard
                          : AppTheme.surface,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),

                // ── Category chips ───────────────────────────────────────
                SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: _categories.length,
                    separatorBuilder: (_, i) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final cat = _categories[i];
                      final selected = _selectedCategory == cat;
                      return GestureDetector(
                        onTap: () => setState(() => _selectedCategory = cat),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: selected
                                ? AppTheme.caramel
                                : (isDark
                                      ? AppTheme.darkSurfaceCard
                                      : AppTheme.surface),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: selected
                                  ? AppTheme.caramel
                                  : Theme.of(
                                      context,
                                    ).dividerColor.withValues(alpha: 0.2),
                            ),
                          ),
                          child: Text(
                            cat,
                            style: GoogleFonts.figtree(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: selected
                                  ? Colors.white
                                  : Theme.of(context).colorScheme.onSurface
                                        .withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),

                const SizedBox(height: 12),

                // ── FAQ list ─────────────────────────────────────────────
                Expanded(
                  child: filtered.isEmpty
                      ? _buildEmpty(context)
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                          itemCount: filtered.length + 1, // +1 for footer
                          separatorBuilder: (_, i) =>
                              const SizedBox(height: 12),
                          itemBuilder: (_, i) {
                            if (i == filtered.length) {
                              return _buildContactFooter(context);
                            }
                            return _FaqTile(entry: filtered[i]);
                          },
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 56,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 12),
          Text(
            'No results for "$_searchQuery"',
            style: GoogleFonts.figtree(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              _searchController.clear();
              setState(() {
                _searchQuery = '';
                _selectedCategory = 'All';
              });
            },
            child: Text(
              'Clear search',
              style: GoogleFonts.figtree(color: AppTheme.caramel),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactFooter(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: ProfileCard(
        accentColor: AppTheme.caramel,
        child: Column(
          children: [
            Icon(Icons.headset_mic_rounded, color: AppTheme.caramel, size: 32),
            const SizedBox(height: 10),
            Text(
              'Still have questions?',
              style: GoogleFonts.figtree(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Our support team replies within 24 hours',
              style: GoogleFonts.figtree(
                fontSize: 13,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  final uri = Uri(
                    scheme: 'mailto',
                    path: 'support@i-spoon.app',
                    query: 'subject=i-Spoon FAQ — Need Help',
                  );
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri);
                  } else if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Email us at support@i-spoon.app'),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.email_outlined, size: 18),
                label: Text(
                  'Contact Support',
                  style: GoogleFonts.figtree(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.caramel,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── FAQ Tile ─────────────────────────────────────────────────────────────────

class _FaqTile extends StatefulWidget {
  final _FaqEntry entry;
  const _FaqTile({required this.entry});

  @override
  State<_FaqTile> createState() => _FaqTileState();
}

class _FaqTileState extends State<_FaqTile>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _ctrl;
  late final Animation<double> _rotate;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _rotate = Tween<double>(
      begin: 0,
      end: 0.5,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    _expanded ? _ctrl.forward() : _ctrl.reverse();
  }

  Color get _categoryColor {
    switch (widget.entry.category) {
      case 'Device':
        return AppTheme.caramel;
      case 'Eating':
        return AppTheme.honey;
      case 'Data':
        return AppTheme.sageDeep;
      case 'Troubleshooting':
        return AppTheme.paprika;
      default:
        return AppTheme.caramel;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = _categoryColor;

    return ProfileCard(
      accentColor: color,
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: _toggle,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Category icon
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: IconTheme(
                      data: IconThemeData(color: color, size: 18),
                      child: widget.entry.icon,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Question text
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Category badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            widget.entry.category,
                            style: GoogleFonts.figtree(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: color,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.entry.question,
                          style: GoogleFonts.figtree(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Animated chevron
                  RotationTransition(
                    turns: _rotate,
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: color,
                      size: 22,
                    ),
                  ),
                ],
              ),
              // Animated answer
              FadeTransition(
                opacity: _fade,
                child: SizeTransition(
                  sizeFactor: _fade,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Divider(
                          color: isDark ? AppTheme.darkBorder : AppTheme.border,
                          height: 1,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          widget.entry.answer,
                          style: GoogleFonts.figtree(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.75),
                            fontSize: 13.5,
                            height: 1.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Keep FaqItem for any external references (now just delegates to _FaqTile style)
class FaqItem extends StatelessWidget {
  final String question;
  final String answer;
  const FaqItem({super.key, required this.question, required this.answer});

  @override
  Widget build(BuildContext context) {
    return _FaqTile(
      entry: _FaqEntry(
        category: 'General',
        icon: const Icon(Icons.help_outline_rounded),
        question: question,
        answer: answer,
      ),
    );
  }
}
