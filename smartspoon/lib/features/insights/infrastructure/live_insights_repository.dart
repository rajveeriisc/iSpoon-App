// live_insights_repository.dart — concrete InsightsRepository backed by real data.
//
// Implements the domain contract for production: RealLiveTelemetrySource adapts
// UnifiedDataService's ChangeNotifier updates into the temperature/tremor/health/
// environment broadcast streams, and the repository answers historical queries
// (meal summaries, bite events, trends, daily rollups) from the local SQLite
// store via DatabaseService. This is the wiring between the Insights UI layer
// and the app's actual live + stored data.
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:smartspoon/features/insights/index.dart';
import 'package:smartspoon/core/services/database_service.dart';

/// Real implementation of LiveTelemetrySource that adapts UnifiedDataService
class RealLiveTelemetrySource implements LiveTelemetrySource {
  final UnifiedDataService _dataService;

  final _tempCtrl = StreamController<TemperatureStats>.broadcast();
  final _tremorCtrl = StreamController<TremorMetrics>.broadcast();
  final _healthCtrl = StreamController<DeviceHealth>.broadcast();
  final _envCtrl = StreamController<EnvironmentData>.broadcast();

  RealLiveTelemetrySource(this._dataService) {
    // Listen to UnifiedDataService updates and push to streams
    _dataService.addListener(_onDataChanged);
  }

  void _onDataChanged() {
    // 1. Temperature
    _tempCtrl.add(
      TemperatureStats(
        foodTempC: _dataService.foodTempC,
        heaterTempC: _dataService.heaterTempC,
      ),
    );

    // 2. Tremor
    final result = _dataService.lastTremorResult;

    final magnitude = result.score;
    TremorLevel level;
    if (magnitude <= TremorMetrics.moderateThreshold) {
      level = TremorLevel.low;
    } else if (magnitude <= TremorMetrics.highThreshold) {
      level = TremorLevel.moderate;
    } else {
      level = TremorLevel.high;
    }

    _tremorCtrl.add(
      TremorMetrics(
        isMeasured:
            result.measured && result.isFresh && result.confidence >= 0.5,
        currentMagnitude: magnitude,
        peakFrequencyHz: result.detected ? result.frequency : 0.0,
        confidence: result.confidence,
        sampleDurationSeconds: result.windowDurationMs / 1000.0,
        level: level,
      ),
    );

    // 3. Device Health
    _healthCtrl.add(
      DeviceHealth(
        batteryPercent: _dataService.batteryLevel,
        voltage: 3.7, // Fixed for now
        chargeCycles: 0,
        sensorsHealthy: true,
        batteryStatus: _dataService.batteryLevel > 20 ? 'Good' : 'Low',
        lastSync: DateTime.now(),
      ),
    );

    // 4. Environment (Mock for now as we don't have sensors)
    _envCtrl.add(
      const EnvironmentData(
        ambientTempC: 25.0,
        humidityPercent: 50.0,
        pressureHpa: 1013.0,
      ),
    );
  }

  void dispose() {
    _dataService.removeListener(_onDataChanged);
    _tempCtrl.close();
    _tremorCtrl.close();
    _healthCtrl.close();
    _envCtrl.close();
  }

  @override
  Stream<TemperatureStats> get temperature$ => _tempCtrl.stream;

  @override
  Stream<TremorMetrics> get tremor$ => _tremorCtrl.stream;

  @override
  Stream<DeviceHealth> get deviceHealth$ => _healthCtrl.stream;

  @override
  Stream<EnvironmentData> get environment$ => _envCtrl.stream;
}

/// Hybrid Repository: Real Live Data + Mock Historical Data
class LiveInsightsRepository implements InsightsRepository {
  late final RealLiveTelemetrySource _live;
  final UnifiedDataService _dataService;

  LiveInsightsRepository(this._dataService) {
    _live = RealLiveTelemetrySource(_dataService);
    // NOTE: async init is exposed via initAsync() so callers can await it.
    // Do NOT call _initData() here — let InsightsController.init() await it.
  }

  /// Reload today's snapshot in UnifiedDataService so home cards reflect reality.
  Future<void> initAsync() async {
    if (_currentUserId.isEmpty) return;
    _dataService.refreshTodaySnapshot();
  }

  @override
  LiveTelemetrySource get live => _live;

  void dispose() {
    _live.dispose();
  }

  // --- Real Offline History Data ---

  final DatabaseService _db = DatabaseService();

  @override
  Future<MealSummary> getLastMealSummary() async {
    // Try to get the latest meal from DB (for the selected spoon).
    final meals = await _db.getMeals(
      userId: _currentUserId,
      limit: 1,
      spoonKey: _spoonFilter,
    );

    if (meals.isNotEmpty) {
      final last = meals.first;
      return MealSummary(
        totalBites: last.totalBites,
        eatingPaceBpm: last.avgPaceBpm ?? 0.0,
        steadyPct: last.steadyPct,
        measuredSeconds: last.measuredSeconds ?? 0,
        tremorIndex: last.tremorIndex ?? 0.0,
        lastMealStart: last.startedAt,
        lastMealEnd: last.endedAt,
      );
    }

    return const MealSummary(totalBites: 0, eatingPaceBpm: 0.0, tremorIndex: 0);
  }

