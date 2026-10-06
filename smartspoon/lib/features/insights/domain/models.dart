// models.dart — immutable value objects for the Insights feature.
//
// Plain, immutable data classes the repository produces and the dashboard
// consumes: MealSummary, BiteEvent, TemperatureStats, TremorMetrics,
// DeviceHealth, EnvironmentData, TrendData, and the DailyBiteSummary /
// DailyTremorSummary rollups. No logic or I/O — just typed, view-ready shapes.
import 'package:flutter/foundation.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';

@immutable
class MealSummary {
  final int totalBites;
  final double eatingPaceBpm; // bites per minute
  final double tremorIndex; // 0–3 scale
  final DateTime? lastMealStart;
  final DateTime? lastMealEnd;
  final String? mealType; // e.g. "Breakfast"
  final double? durationMinutes; // Pre-calculated duration
  final double? avgFoodTempC; // Average food temperature in °C
  final String? mealUuid;

  /// Hand steadiness for this meal, 0–100, as stored by the model. Null for
  /// meals recorded before it, which must not be drawn as a steady meal.
  final double? steadyPct;

  /// Seconds of the meal the model measured.
  final int measuredSeconds;

  const MealSummary({
    required this.totalBites,
    required this.eatingPaceBpm,
    required this.tremorIndex,
    this.lastMealStart,
    this.lastMealEnd,
    this.mealType,
    this.durationMinutes,
    this.avgFoodTempC,
    this.mealUuid,
    this.steadyPct,
    this.measuredSeconds = 0,
  });
}

@immutable
class BiteEvent {
  final int index;
  final DateTime timestamp;
  final double foodTempC;
  final double tremorMagnitude; // 0–3 severity index near bite
  final BiteEventType type;

  const BiteEvent({
    required this.index,
    required this.timestamp,
    required this.foodTempC,
    required this.tremorMagnitude,
    required this.type,
  });
}

enum BiteEventType { valid, missed, anomaly }

@immutable
class TemperatureStats {
  final double foodTempC;
  final double heaterTempC;

  const TemperatureStats({required this.foodTempC, required this.heaterTempC});
}

@immutable
class TremorMetrics {
  /// Index bands for the 0-3 scale, DERIVED from the single set of steadiness
  /// percentage bands in eating_insights.dart so the screens cannot disagree
  /// about the same reading.
  ///
  /// They used to be 0.6 / 1.4, chosen independently of the AI Lab's 90% / 75%
  /// percentage bands, and the two never matched: index 0.6 is 80% steady and
  /// index 1.4 is 53% steady. So 82% read "Mostly steady" on AI Lab but
  /// "Steady hand" on Home, and 74% was red "Frequent rhythmic shaking" on AI
  /// Lab but only "Some shake" on Home. Same number, three different verdicts.
  ///
  /// index = 3 * (100 - steadyPct) / 100, so 90% -> 0.30 and 75% -> 0.75.
  ///
  /// Compare with `<=`, not `<`. The percentage side is inclusive
  /// (`pct >= 90` is Steady), and the index runs the other way, so a
  /// strict `<` put exactly 90% / 75% in different bands on the two
  /// scales — the one gap left after the thresholds were unified.
  static const double moderateThreshold =
      3.0 * (100.0 - kSteadyFromPct) / 100.0;
  static const double highThreshold =
      3.0 * (100.0 - kShakyBelowPct) / 100.0;

  final bool isMeasured;
  final double currentMagnitude; // 0–3 repeated-movement pattern index
  final double peakFrequencyHz;
  final double confidence;
  final double sampleDurationSeconds;
  final TremorLevel level;

  const TremorMetrics({
    this.isMeasured = true,
    required this.currentMagnitude,
    required this.peakFrequencyHz,
    this.confidence = 1.0,
    this.sampleDurationSeconds = 0.0,
    required this.level,
  });
}

enum TremorLevel { low, moderate, high }

@immutable
class TrendDataPoint<T extends num> {
  final DateTime time;
  final T value;

  const TrendDataPoint(this.time, this.value);
}

@immutable
class TrendData {
  final List<TrendDataPoint<int>> bitesPerMeal;
  final List<TrendDataPoint<double>> avgMealDurationMin;
  final List<TrendDataPoint<double>> tremorIndexOverTime;

  const TrendData({
    required this.bitesPerMeal,
    required this.avgMealDurationMin,
    required this.tremorIndexOverTime,
  });
}

@immutable
class DailyBiteSummary {
  final DateTime date;
  final int totalBites;
  final double avgMealDurationMin;
  final double totalDurationMin;
  final double avgPaceBpm;
  final Map<String, int> mealBites;

  const DailyBiteSummary({
    required this.date,
    required this.totalBites,
    required this.avgMealDurationMin,
    required this.totalDurationMin,
    required this.avgPaceBpm,
    this.mealBites = const {},
  });

  DailyBiteSummary copyWith({
    DateTime? date,
    int? totalBites,
    double? avgMealDurationMin,
    double? totalDurationMin,
    double? avgPaceBpm,
    Map<String, int>? mealBites,
  }) {
    return DailyBiteSummary(
      date: date ?? this.date,
      totalBites: totalBites ?? this.totalBites,
      avgMealDurationMin: avgMealDurationMin ?? this.avgMealDurationMin,
      totalDurationMin: totalDurationMin ?? this.totalDurationMin,
      avgPaceBpm: avgPaceBpm ?? this.avgPaceBpm,
      mealBites: mealBites ?? this.mealBites,
    );
  }
}

@immutable
class DailyTremorSummary {
  final DateTime date;
  final int sampleCount;
  final int rhythmicSampleCount;
  final double avgMagnitude;
  final double avgFrequencyHz;
  final TremorLevel dominantLevel;
  final Map<String, int>?
  tremorLevelCounts; // {'low': 10, 'moderate': 5, 'high': 2}
  final Map<String, DailyTremorSummary>? mealBreakdown;

  /// Share of the measured time with no repeated rhythm, 0–100 — the number
  /// the user reads. Null for days recorded before the model stored it.
  final double? steadyPct;

  /// Seconds of that day the model actually measured. "94 % steady" from a few
  /// seconds and from half an hour are not the same claim.
  final int measuredSeconds;

  /// True when the day's movement numbers came from the AI Lab model, so the
  /// UI can say so instead of guessing from missing fields.
  final bool fromModel;

  const DailyTremorSummary({
    required this.date,
    this.sampleCount = 0,
    this.rhythmicSampleCount = 0,
    required this.avgMagnitude,
    required this.avgFrequencyHz,
    required this.dominantLevel,
    this.tremorLevelCounts,
    this.mealBreakdown,
    this.steadyPct,
    this.measuredSeconds = 0,
    this.fromModel = false,
  });
}

@immutable
class DeviceHealth {
  const DeviceHealth({
    required this.batteryPercent,
    required this.voltage,
    required this.chargeCycles,
    required this.sensorsHealthy,
    required this.batteryStatus,
    required this.lastSync,
  });

  final int batteryPercent; // 0-100
  final double voltage;
  final int chargeCycles;
  final bool sensorsHealthy;
  final String batteryStatus;
  final DateTime lastSync;

  factory DeviceHealth.empty() => DeviceHealth(
    batteryPercent: 0,
    voltage: 0.0,
    chargeCycles: 0,
    sensorsHealthy: false,
    batteryStatus: 'Unknown',
    lastSync: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

@immutable
class EnvironmentData {
  final double ambientTempC;
  final double humidityPercent;
  final double pressureHpa;

  const EnvironmentData({
    required this.ambientTempC,
    required this.humidityPercent,
    required this.pressureHpa,
  });
}
