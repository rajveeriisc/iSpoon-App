// tremor_history_page.dart — historical tremor-trend screen.
//
// Visualizes tremor severity over time from InsightsController's daily tremor
// summaries (low/moderate/high bands and average score per day), letting the
// user track how their hand-tremor metrics change across days. Read-only.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../domain/models.dart';
import '../../application/insights_controller.dart';
import 'package:smartspoon/core/theme/app_theme.dart';

class TremorHistoryPage extends StatefulWidget {
  const TremorHistoryPage({super.key, required this.controller});

  final InsightsController controller;

  @override
  State<TremorHistoryPage> createState() => _TremorHistoryPageState();
}

/// Number of daily-breakdown rows rendered per "page" in the data table.
/// Keeps widget construction cheap even when the selected range is dense
/// (e.g. 90 days); the underlying SQLite fetch already returns the whole
/// range at once since that query is cheap — only the rendering is chunked.
const int _kRowsPerPage = 14;

String _patternLabel(TremorLevel level) {
  switch (level) {
    case TremorLevel.low:
      return 'No repeated rhythm';
    case TremorLevel.moderate:
      return 'Some repeated rhythm';
    case TremorLevel.high:
      return 'More repeated rhythm';
  }
}

class _TremorHistoryPageState extends State<TremorHistoryPage> {
  int _selectedDays = 7; // Default to 7 days
  String _selectedMeal = 'All';
  List<DailyTremorSummary> _summaries = [];
  bool _isLoading = true;
  bool _isSyncing = false;
  int _visibleRowCount = _kRowsPerPage;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final data = await widget.controller.fetchTremorDataForRange(
        _selectedDays,
      );
      if (!mounted) return;
      setState(() {
        _summaries = data;
        _isLoading = false;
        _visibleRowCount = _kRowsPerPage;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Couldn't load your movement data. Please try again.",
            ),
          ),
        );
      }
    }
  }

  /// Manual sync: pull history from the cloud, then reload this page's range.
  Future<void> _syncFromCloud() async {
    setState(() => _isSyncing = true);
    try {
      final result = await widget.controller.syncFromCloud();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.userMessage)));
      await _loadData();
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: Text(
            'Hand movement',
            style: AppTheme.serif(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          centerTitle: true,
          elevation: 0,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final sorted = [..._summaries]..sort((a, b) => a.date.compareTo(b.date));
    final now = sorted.isEmpty ? DateTime.now() : sorted.last.date;
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
          'Hand movement',
          style: AppTheme.serif(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        actions: [
          IconButton(
            tooltip: 'Sync from cloud',
            icon: _isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            onPressed: _isSyncing ? null : _syncFromCloud,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _OverviewStrip(aggregate: display, days: _selectedDays),

            const SizedBox(height: 24),

            // Time Range Dropdown (matching Eating Pattern design)
            // Mobile-responsive Layout for Header + Dropdowns
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

            // Rendered incrementally; only the first `_visibleRowCount`
            // daily rows are built at a time so a dense 90-day range
            // doesn't construct ~90 DataRows up front.
            _TremorDataTable(
              entries: display.entries,
              visibleRowCount: _visibleRowCount,
              onLoadMore: () {
                setState(() {
                  _visibleRowCount = (_visibleRowCount + _kRowsPerPage).clamp(
                    0,
                    display.entries.length,
                  );
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  _TremorAggregate _computeAggregates(
    List<DailyTremorSummary> summaries,
    DateTime end,
    int days,
    String mealType,
  ) {
    final start = end.subtract(Duration(days: days - 1));
    var rawRange = summaries.where(
      (s) => !s.date.isBefore(start) && !s.date.isAfter(end),
    );

    List<DailyTremorSummary> range;
    if (mealType == 'All') {
      range = rawRange.where((s) => s.sampleCount > 0).toList();
    } else {
      range = rawRange
          .map((s) => s.mealBreakdown?[mealType])
          .whereType<DailyTremorSummary>()
          .where((s) => s.sampleCount > 0)
          .toList();
    }

    if (range.isEmpty) {
      return _TremorAggregate(
        entries: const [],
        avgMagnitude: 0,
        avgFrequency: 0,
        levelDistribution: const {},
        totalSamples: 0,
        rhythmicSamples: 0,
      );
    }

    final totalSamples = range.fold<int>(0, (sum, e) => sum + e.sampleCount);
    final avgMag = totalSamples == 0
        ? 0.0
        : range.fold<double>(
                0,
                (sum, e) => sum + e.avgMagnitude * e.sampleCount,
              ) /
              totalSamples;
    final frequencyEntries = range
        .where((e) => e.avgFrequencyHz > 0 && e.rhythmicSampleCount > 0)
        .toList();
    final frequencySamples = frequencyEntries.fold<int>(
      0,
      (sum, e) => sum + e.rhythmicSampleCount,
    );
    final avgFreq = frequencySamples == 0
        ? 0.0
        : frequencyEntries.fold<double>(
                0,
                (sum, e) => sum + e.avgFrequencyHz * e.rhythmicSampleCount,
              ) /
              frequencySamples;

    final Map<TremorLevel, int> levels = {};
    for (final entry in range) {
      levels.update(
        entry.dominantLevel,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }

    // Steadiness weighted by measured time: a day measured for 20 minutes
    // should count for more than one measured for 30 seconds.
    final measuredSeconds = range.fold<int>(0, (s, e) => s + e.measuredSeconds);
    final steadyEntries =
        range.where((e) => e.steadyPct != null && e.measuredSeconds > 0);
    final steadyWeight =
        steadyEntries.fold<int>(0, (s, e) => s + e.measuredSeconds);
    final steadyPct = steadyWeight == 0
        ? null
        : steadyEntries.fold<double>(
              0,
              (s, e) => s + e.steadyPct! * e.measuredSeconds,
            ) /
            steadyWeight;

    return _TremorAggregate(
      entries: range,
      avgMagnitude: avgMag,
      avgFrequency: avgFreq,
      levelDistribution: levels,
      totalSamples: totalSamples,
      rhythmicSamples: frequencySamples,
      steadyPct: steadyPct,
      measuredSeconds: measuredSeconds,
      fromModel: range.any((e) => e.fromModel),
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
                  setState(() => _selectedDays = val);
                  _loadData(); // Fetch new data when dropdown changes
                }
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// "12 min" / "45 s" — how much movement a reading is actually based on.
String _measuredLabel(int seconds) {
  if (seconds <= 0) return 'briefly';
  if (seconds < 90) return '$seconds s';
  return '${(seconds / 60).round()} min';
}

class _TremorAggregate {
  const _TremorAggregate({
    required this.entries,
    required this.avgMagnitude,
    required this.avgFrequency,
    required this.levelDistribution,
    required this.totalSamples,
    required this.rhythmicSamples,
    this.steadyPct,
    this.measuredSeconds = 0,
    this.fromModel = false,
  });

  final List<DailyTremorSummary> entries;
  final double avgMagnitude;
  final double avgFrequency;
  final Map<TremorLevel, int> levelDistribution;
  final int totalSamples;
  final int rhythmicSamples;

  /// Steadiness as stored by the model, weighted by how long each day was
  /// measured. Null for ranges that only contain older readings.
  final double? steadyPct;
  final int measuredSeconds;
  final bool fromModel;
}

class _OverviewStrip extends StatelessWidget {
  const _OverviewStrip({required this.aggregate, required this.days});

  final _TremorAggregate aggregate;
  final int days;

  @override
  Widget build(BuildContext context) {
    final hasData = aggregate.entries.isNotEmpty;
    // Which engine recorded this range is now stored with the meal, so the
    // page no longer has to infer "older reading" from a missing frequency.
    final likelyLegacyReading =
        hasData && !aggregate.fromModel && aggregate.steadyPct == null;
    final typicalLevel =
        aggregate.avgMagnitude <= TremorMetrics.moderateThreshold
        ? TremorLevel.low
        : aggregate.avgMagnitude <= TremorMetrics.highThreshold
        ? TremorLevel.moderate
        : TremorLevel.high;
    final typicalValue = !hasData
        ? '—'
        : likelyLegacyReading
        ? 'Older reading'
        : _patternLabel(typicalLevel);
    final typicalSubtitle = !hasData
        ? 'No clean readings yet'
        : likelyLegacyReading
        ? '${aggregate.avgMagnitude.toStringAsFixed(2)} / 3 across ${aggregate.totalSamples} readings; quality details unavailable'
        // Same wording as Home and AI Lab: the share of measured time that
        // carried no repeated rhythm, with the raw index kept for reference.
        : '${(aggregate.steadyPct ?? (100 - aggregate.avgMagnitude / 3 * 100)).round()}% '
              'steady, measured ${_measuredLabel(aggregate.measuredSeconds)} '
              'across ${aggregate.totalSamples} readings';
    final rhythmValue = aggregate.avgFrequency > 0
        ? aggregate.avgFrequency.toStringAsFixed(1)
        : likelyLegacyReading
        ? 'Not recorded'
        : 'Not seen';
    final rhythmSubtitle = aggregate.rhythmicSamples > 0
        ? 'Across ${aggregate.rhythmicSamples} readings with a repeated rhythm'
        : likelyLegacyReading
        ? 'Older readings did not store today’s quality checks'
        : hasData
        ? 'No repeated rhythm in clean readings'
        : 'Hold the spoon naturally for 4 seconds';
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 600;

        if (isNarrow) {
          return Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: _OverviewTile(
                  title: 'Typical pattern',
                  value: typicalValue,
                  unit: '',
                  subtitle: typicalSubtitle,
                  color: AppTheme.caramel,
                  icon: Icons.analytics,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: _OverviewTile(
                  title: 'Average rhythm',
                  value: rhythmValue,
                  unit: aggregate.avgFrequency > 0 ? 'Hz' : '',
                  subtitle: rhythmSubtitle,
                  color: AppTheme.sageDeep,
                  icon: Icons.graphic_eq_rounded,
                ),
              ),
            ],
          );
        }

        return Row(
          children: [
            Expanded(
              child: _OverviewTile(
                title: 'Typical pattern',
                value: typicalValue,
                unit: '',
                subtitle: typicalSubtitle,
                color: AppTheme.caramel,
                icon: Icons.analytics,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _OverviewTile(
                title: 'Average rhythm',
                value: rhythmValue,
                unit: aggregate.avgFrequency > 0 ? 'Hz' : '',
                subtitle: rhythmSubtitle,
                color: AppTheme.sageDeep,
                icon: Icons.graphic_eq_rounded,
              ),
            ),
          ],
        );
      },
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

class _TremorDataTable extends StatelessWidget {
  const _TremorDataTable({
    required this.entries,
    required this.visibleRowCount,
    required this.onLoadMore,
  });

  final List<DailyTremorSummary> entries;
  final int visibleRowCount;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
          ),
        ),
        child: Column(
          children: [
            const Icon(
              Icons.insights_rounded,
              color: AppTheme.primary,
              size: 28,
            ),
            const SizedBox(height: 10),
            Text(
              'No daily readings yet',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Complete a meal with the spoon connected to build this history.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    final dateFmt = DateFormat.MMMd();
    final columns = [
      const DataColumn(label: Text('Date')),
      const DataColumn(label: Text('Variation')),
      const DataColumn(label: Text('Index')),
      const DataColumn(label: Text('Samples')),
    ];

    // Only render the first `visibleRowCount` daily rows. The full range is
    // already fetched cheaply from local SQLite (see InsightsController) —
    // it's widget construction for ~90 DataRows at once that gets expensive,
    // so we chunk that part and let the user reveal more via "Load More".
    final totalRows = entries.length;
    final clampedVisible = visibleRowCount.clamp(0, totalRows);
    final hasMore = clampedVisible < totalRows;

    final rows = entries
        .take(clampedVisible)
        .map(
          (entry) => DataRow(
            cells: [
              DataCell(Text(dateFmt.format(entry.date))),
              DataCell(Text(_labelFor(entry.dominantLevel))),
              DataCell(Text(entry.avgMagnitude.toStringAsFixed(2))),
              DataCell(Text('${entry.sampleCount}')),
            ],
          ),
        )
        .toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final table = DataTable(
          horizontalMargin: constraints.maxWidth < 600 ? 12 : 24,
          columnSpacing: constraints.maxWidth < 600 ? 18 : 56,
          headingRowColor: WidgetStateProperty.all(
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
          ),
          columns: columns,
          rows: rows,
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

  String _labelFor(TremorLevel level) {
    switch (level) {
      case TremorLevel.low:
        return 'None';
      case TremorLevel.moderate:
        return 'Some';
      case TremorLevel.high:
        return 'More';
    }
  }
}