  @override
  Future<List<BiteEvent>> getBiteEvents({
    required DateTime start,
    required DateTime end,
  }) async {
    // Fetch bites for meals in this range
    // For now returning empty or we need a complex query to join meals+bites
    return [];
  }

  @override
  Future<TrendData> getTrends({
    required DateTime start,
    required DateTime end,
  }) async {
    final meals = await _db.getMeals(
      userId: _currentUserId,
      limit: 1000,
      spoonKey: _spoonFilter,
    );

    // Filter by date range
    final rangeMeals = meals
        .where(
          (m) =>
              m.startedAt.isAfter(start.subtract(const Duration(days: 1))) &&
              m.startedAt.isBefore(end.add(const Duration(days: 1))),
        )
        .toList();

    final List<TrendDataPoint<int>> bites = [];
    final List<TrendDataPoint<double>> duration = [];
    final List<TrendDataPoint<double>> tremor = [];

    // Group by day for trends? Or per meal?
    // Usually trends are per day or per meal point. Assuming per meal point for now.
    for (var m in rangeMeals) {
      bites.add(TrendDataPoint<int>(m.startedAt, m.totalBites));
      if (m.durationMinutes != null) {
        duration.add(TrendDataPoint<double>(m.startedAt, m.durationMinutes!));
      }
      if (m.tremorIndex != null) {
        tremor.add(TrendDataPoint<double>(m.startedAt, m.tremorIndex!));
      }
    }

    return TrendData(
      bitesPerMeal: bites,
      avgMealDurationMin: duration,
      tremorIndexOverTime: tremor,
    );
  }

  @override
  Future<List<DailyBiteSummary>> getDailyBiteSummaries({
    required DateTime start,
    required DateTime end,
  }) async {
    // Fast path: read from pre-aggregated daily_summaries table.
    // Falls back to empty list if table doesn't exist yet (new install before first meal).
    final userId = _currentUserId;
    final rows = await _db.getDailySummaries(
      userId: userId,
      start: start,
      end: end,
      spoonKey: _spoonFilter,
    );

    return rows.map((r) {
      final dateStr = r['date'] as String; // "YYYY-MM-DD" local date
      // Parse as LOCAL midnight — DateTime.parse("YYYY-MM-DD") creates UTC midnight
      // which causes day-mismatch in non-UTC timezones (e.g. IST, EST).
      final parts = dateStr.split('-');
      final date = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
      final totalBites = (r['total_bites'] as num?)?.toInt() ?? 0;
      final totalMinutes = (r['total_eating_min'] as num?)?.toDouble() ?? 0.0;
      // Compute bpm from aggregated data: bites / total_minutes.
      // avg_pace_bpm per meal is not stored in daily_summaries, so we derive it.
      final avgPace = (totalMinutes > 0 && totalBites > 0)
          ? totalBites / totalMinutes
          : 0.0;
      return DailyBiteSummary(
        date: date,
        totalBites: totalBites,
        avgMealDurationMin: totalMinutes,
        totalDurationMin: totalMinutes,
        avgPaceBpm: avgPace,
        mealBites: {
          'Breakfast': (r['breakfast_bites'] as num?)?.toInt() ?? 0,
          'Lunch': (r['lunch_bites'] as num?)?.toInt() ?? 0,
          'Dinner': (r['dinner_bites'] as num?)?.toInt() ?? 0,
          'Snacks': (r['snack_bites'] as num?)?.toInt() ?? 0,
        },
      );
    }).toList();
  }

