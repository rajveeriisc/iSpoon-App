// insights_dashboard.dart — main Insights tab screen.
//
// The analytics home: reads InsightsController and renders summary cards, trend
// charts, tremor/temperature sections, and generated coaching insights, with
// entry points into the bite-history, tremor-history, and meals-analysis pages.
// Purely presentational — all data and blending happen in the controller.
import 'package:flutter/material.dart';
import 'package:smartspoon/core/widgets/bowl_spoon_icon.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartspoon/features/insights/index.dart';
import 'package:smartspoon/features/insights/domain/services/insight_generator.dart';
import 'package:smartspoon/core/widgets/premium_widgets.dart';
import 'package:smartspoon/core/widgets/premium_header.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/card_layout.dart';

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
                  subtitle: 'How your meals have been going',
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
                      padding: CardLayout.listPadding(context,
                          top: AppTheme.spaceSm),
                      child: Column(
                        children: [
                          CombinedMetricCard(
                            metric1: MetricData(
                              icon: const BowlSpoonIcon(),
                              title: 'Total Bites',
                              value: '${unifiedData.selectedTotalBites}',
                              color: AppTheme.emerald,
                              // Both figures here are TODAY's, from
                              // _todayStatsForDevice. The pages they open
                              // default to seven days, so leaving the period
                              // off made the two look like they disagreed.
                              subtitle: 'today',
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
                              icon: const Icon(Icons.speed_rounded),
                              title: 'Eating Pace',
                              value:
                                  '${(unifiedData.selectedAvgBiteTime).toStringAsFixed(1)}s',
                              color: AppTheme.primary,
                              subtitle: 'today · sec between bites',
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
                                  'What stands out',
                                  style: GoogleFonts.figtree(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: colorScheme.onSurface,
                                  ),
                                ),
                                Text(
                                  'Picked up from your recent meals',
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
          _buildTab('Eating', const BowlSpoonIcon(), 'eating', AppTheme.primary),
          _buildTab(
            'Movement',
            const Icon(Icons.show_chart),
            'tremor',
            colorScheme.primary,
          ),
        ],
      ),
    );
  }

  Widget _buildTab(String label, Widget icon, String key, Color accent) {
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
                  IconTheme(data: IconThemeData(size: 18,
                    color: isActive ? accent : inactiveColor), child: icon),
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

    // SuggestionEngine works from one meal's bite timings; InsightGenerator
    // works from the daily rollups. They answer different questions ("what
    // happened in your last meal" vs "what has this week looked like"), so
    // both run, suggestions first — they are the more specific of the two.
    //
    // A "no meals recorded yet" suggestion is dropped here, not in the
    // engine: the screen already has its own empty state below, and the
    // engine has to be able to say "nothing recorded" to callers that don't.
    final suggestions = controller.suggestions
        .where((s) => s.kind != SuggestionKind.learning || s.id != 'no_data')
        .toList(growable: false);

    final suggestionCard = suggestions.isEmpty
        ? null
        : Recommendations(
            suggestions: suggestions,
            margin: EdgeInsets.zero,
          );

    if (insights.isEmpty) {
      if (suggestionCard != null) return [suggestionCard];
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
                  'Eat a few more meals with your spoon and patterns worth mentioning will show up here.',
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
    if (suggestionCard != null) {
      cards.add(suggestionCard);
      cards.add(const SizedBox(height: 12));
    }
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

}
