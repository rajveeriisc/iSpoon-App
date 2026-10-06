// daily_food_timeline.dart — per-day bites bar chart widget.
//
// DailyFoodTimeline renders a fl_chart bar chart of daily bite counts from a
// list of DailyBiteSummary, giving an at-a-glance view of eating activity over
// recent days; tapping drills into the bite-history page.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/premium_widgets.dart';
import '../../domain/models.dart';
import '../screens/bite_history_page.dart';
import 'dart:math' show max;

class DailyFoodTimeline extends StatefulWidget {
  const DailyFoodTimeline({super.key, required this.summaries});
  final List<DailyBiteSummary> summaries;

  @override
  State<DailyFoodTimeline> createState() => _DailyFoodTimelineState();
}

class _DailyFoodTimelineState extends State<DailyFoodTimeline>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  int _selectedIndex = -1;
  // Fixed to 7 days for Weekly History
  final int _rangeDays = 7;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // Build day-keyed buckets for selected range (7 / 30 / 90 days)
    final biteBuckets = <DateTime, int>{};
    final timeBuckets = <DateTime, double>{};
    for (var i = _rangeDays - 1; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      biteBuckets[d] = 0;
      timeBuckets[d] = 0.0;
    }

    // Fill from daily_summaries (authoritative source)
    for (final s in widget.summaries) {
      final d = DateTime(s.date.year, s.date.month, s.date.day);
      if (biteBuckets.containsKey(d)) {
        biteBuckets[d] = (biteBuckets[d] ?? 0) + s.totalBites;
        timeBuckets[d] = (timeBuckets[d] ?? 0) + s.totalDurationMin;
      }
    }

    final keys = biteBuckets.keys.toList()..sort();
    if (_selectedIndex == -1 && keys.isNotEmpty) {
      _selectedIndex = keys.length - 1;
    }

    double minutesMax = timeBuckets.values.fold(
      0.0,
      (a, b) => a > b ? a : b.toDouble(),
    );
    double bitesMax = biteBuckets.values.fold(
      0.0,
      (a, b) => a > b ? a : b.toDouble(),
    );
    if (minutesMax <= 0) minutesMax = 10;
    if (bitesMax <= 0) bitesMax = 10;
    final minutesNiceMax = (minutesMax / 10).ceil() * 10;
    final bitesNiceMax = (bitesMax / 5).ceil() * 5;
    final scaleFactor = minutesNiceMax / bitesNiceMax.clamp(1, 99999);

    final timeSpots = <FlSpot>[];
    final biteSpotsScaled = <FlSpot>[];
    for (var i = 0; i < keys.length; i++) {
      final d = keys[i];
      timeSpots.add(FlSpot(i.toDouble(), (timeBuckets[d] ?? 0).toDouble()));
      biteSpotsScaled.add(
        FlSpot(i.toDouble(), (biteBuckets[d] ?? 0) * scaleFactor),
      );
    }

    String dayLabel(DateTime d) {
      const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return names[d.weekday - 1];
    }

    String fullDateLabel(DateTime d) {
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${dayLabel(d)}, ${d.day} ${months[d.month - 1]}';
    }

    final interval = max(2, (minutesNiceMax / 5).round());

    // Use PremiumGlassCard instead of generic Container
    return PremiumGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Weekly History',
                    style: GoogleFonts.figtree(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _LegendDot(color: AppTheme.caramel, label: 'Time (min)'),
                      const SizedBox(width: 12),
                      _LegendDot(color: AppTheme.honey, label: 'Bites'),
                    ],
                  ),
                ],
              ),
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const BiteHistoryPage(),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.caramel.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppTheme.caramel.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.history_rounded,
                        size: 16,
                        color: AppTheme.caramel,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'History',
                        style: GoogleFonts.figtree(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.caramel,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Chart — LayoutBuilder maps tap pixel → day index (works even on zero-value days)
          LayoutBuilder(
            builder: (context, constraints) {
              final chartWidth = constraints.maxWidth;
              final xRange = (keys.length - 1) + 0.6;

              void onTapX(double localX) {
                if (keys.isEmpty) return;
                final ratio = (localX / chartWidth).clamp(0.0, 1.0);
                final xValue = ratio * xRange - 0.3;
                final idx = xValue.round().clamp(0, keys.length - 1);
                setState(() => _selectedIndex = idx);
              }

              return Column(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => onTapX(d.localPosition.dx),
                    onHorizontalDragUpdate: (d) => onTapX(d.localPosition.dx),
                    child: AnimatedBuilder(
                      animation: _animationController,
                      builder: (context, child) {
                        return SizedBox(
                          height: 220,
                          child: RepaintBoundary(
                            child: LineChart(
                              LineChartData(
                              minX: -0.3,
                              maxX: (keys.length - 1) + 0.3,
                              minY: 0,
                              maxY: minutesNiceMax.toDouble(),
                              gridData: FlGridData(
                                show: true,
                                drawVerticalLine: false,
                                horizontalInterval: interval.toDouble(),
                                getDrawingHorizontalLine: (value) => FlLine(
                                  color: Theme.of(
                                    context,
                                  ).dividerColor.withValues(alpha: 0.1),
                                  strokeWidth: 1,
                                  dashArray: [5, 5],
                                ),
                              ),
                              borderData: FlBorderData(show: false),
                              titlesData: FlTitlesData(
                                leftTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                                rightTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                                topTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                                bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    reservedSize: 42,
                                    interval: 1,
                                    getTitlesWidget: (value, meta) {
                                      final idx = value.round();
                                      if (idx < 0 || idx >= keys.length) {
                                        return const SizedBox.shrink();
                                      }
                                      if ((value - idx).abs() > 0.01) {
                                        return const SizedBox.shrink();
                                      }
                                      final isSelected = _selectedIndex == idx;
                                      final d = keys[idx];
                                      final label = dayLabel(d);
                                      return SideTitleWidget(
                                        axisSide: meta.axisSide,
                                        space: 14,
                                        child: Text(
                                          label,
                                          style: GoogleFonts.figtree(
                                            fontSize: 13,
                                            fontWeight: isSelected
                                                ? FontWeight.bold
                                                : FontWeight.w500,
                                            color: isSelected
                                                ? AppTheme.caramel
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withValues(alpha: 0.45),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              lineTouchData: LineTouchData(enabled: false),
                              lineBarsData: [
                                LineChartBarData(
                                  spots: timeSpots
                                      .take(
                                        (timeSpots.length *
                                                _animationController.value)
                                            .ceil(),
                                      )
                                      .toList(),
                                  isCurved: true,
                                  curveSmoothness: 0.2,
                                  preventCurveOverShooting: true,
                                  color: AppTheme.caramel,
                                  barWidth: 3,
                                  isStrokeCapRound: true,
                                  dotData: FlDotData(
                                    show: true,
                                    getDotPainter:
                                        (spot, percent, barData, index) {
                                          final isSelected =
                                              index == _selectedIndex;
                                          return FlDotCirclePainter(
                                            radius: isSelected ? 6 : 0,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.surface,
                                            strokeWidth: isSelected ? 3 : 0,
                                            strokeColor: AppTheme.caramel,
                                          );
                                        },
                                  ),
                                  belowBarData: BarAreaData(
                                    show: true,
                                    gradient: LinearGradient(
                                      colors: [
                                        AppTheme.caramel.withValues(alpha: 0.2),
                                        AppTheme.caramel.withValues(alpha: 0.0),
                                      ],
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                    ),
                                  ),
                                ),
                                LineChartBarData(
                                  spots: biteSpotsScaled
                                      .take(
                                        (biteSpotsScaled.length *
                                                _animationController.value)
                                            .ceil(),
                                      )
                                      .toList(),
                                  isCurved: true,
                                  curveSmoothness: 0.2,
                                  preventCurveOverShooting: true,
                                  color: AppTheme.honey,
                                  barWidth: 3,
                                  isStrokeCapRound: true,
                                  dotData: FlDotData(
                                    show: true,
                                    getDotPainter:
                                        (spot, percent, barData, index) {
                                          final isSelected =
                                              index == _selectedIndex;
                                          return FlDotCirclePainter(
                                            radius: isSelected ? 6 : 0,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.surface,
                                            strokeWidth: isSelected ? 3 : 0,
                                            strokeColor: AppTheme.honey,
                                          );
                                        },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                    ),
                  ),

                  const SizedBox(height: 20),

                  if (_selectedIndex >= 0 && _selectedIndex < keys.length)
                    _buildDetailSection(
                      context,
                      keys[_selectedIndex],
                      timeBuckets[keys[_selectedIndex]] ?? 0,
                      biteBuckets[keys[_selectedIndex]] ?? 0,
                      fullDateLabel(keys[_selectedIndex]),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDetailSection(
    BuildContext context,
    DateTime date,
    double minutes,
    int bites,
    String dateLabel,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              dateLabel,
              style: GoogleFonts.figtree(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DetailItem(
                value: '${minutes.toInt()}m',
                label: 'Duration',
                color: AppTheme.caramel,
              ),
              Container(
                height: 24,
                width: 1,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                color: Theme.of(context).dividerColor,
              ),
              _DetailItem(
                value: '$bites',
                label: 'Bites',
                color: AppTheme.honey,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailItem extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _DetailItem({
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          value,
          style: GoogleFonts.figtree(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: GoogleFonts.figtree(
            fontSize: 12,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.45),
          ),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 4),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.figtree(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}