  @override
  Future<List<DailyTremorSummary>> getDailyTremorSummaries({
    required DateTime start,
    required DateTime end,
  }) async {
    // Primary: read pre-aggregated tremor counts from daily_summaries.
    final userId = _currentUserId;
    final rows = await _db.getDailySummaries(
      userId: userId,
      start: start,
      end: end,
      spoonKey: _spoonFilter,
    );

    // Secondary: per-meal-type breakdown — only computed on demand (Tremor History page).
    final mealStats = await _db.getMealTypeTremorStats(
      userId: userId,
      start: start,
      end: end,
      spoonKey: _spoonFilter,
    );
    final Map<String, Map<String, DailyTremorSummary>> breakdowns = {};
    for (final row in mealStats) {
      final dateStr = row['date'] as String;
      final mealType = row['meal_type'] as String? ?? 'Snacks';
      final avgMag = (row['avg_magnitude'] as num?)?.toDouble() ?? 0.0;
      breakdowns.putIfAbsent(dateStr, () => {})[mealType] = DailyTremorSummary(
        date: _parseLocalDate(dateStr),
        sampleCount:
            ((row['low_count'] as num?)?.toInt() ?? 0) +
            ((row['moderate_count'] as num?)?.toInt() ?? 0) +
            ((row['high_count'] as num?)?.toInt() ?? 0),
        rhythmicSampleCount:
            (row['rhythmic_sample_count'] as num?)?.toInt() ?? 0,
        avgMagnitude: avgMag,
        steadyPct: (row['avg_steady_pct'] as num?)?.toDouble(),
        avgFrequencyHz: (row['avg_frequency'] as num?)?.toDouble() ?? 0.0,
        dominantLevel: avgMag <= TremorMetrics.moderateThreshold
            ? TremorLevel.low
            : avgMag <= TremorMetrics.highThreshold
            ? TremorLevel.moderate
            : TremorLevel.high,
        tremorLevelCounts: {
          'low': (row['low_count'] as num?)?.toInt() ?? 0,
          'moderate': (row['moderate_count'] as num?)?.toInt() ?? 0,
          'high': (row['high_count'] as num?)?.toInt() ?? 0,
        },
      );
    }

    return rows.map((r) {
      final dateStr = r['date'] as String;
      final avgMag = (r['avg_tremor_magnitude'] as num?)?.toDouble() ?? 0.0;
      final avgFreq = (r['avg_tremor_frequency'] as num?)?.toDouble() ?? 0.0;
      final level = avgMag <= TremorMetrics.moderateThreshold
          ? TremorLevel.low
          : avgMag <= TremorMetrics.highThreshold
          ? TremorLevel.moderate
          : TremorLevel.high;
      return DailyTremorSummary(
        date: _parseLocalDate(dateStr),
        sampleCount:
            ((r['tremor_low_count'] as num?)?.toInt() ?? 0) +
            ((r['tremor_moderate_count'] as num?)?.toInt() ?? 0) +
            ((r['tremor_high_count'] as num?)?.toInt() ?? 0),
        rhythmicSampleCount: (r['tremor_rhythmic_count'] as num?)?.toInt() ?? 0,
        avgMagnitude: avgMag,
        avgFrequencyHz: avgFreq,
        dominantLevel: level,
        steadyPct: (r['avg_steady_pct'] as num?)?.toDouble(),
        measuredSeconds: (r['measured_seconds'] as num?)?.toInt() ?? 0,
        fromModel: ((r['ai_lab_meals'] as num?)?.toInt() ?? 0) > 0,
        tremorLevelCounts: {
          'low': (r['tremor_low_count'] as num?)?.toInt() ?? 0,
          'moderate': (r['tremor_moderate_count'] as num?)?.toInt() ?? 0,
          'high': (r['tremor_high_count'] as num?)?.toInt() ?? 0,
        },
        mealBreakdown: breakdowns[dateStr],
      );
    }).toList();
  }

  @override
  Future<List<MealSummary>> getMealsForDate(DateTime date) async {
    final startOfDay = DateTime(date.year, date.month, date.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));
    final userId = FirebaseAuth.instance.currentUser?.uid;

    // Use SQL date-range query — filtered by userId to prevent cross-user leakage
    final meals = await _db.getMealsForDateRange(
      startOfDay,
      endOfDay,
      userId: userId,
      spoonKey: _spoonFilter,
    );

    return meals
        .map(
          (m) => MealSummary(
            totalBites: m.totalBites,
            eatingPaceBpm: m.avgPaceBpm ?? 0.0,
            tremorIndex: m.tremorIndex ?? 0.0,
            lastMealStart: m.startedAt,
            lastMealEnd: m.endedAt,
            mealType: m.mealType ?? 'Snack',
            durationMinutes: m.durationMinutes ?? 0.0,
            avgFoodTempC: m.avgFoodTemp,
            mealUuid: m.uuid,
            steadyPct: m.steadyPct,
            measuredSeconds: m.measuredSeconds ?? 0,
          ),
        )
        .toList();
  }

  /// Single source of truth for current user ID across all queries.
  /// Falls back to empty string so DB queries return empty (safe) rather than
  /// leaking data from another user.
  String get _currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';

  /// Per-spoon (per-person) filter applied to EVERY history query, so Insights /
  /// Meals / Movement / Eating-pattern all show only the selected spoon. Null
  /// (no filter) when no spoon is selected/known yet.
  String? get _spoonFilter {
    final key = _dataService.selectedSpoonKey;
    return key.isEmpty ? null : key;
  }

  /// Parse a "YYYY-MM-DD" string as LOCAL midnight.
  /// DateTime.parse("YYYY-MM-DD") creates UTC midnight which causes day-off
  /// mismatches when the device timezone is ahead or behind UTC.
  static DateTime _parseLocalDate(String dateStr) {
    final parts = dateStr.split('-');
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }
}
