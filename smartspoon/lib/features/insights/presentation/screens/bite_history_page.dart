// bite_history_page.dart — historical bite-count browsing screen.
//
// Shows the user's bite history over time (per-day / per-meal counts and trends)
// sourced from InsightsController's daily bite summaries. Read-only charts and
// lists for reviewing eating patterns across days.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../application/insights_controller.dart';
import '../../domain/models.dart';
import 'package:smartspoon/core/theme/app_theme.dart';

class BiteHistoryPage extends StatefulWidget {
  const BiteHistoryPage({super.key});

  @override
  State<BiteHistoryPage> createState() => _BiteHistoryPageState();
}

/// Number of daily-breakdown rows rendered per "page" in the data table.
/// Keeps widget construction cheap even when the selected range is dense
/// (e.g. 90 days); the underlying SQLite fetch already returns the whole
/// range at once since that query is cheap — only the rendering is chunked.
const int _kRowsPerPage = 14;

class _BiteHistoryPageState extends State<BiteHistoryPage> {
  int _selectedDays = 7; // Default to 7 days
  String _selectedMeal = 'All';
  int _visibleRowCount = _kRowsPerPage;

  @override
  Widget build(BuildContext context) {
    // Watch daily summaries directly from controller so live updates rebuild the page
    final controller = context.watch<InsightsController>();

    // Sort summaries by date
    final sorted = [...controller.dailySummaries]
      ..sort((a, b) => a.date.compareTo(b.date));

    final now = DateTime.now();

    // Compute aggregates for selected range
    final display = _computeAggregates(
      sorted,
      now,
      _selectedDays,
      _selectedMeal,
    );

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          'Eating Patterns',
          style: AppTheme.serif(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        actions: [
          IconButton(
            tooltip: 'Sync from cloud',
            icon: controller.isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            onPressed: controller.isSyncing
                ? null
                : () async {
                    final result = await controller.syncFromCloud();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(result.userMessage)));
                  },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Overview Cards
            _OverviewStrip(aggregate: display, days: _selectedDays),

            const SizedBox(height: 24),

            // Meal Breakdown Chart
            RepaintBoundary(
              child: _MealBreakdownChart(aggregate: display),
            ),

            const SizedBox(height: 24),

            // Time Range & Meal Dropdowns
            LayoutBuilder(
              builder: (context, constraints) {
                final isSmall = constraints.maxWidth < 600;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!isSmall)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _buildHeaderTitle(context),
                          _buildDropdownsRow(context),
                        ],
                      )
                    else ...[
                      _buildHeaderTitle(context),
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: _buildDropdownsRow(context),
                      ),
                    ],
                  ],
                );
              },
            ),

            const SizedBox(height: 12),

            // Data Table (rendered incrementally; only the first
            // `_visibleRowCount` daily rows are built at a time so a dense
            // 90-day range doesn't construct ~90 DataRows up front).
            _BiteDataTable(
              aggregate: display,
              visibleRowCount: _visibleRowCount,
              onLoadMore: () {
                setState(() {
                  _visibleRowCount = (_visibleRowCount + _kRowsPerPage).clamp(
                    0,
                    display.summaries.length,
                  );
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderTitle(BuildContext context) {
    return Text(
      'Daily Breakdown',
      style: GoogleFonts.figtree(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  Widget _buildDropdownsRow(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Meal Selection Dropdown
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
            ),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedMeal,
              isDense: true,
              icon: Icon(
                Icons.keyboard_arrow_down,
                size: 18,
                color: AppTheme.caramel,
              ),
              style: GoogleFonts.figtree(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
              items: [
                'All',
                'Breakfast',
                'Lunch',
                'Snacks',
                'Dinner',
              ].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
              onChanged: (val) {
                if (val != null) {
                  setState(() {
                    _selectedMeal = val;
                    _visibleRowCount = _kRowsPerPage;
                  });
                }
              },
            ),
          ),
        ),
        const SizedBox(width: 12),
        // Date Range Dropdown
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
            ),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _selectedDays,
              isDense: true,
              icon: Icon(
                Icons.keyboard_arrow_down,
                size: 18,
                color: AppTheme.caramel,
              ),
              style: GoogleFonts.figtree(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
              items: const [
                DropdownMenuItem(value: 7, child: Text('Last 7 Days')),
                DropdownMenuItem(value: 30, child: Text('1 Month')),
                DropdownMenuItem(value: 60, child: Text('2 Months')),
                DropdownMenuItem(value: 90, child: Text('3 Months')),
              ],
              onChanged: (val) {
                if (val != null) {
                  setState(() {
                    _selectedDays = val;
                    _visibleRowCount = _kRowsPerPage;
                  });
                }
              },
            ),
          ),
        ),
      ],
    );
  }

  _BiteAggregate _computeAggregates(
    List<DailyBiteSummary> summaries,
    DateTime end,
    int days,
    String selectedMeal,
  ) {
    final start = end.subtract(Duration(days: days - 1));
    final range = summaries
        .where((s) => !s.date.isBefore(start) && !s.date.isAfter(end))
        .toList();

    if (range.isEmpty) {
      return _BiteAggregate(
        summaries: [],
        totalBites: 0,
        totalDuration: 0,
        avgPace: 0,
        avgDuration: 0,
        mealBites: const {},
        selectedMeal: selectedMeal,
      );
    }

    // Aggregate meal-wise bites
    final mealAgg = <String, int>{};
    for (var day in range) {
      day.mealBites.forEach((meal, bites) {
        mealAgg[meal] = (mealAgg[meal] ?? 0) + bites;
      });
    }

    // Always every meal in the period. The meal dropdown sits under "Daily
    // Breakdown" and scopes THAT TABLE; it used to silently rewrite the two
    // cards above it as well, which is what produced "Period Total 22" while
    // the distribution underneath listed Lunch at 51.
    final totalBites = range.fold<int>(0, (sum, e) => sum + e.totalBites);
    final totalDuration = range.fold<double>(
      0,
      (sum, e) => sum + e.totalDurationMin,
    );
    final avgPace = totalDuration > 0 ? totalBites / totalDuration : 0.0;
    final avgDuration =
        range.fold<double>(0, (sum, e) => sum + e.avgMealDurationMin) /
        range.length;

    // No longer building flatEntries. The table reads directly from `range`.

    return _BiteAggregate(
      summaries: range.reversed.toList(),
      totalBites: totalBites,
      totalDuration: totalDuration,
      avgPace: avgPace,
      avgDuration: avgDuration,
      mealBites: mealAgg,
      selectedMeal: selectedMeal,
    );
  }
}

