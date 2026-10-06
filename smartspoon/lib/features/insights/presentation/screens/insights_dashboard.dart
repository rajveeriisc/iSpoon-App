// insights_dashboard.dart — main Insights tab screen.
//
// The analytics home: reads InsightsController and renders summary cards, trend
// charts, tremor/temperature sections, and generated coaching insights, with
// entry points into the bite-history, tremor-history, and meals-analysis pages.
// Purely presentational — all data and blending happen in the controller.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartspoon/features/insights/index.dart';
import 'package:smartspoon/features/insights/domain/services/insight_generator.dart';
import 'package:smartspoon/ble/spoon_runtime.dart';
import 'package:smartspoon/core/widgets/premium_widgets.dart';
import 'package:smartspoon/core/widgets/premium_header.dart';
import 'package:smartspoon/core/theme/app_theme.dart';

class InsightsDashboard extends StatefulWidget {
  const InsightsDashboard({super.key});

  @override
  State<InsightsDashboard> createState() => _InsightsDashboardState();
}

class _InsightsDashboardState extends State<InsightsDashboard> {
  String _activeTab = 'eating';
  bool _personalizedRecsEnabled = true;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _loadPersonalizationPref();
  }

  Future<void> _loadPersonalizationPref() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _personalizedRecsEnabled =
          prefs.getBool('privacy_personalized_recs') ?? true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InsightsController>();
    final unifiedData = context.watch<UnifiedDataService>();

    // Re-read the privacy toggle on rebuild (synchronous in-memory lookup once
    // the instance is cached) so a change made on the privacy settings page
    // takes effect while this dashboard stays mounted — a value captured only
    // in initState would go stale.
    _personalizedRecsEnabled =
        _prefs?.getBool('privacy_personalized_recs') ??
        _personalizedRecsEnabled;

    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      // HomePage paints the theme-aware gradient behind this tab; keeping the
      // scaffold transparent lets light/dark backgrounds show through.
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                // Shared app header: real profile avatar/name + working
                // notification bell, consistent with the Home tab.
                const PremiumHeader(
                  title: 'Insights',
                  subtitle: 'Recent behavior & trends',
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () async {
                      // Real refresh: reload today's live snapshot and the
                      // 90-day history the dashboard charts read from.
                      context.read<UnifiedDataService>().refreshTodaySnapshot();
                      await context.read<InsightsController>().fetchHistory(90);
                    },
                    color: colorScheme.primary,
                    backgroundColor: colorScheme.surface,
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 100),
                      child: Column(
                        children: [
                          CombinedMetricCard(
                            metric1: MetricData(
                              icon: Icons.restaurant_menu_rounded,
                              title: 'Total Bites',
                              value: '${unifiedData.selectedTotalBites}',
                              color: AppTheme.emerald,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        const MealsAnalysisPage(),
                                  ),
                                );
                              },
                            ),
                            metric2: MetricData(
                              icon: Icons.speed_rounded,
                              title: 'Eating Pace',
                              value:
                                  '${(unifiedData.selectedAvgBiteTime).toStringAsFixed(1)}s',
                              color: AppTheme.primary,
                              subtitle: 'sec / bite',
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        const BiteHistoryPage(),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 24),

                          // New Tab Navigation matching design
                          _buildTabNavigation(),
                          const SizedBox(height: 24),

                          // Tab Content (keeps original real charts/data)
                          _buildTabContent(controller),
                          const SizedBox(height: 24),

                          // Insights Section
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Key Observations',
                                  style: GoogleFonts.figtree(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: colorScheme.onSurface,
                                  ),
                                ),
                                Text(
                                  'Recent behavior & trends',
                                  style: GoogleFonts.figtree(
                                    fontSize: 13,
                                    color: colorScheme.onSurface.withValues(
                                      alpha: 0.6,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),

                          ..._buildInsightCards(controller),
                        ],
                      ),
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

  Widget _buildTabNavigation() {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          _buildTab('Eating', Icons.restaurant, 'eating', AppTheme.primary),
          _buildTab(
            'Movement',
            Icons.show_chart,
            'tremor',
            colorScheme.primary,
          ),
          _buildTab(
            'Temp',
            Icons.thermostat,
            'temperature',
            colorScheme.primary,
          ),
        ],
      ),
    );
  }

  Widget _buildTab(String label, IconData icon, String key, Color accent) {
    final isActive = _activeTab == key;
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inactiveColor = colorScheme.onSurface.withValues(alpha: 0.6);
    return Expanded(
      child: Semantics(
        button: true,
        selected: isActive,
        label: '$label tab',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => setState(() => _activeTab = key),
            borderRadius: BorderRadius.circular(24),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: isActive
                    ? accent.withValues(alpha: isDark ? 0.22 : 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: isActive ? accent : inactiveColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: GoogleFonts.figtree(
                      fontSize: 14,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                      color: isActive ? accent : inactiveColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildInsightCards(InsightsController controller) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!_personalizedRecsEnabled) {
      return [
        PremiumGlassCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.privacy_tip_outlined,
                color: colorScheme.onSurface.withValues(alpha: 0.6),
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Personalized recommendations are turned off.',
                  style: GoogleFonts.figtree(
                    fontSize: 14,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ];
    }

    final insights = InsightGenerator.generate(
      tremorSummaries: controller.tremorSummaries,
      dailySummaries: controller.dailySummaries,
    );

    if (insights.isEmpty) {
      return [
        PremiumGlassCard(
          padding: const EdgeInsets.all(16),
          borderRadius: 16,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.emerald.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.trending_up,
                  color: AppTheme.emerald,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Keep logging meals with your spoon — insights show up once we have enough data to compare.',
                  style: GoogleFonts.figtree(
                    fontSize: 14,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ];
    }

    final cards = <Widget>[];
    for (var i = 0; i < insights.length; i++) {
      final insight = insights[i];
      if (i > 0) cards.add(const SizedBox(height: 12));
      cards.add(
        AIInsightCard(
          type: insight.type,
          title: insight.title,
          message: insight.message,
          accentColor: insight.accentColor,
        ),
      );
    }
    return cards;
  }

  Widget _buildTabContent(InsightsController controller) {
    switch (_activeTab) {
      case 'eating':
        return _buildEatingPatternsTab(controller);
      case 'tremor':
        return _buildTremorTab(controller);
      case 'temperature':
        return _buildTemperatureTab();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildEatingPatternsTab(InsightsController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DailyFoodTimeline(summaries: controller.dailySummaries),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildTremorTab(InsightsController controller) {
    return TremorCharts(
      metrics: controller.tremor,
      onViewHistory: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TremorHistoryPage(controller: controller),
          ),
        );
      },
    );
  }

  Widget _buildTemperatureTab() {
    final colorScheme = Theme.of(context).colorScheme;
    return PremiumGlassCard(
      accentColor: const Color(0xFFFF7043),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Temperature Control',
                style: GoogleFonts.ptSerif(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              const Icon(Icons.thermostat, color: Color(0xFFFF7043)),
            ],
          ),
          const SizedBox(height: 16),
          Consumer<SpoonRuntime>(
            builder: (context, ble, _) {
              final blurb = Text(
                'Access full temperature controls and heater settings.',
                style: GoogleFonts.figtree(
                  fontSize: 14,
                  color: colorScheme.onSurface.withValues(alpha: 0.8),
                ),
              );

              // A connected spoon that reports NO heater gets no heater UI at
              // all — not the controls, and not the "get a Pro" line either.
              // Capability is the device's own answer (owner-status capability
              // bits), so this is a fact about the hardware in the user's hand,
              // not a guess worth advertising around. Temperature itself still
              // belongs here: the no-heater SKU reports it too.
              if (ble.connectedDeviceId != null &&
                  !ble.connectedDeviceHasHeater) {
                return Text(
                  'Live temperature from your spoon.',
                  style: GoogleFonts.figtree(
                    fontSize: 14,
                    color: colorScheme.onSurface.withValues(alpha: 0.8),
                  ),
                );
              }

              if (ble.connectedDeviceHasHeater) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    blurb,
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const HeaterControlPage(),
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          // Deep orange 700 keeps white label readable (>=3:1
                          // for large bold text); lighter FF7043 failed.
                          backgroundColor: const Color(0xFFE64A19),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 0,
                        ),
                        child: Text(
                          'Open Heater Control',
                          style: GoogleFonts.figtree(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }

              // Nothing connected: capability is genuinely unknown, so the
              // original guidance still applies.
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  blurb,
                  const SizedBox(height: 24),
                  Text(
                    'Connect an iSpoon Pro to access heater controls.',
                    style: GoogleFonts.figtree(
                      fontSize: 14,
                      color: colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
