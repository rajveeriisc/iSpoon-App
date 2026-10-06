// insights_repository.dart — abstract data-source contract for the Insights feature.
//
// Defines the interfaces the controller depends on, decoupling it from any
// concrete data source: LiveTelemetrySource exposes real-time streams
// (temperature$, tremor$, deviceHealth$, environment$), while InsightsRepository
// exposes historical queries (last meal summary, bite events, trends, daily
// bite/tremor summaries, meals-for-date). The live implementation lives in
// infrastructure/live_insights_repository.dart.
import 'dart:async';
import 'models.dart';

abstract class LiveTelemetrySource {
  Stream<TemperatureStats> get temperature$;
  Stream<TremorMetrics> get tremor$;
  Stream<DeviceHealth> get deviceHealth$;
  Stream<EnvironmentData> get environment$;
}

abstract class InsightsRepository {
  LiveTelemetrySource get live;

  Future<MealSummary> getLastMealSummary();
  Future<List<BiteEvent>> getBiteEvents({
    required DateTime start,
    required DateTime end,
  });
  Future<TrendData> getTrends({required DateTime start, required DateTime end});
  Future<List<DailyBiteSummary>> getDailyBiteSummaries({
    required DateTime start,
    required DateTime end,
  });
  Future<List<DailyTremorSummary>> getDailyTremorSummaries({
    required DateTime start,
    required DateTime end,
  });

  /// Fetch detailed meal records for a specific date (for analysis page)
  Future<List<MealSummary>> getMealsForDate(DateTime date);
}