class _BiteAggregate {
  const _BiteAggregate({
    required this.summaries,
    required this.totalBites,
    required this.totalDuration,
    required this.avgPace,
    required this.avgDuration,
    required this.mealBites,
    required this.selectedMeal,
  });

  final List<DailyBiteSummary> summaries;
  final int totalBites;
  final double totalDuration;
  final double avgPace;
  final double avgDuration;
  final Map<String, int> mealBites;
  final String selectedMeal;
}

class _OverviewStrip extends StatelessWidget {
  const _OverviewStrip({required this.aggregate, required this.days});

  final _BiteAggregate aggregate;
  final int days;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _OverviewTile(
            title: 'Period Total',
            value: '${aggregate.totalBites}',
            unit: 'total bites',
            subtitle:
                'All meals · avg ${(days > 0 ? (aggregate.totalBites / days) : 0).toStringAsFixed(1)}/day',
            color: AppTheme.caramel,
            icon: Icons.analytics,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _OverviewTile(
            title: 'Avg Pace',
            value: aggregate.avgPace.isNaN
                ? '0.0'
                : aggregate.avgPace.toStringAsFixed(1),
            unit: 'bites/min',
            subtitle: 'All meals, over $days days',
            color: AppTheme.caramel,
            icon: Icons.timer,
          ),
        ),
      ],
    );
  }
}

/// Share of the period's bites held by each meal, in percent.
///
/// A distribution has to be taken over the things it is drawing. This used to
/// divide each meal by `aggregate.totalBites`, which the meal filter had
/// already narrowed to ONE meal — so with "Snacks" selected, Lunch's 51 bites
/// over Snacks' 22 rendered as "232%", and the number fed straight into a
/// FractionallySizedBox, drawing that bar at 2.3x the width of its card.
///
/// Guarantees: no entry exceeds 100, and the entries sum to 100 whenever any
/// bites exist.
Map<String, double> mealDistributionShares(Map<String, int> mealBites) {
  final positive = <String, int>{
    for (final e in mealBites.entries)
      if (e.value > 0) e.key: e.value,
  };
  final total = positive.values.fold<int>(0, (sum, v) => sum + v);
  if (total <= 0) {
    return {for (final k in mealBites.keys) k: 0.0};
  }
  return {
    for (final k in mealBites.keys)
      k: (((positive[k] ?? 0) / total) * 100).clamp(0.0, 100.0),
  };
}

class _MealBreakdownChart extends StatelessWidget {
  const _MealBreakdownChart({required this.aggregate});

  final _BiteAggregate aggregate;

  @override
  Widget build(BuildContext context) {
    final meals = aggregate.mealBites.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final shares = mealDistributionShares(aggregate.mealBites);
    final total = meals.fold<int>(0, (sum, e) => sum + e.value);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Meal Distribution',
            style: GoogleFonts.figtree(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 20),
          if (total == 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                'No meal data available for this period.',
                textAlign: TextAlign.center,
                style: GoogleFonts.figtree(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            )
          else
            ...meals.map((meal) {
              final double percentage = shares[meal.key] ?? 0.0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          meal.key,
                          style: GoogleFonts.figtree(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                        Text(
                          '${meal.value} bites (${percentage.toStringAsFixed(0)}%)',
                          style: GoogleFonts.figtree(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.caramel,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Stack(
                      children: [
                        Container(
                          height: 10,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).dividerColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                        FractionallySizedBox(
                          widthFactor: (percentage / 100).clamp(0.0, 1.0),
                          child: Container(
                            height: 10,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  AppTheme.caramel,
                                  AppTheme.caramel.withValues(alpha: 0.6),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}

class _OverviewTile extends StatelessWidget {
  const _OverviewTile({
    required this.title,
    required this.value,
    required this.unit,
    required this.subtitle,
    required this.color,
    required this.icon,
  });

  final String title;
  final String value;
  final String unit;
  final String subtitle;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: GoogleFonts.figtree(
                  fontSize: 13,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                  fontWeight: FontWeight.w500,
                ),
              ),
              Icon(icon, color: color, size: 18),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: AppTheme.serif(
              fontSize: 28,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          Text(
            unit,
            style: GoogleFonts.figtree(
              fontSize: 12,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              subtitle,
              style: GoogleFonts.figtree(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BiteDataTable extends StatelessWidget {
  const _BiteDataTable({
    required this.aggregate,
    required this.visibleRowCount,
    required this.onLoadMore,
  });

  final _BiteAggregate aggregate;
  final int visibleRowCount;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (aggregate.summaries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No meal data for this period.',
            style: GoogleFonts.figtree(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }

    final dateFmt = DateFormat.MMMd();

    // Determine columns based on selected meal
    final bool showAll = aggregate.selectedMeal == 'All';
    final columns = [
      const DataColumn(label: Text('Date')),
      if (showAll) ...[
        const DataColumn(label: Text('Breakfast')),
        const DataColumn(label: Text('Lunch')),
        const DataColumn(label: Text('Snacks')),
        const DataColumn(label: Text('Dinner')),
        const DataColumn(label: Text('Total')),
      ] else ...[
        DataColumn(label: Text(aggregate.selectedMeal)),
      ],
    ];

    // Only render the first `visibleRowCount` daily rows. The full range is
    // already fetched cheaply from local SQLite (see InsightsController) —
    // it's widget construction for ~90 DataRows at once that gets expensive,
    // so we chunk that part and let the user reveal more via "Load More".
    final totalRows = aggregate.summaries.length;
    final clampedVisible = visibleRowCount.clamp(0, totalRows);
    final visibleSummaries = aggregate.summaries.take(clampedVisible);
    final hasMore = clampedVisible < totalRows;

    final rows = visibleSummaries.map((summary) {
      final bites = summary.mealBites;
      return DataRow(
        cells: [
          DataCell(Text(dateFmt.format(summary.date))),
          if (showAll) ...[
            DataCell(Text('${bites['Breakfast'] ?? 0}')),
            DataCell(Text('${bites['Lunch'] ?? 0}')),
            DataCell(Text('${bites['Snacks'] ?? 0}')),
            DataCell(Text('${bites['Dinner'] ?? 0}')),
            DataCell(
              Text(
                '${summary.totalBites}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ] else ...[
            DataCell(Text('${bites[aggregate.selectedMeal] ?? 0}')),
          ],
        ],
      );
    }).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final table = DataTable(
          headingRowColor: WidgetStateProperty.all(
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
          ),
          columns: columns,
          rows: rows,
          dataRowMinHeight: 48,
          dataRowMaxHeight: 48,
          columnSpacing: showAll ? 20 : 56,
          horizontalMargin: 16,
        );

        final tableWidget = constraints.maxWidth < 600
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: table,
              )
            : table;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: tableWidget,
              ),
            ),
            if (hasMore) ...[
              const SizedBox(height: 12),
              Center(
                child: OutlinedButton(
                  onPressed: onLoadMore,
                  child: Text(
                    'Load More (${totalRows - clampedVisible} more days)',
                    style: GoogleFonts.figtree(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
