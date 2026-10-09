// insights_controller.dart — view-model for the Insights dashboard.
//
// A ChangeNotifier that assembles everything the Insights UI shows: the last
// meal summary, bite events, temperature/tremor metrics, device health,
// environment, trends, and daily bite/tremor summaries. It pulls historical
// data through an InsightsRepository and blends in live values from
// UnifiedDataService (subscribing to its telemetry streams), triggers a one-time
// cloud restore when local data is empty, and periodically refreshes tremor.
// The presentation layer only reads from this controller.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../domain/insights_repository.dart';
import '../domain/models.dart';
import '../domain/suggestion_engine.dart';
import '../../ai_lab/domain/services/personalized_eating_model.dart';
import '../infrastructure/live_insights_repository.dart';
import '../domain/services/unified_data_service.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../core/models/cloud_sync_result.dart';

class InsightsController with ChangeNotifier {
  final InsightsRepository _repository;
  UnifiedDataService? _unifiedDataService; // Added to blend live data
  Timer? _tremorRefreshTimer;
  bool _cloudRestoreAttempted = false;

  InsightsController(this._repository);

  MealSummary? _summary;
  List<BiteEvent> _bites = const [];
  TemperatureStats? _temperature;
  TremorMetrics? _tremor;
  DeviceHealth? _deviceHealth;
  EnvironmentData? _environment;
  TrendData? _trends;
  List<DailyBiteSummary> _dailySummaries = const [];
  List<DailyTremorSummary> _tremorSummaries = const [];
  List<Suggestion> _suggestions = const [];

  StreamSubscription? _tempSub;
  StreamSubscription? _tremorSub;
  StreamSubscription? _healthSub;
  StreamSubscription? _envSub;
  StreamSubscription? _authSub;

  MealSummary? get summary => _summary;
  List<BiteEvent> get bites => _bites;
  TemperatureStats? get temperature => _temperature;
  TremorMetrics? get tremor => _tremor;
  DeviceHealth? get deviceHealth => _deviceHealth;
  EnvironmentData? get environment => _environment;
  TrendData? get trends => _trends;

  List<DailyBiteSummary> get dailySummaries {
    // If we have live data, dynamically update or inject today's summary
    if (_unifiedDataService != null) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      // Per-spoon: blend live counts for the SELECTED spoon only, matching the
      // per-spoon history rows the repository now returns.
      final liveBites = _unifiedDataService!.selectedTotalBites;

      // Build live meal map (selected spoon)
      final liveMealBites = {
        'Breakfast': _unifiedDataService!.selectedBreakfastBites,
        'Lunch': _unifiedDataService!.selectedLunchBites,
        'Dinner': _unifiedDataService!.selectedDinnerBites,
        'Snacks': _unifiedDataService!.selectedSnackBites,
      };

      // Find today's summary index
      final todayIdx = _dailySummaries.indexWhere(
        (s) =>
            s.date.year == now.year &&
            s.date.month == now.month &&
            s.date.day == now.day,
      );

      if (todayIdx != -1) {
        // Update existing today entry with live data.
        // Keep totalBites and mealBites consistent: use whichever source has a
        // higher total so the graph bar and the table rows always match.
        final current = _dailySummaries[todayIdx];
        final updatedList = List<DailyBiteSummary>.from(_dailySummaries);
        final liveMealTotal = liveMealBites.values.fold(0, (a, b) => a + b);
        final useLive = liveMealTotal >= current.totalBites;
        updatedList[todayIdx] = current.copyWith(
          totalBites: useLive ? liveMealTotal : current.totalBites,
          mealBites: useLive ? liveMealBites : current.mealBites,
        );
        return updatedList;
      } else if (liveBites > 0) {
        // No today entry in DB yet — create one from live data
        final liveToday = DailyBiteSummary(
          date: today,
          totalBites: liveBites,
          avgMealDurationMin: 0,
          totalDurationMin: 0,
          avgPaceBpm: _unifiedDataService!.eatingSpeedBpm,
          mealBites: liveMealBites,
        );
        return [..._dailySummaries, liveToday];
      }
    }
    return _dailySummaries;
  }

  List<DailyTremorSummary> get tremorSummaries => _tremorSummaries;

  /// Suggestions SuggestionEngine derived from this spoon's recent meals and
  /// the per-person baseline. Empty, or a single "no meals yet" entry, when
  /// the measurements do not support saying anything — the engine is allowed
  /// to stay quiet and the UI must respect that rather than filling the gap.
  List<Suggestion> get suggestions => _suggestions;

  /// Tracks the spoon the loaded history belongs to, so a spoon switch triggers
  /// a reload rather than just a repaint of the wrong spoon's data.
  String? _lastSpoonKey;

  void setUnifiedDataService(UnifiedDataService service) {
    _unifiedDataService = service;
    _lastSpoonKey = service.selectedSpoonKey;
    _unifiedDataService?.addListener(_onUnifiedDataChanged);
  }

  void _onUnifiedDataChanged() {
    // When the user selects a different spoon, EVERY insights surface must
    // reload for that spoon (history is per-spoon now). A local switch never
    // needs a cloud restore.
    final key = _unifiedDataService?.selectedSpoonKey ?? '';
    if (key != _lastSpoonKey) {
      _lastSpoonKey = key;
      unawaited(fetchHistory(90, allowCloudRestore: false));
    }
    notifyListeners();
  }

  void resetForUserChange() {
    _summary = null;
    _bites = const [];
    _temperature = null;
    _tremor = null;
    _deviceHealth = null;
    _environment = null;
    _trends = null;
    _dailySummaries = const [];
    _tremorSummaries = const [];
    _suggestions = const [];
    _cloudRestoreAttempted = false;
    notifyListeners();
  }

  Future<void> init() async {
    // If the repository supports async initialisation (backfill), await it FIRST
    // so daily_summaries are complete before we read from them in fetchHistory.
    final repo = _repository;
    if (repo is LiveInsightsRepository) {
      await repo.initAsync();
    }
    await fetchHistory(90); // Fetch all 3 months so details pages have data
    _subscribeLive();

    // Re-fetch history once Firebase Auth is fully restored (cold-start race fix).
    // On the initial fetchHistory() above, LiveInsightsRepository._currentUserId may
    // return '' because Firebase hasn't restored the session yet → empty results.
    // This listener fires ~200ms later with the real UID so historical data shows up.
    _authSub?.cancel();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user == null) {
        resetForUserChange();
        return;
      }
      debugPrint(
        '[IC] Auth restored (uid=${user.uid}), backfilling + re-fetching history...',
      );
      _cloudRestoreAttempted = false;
      _unifiedDataService?.resetForUserChange();
      final repo = _repository;
      if (repo is LiveInsightsRepository) {
        await repo.initAsync();
      }
      await fetchHistory(90);
    });
    // A meal ending is what changes the suggestions, and the per-person model
    // is the thing that learns about it (recordMeal notifies at meal end).
    // Without this the Insights tab would keep showing advice derived from the
    // meal before last until something else forced a refetch.
    PersonalizedEatingModel()
      ..removeListener(_onProfileChanged)
      ..addListener(_onProfileChanged);

    // Refresh tremor summaries every 30 seconds for real-time table updates
    _tremorRefreshTimer?.cancel();
    _tremorRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshTremorSummaries();
    });
  }

  Future<void> _refreshTremorSummaries() async {
    final now = DateTime.now();
    final start = now.subtract(const Duration(days: 90));
    try {
      _tremorSummaries = await _repository.getDailyTremorSummaries(
        start: start,
        end: now,
      );
      notifyListeners();
    } catch (e) {
      // H6: a DB error must not be allowed to LOOK like "no tremor readings
      // this range" — leave the last-known-good _tremorSummaries in place
      // rather than clearing it. This also keeps a failure inside a 30s
      // Timer.periodic callback from becoming an uncaught async error.
      if (kDebugMode) {
        print('[IC] Tremor summary refresh failed, keeping stale data: $e');
      }
    }
  }

  Future<void> fetchHistory(int days, {bool allowCloudRestore = true}) async {
    _summary = await _repository.getLastMealSummary(); // Always latest

    final now = DateTime.now();
    final historyStart = now.subtract(Duration(days: days));

    Future<void> loadRange() async {
      try {
        _dailySummaries = await _repository.getDailyBiteSummaries(
          start: historyStart,
          end: now,
        );
        _tremorSummaries = await _repository.getDailyTremorSummaries(
          start: historyStart,
          end: now,
        );
        _bites = await _repository.getBiteEvents(
          start: historyStart,
          end: now,
        );
      } catch (e) {
        // H6: on a DB error, leave whichever of the three fields didn't reach
        // its await showing its PREVIOUS value rather than an empty list —
        // an empty range here reads as "patient recorded nothing", which the
        // isEmpty check just below already treats as meaningful (it triggers
        // a cloud restore). A caught error must not participate in that
        // signal, or a persistent local failure gets silently reinterpreted
        // as "nothing local, go fetch the cloud copy" forever.
        if (kDebugMode) {
          print('[IC] loadRange failed, keeping previous data: $e');
        }
        rethrow;
      }
    }

    try {
      await loadRange();
    } catch (e) {
      // Genuinely failed (not just empty) — don't let the cloud-restore
      // fallback below misread this as "no local data, try the cloud".
      notifyListeners();
      return;
    }

    // If ANY section of the range is empty locally (eating OR tremor), pull
    // from the server once per session. Covers the case where the user has
    // recent local meals but 3-month-old historical data was never synced
    // to this device.
    if (allowCloudRestore &&
        (_dailySummaries.isEmpty || _tremorSummaries.isEmpty) &&
        !_cloudRestoreAttempted) {
      if (kDebugMode) {
        print(
          '[IC] No local data for $days-day range — restoring from cloud...',
        );
      }
      final result = await SyncService().restoreFromCloud();
      if (result.completed) _cloudRestoreAttempted = true;
      try {
        await loadRange();
      } catch (e) {
        // Same guard as the first attempt above — post-restore retry failing
        // must not fall through to notifyListeners() with a half-updated
        // state read as "confirmed empty".
      }
    }

    await _refreshSuggestions();

    notifyListeners();
  }

  bool _suggestionRefreshInFlight = false;

  void _onProfileChanged() {
    // The model notifies for hand preference and persistence too, not only for
    // a finished meal, so coalesce: one refresh at a time, and the listener
    // never awaits.
    if (_suggestionRefreshInFlight) return;
    unawaited(() async {
      _suggestionRefreshInFlight = true;
      try {
        await _refreshSuggestions();
        // The model is a singleton that outlives this controller, so the
        // screen can be torn down while this read is in flight.
        if (!_disposed) notifyListeners();
      } finally {
        _suggestionRefreshInFlight = false;
      }
    }());
  }

  /// Re-derives [suggestions] from the spoon's recent meals.
  ///
  /// Reads per-meal bite timings rather than the daily rollups the charts use,
  /// because every microstructure measure the engine relies on — satiation,
  /// pause structure, within-meal steadiness drift, cooling rate — only exists
  /// at the level of one meal's bite sequence. A rollup has already averaged
  /// them away.
  Future<void> _refreshSuggestions() async {
    final key = _unifiedDataService?.selectedSpoonKey ?? '';
    try {
      final reports = await _repository.getRecentMealReports(
        limit: _suggestionMealWindow,
      );
      _suggestions = SuggestionEngine.build(
        recentMeals: reports,
        profile:
            key.isEmpty ? null : PersonalizedEatingModel().profileFor(key),
      );
    } catch (e) {
      // Same reasoning as loadRange: a failed read is not evidence that the
      // person has eaten nothing, and the engine's "no meals recorded yet"
      // card would claim exactly that. Keep the last good list.
      if (kDebugMode) {
        print('[IC] Suggestion refresh failed, keeping previous list: $e');
      }
    }
  }

  /// Meals the engine looks back over. Its trend rule needs
  /// [SuggestionEngine.minMealsForTrend]; more than this and a fortnight-old
  /// meal starts dragging on a line meant to describe the current week.
  static const int _suggestionMealWindow = 10;

  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;
  Future<CloudSyncResult>? _manualSyncInFlight;

  /// Manual "sync now" — pulls the user's full meal/bite history from the
  /// cloud and reloads the local summaries. Used by the sync buttons on the
  /// tremor and eating history pages. Returns the number of meals
  /// restored/updated, or null if the sync failed (offline, no auth, server
  /// error). Safe to call repeatedly; concurrent calls are coalesced.
  Future<CloudSyncResult> syncFromCloud({int days = 90}) async {
    final pending = _manualSyncInFlight;
    if (pending != null) return pending;

    final operation = _syncFromCloudOnce(days);
    _manualSyncInFlight = operation;
    try {
      return await operation;
    } finally {
      if (identical(_manualSyncInFlight, operation)) {
        _manualSyncInFlight = null;
      }
    }
  }

  Future<CloudSyncResult> _syncFromCloudOnce(int days) async {
    _isSyncing = true;
    notifyListeners();
    try {
      final result = await SyncService().restoreFromCloud();
      await fetchHistory(days, allowCloudRestore: false);
      if (result.completed) _cloudRestoreAttempted = true;
      return result;
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  void _subscribeLive() {
    _tempSub = _repository.live.temperature$.listen((t) {
      _temperature = t;
      notifyListeners();
    });
    _tremorSub = _repository.live.tremor$.listen((tr) {
      _tremor = tr;
      notifyListeners();
    });
    _healthSub = _repository.live.deviceHealth$.listen((h) {
      _deviceHealth = h;
      notifyListeners();
    });
    _envSub = _repository.live.environment$.listen((e) {
      _environment = e;
      notifyListeners();
    });
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _tremorRefreshTimer?.cancel();
    _tempSub?.cancel();
    _tremorSub?.cancel();
    _healthSub?.cancel();
    _envSub?.cancel();
    _authSub?.cancel();
    _unifiedDataService?.removeListener(_onUnifiedDataChanged);
    PersonalizedEatingModel().removeListener(_onProfileChanged);
    super.dispose();
  }

  /// Fetch detailed meal records for a specific date (for analysis page)
  Future<List<MealSummary>> getMealsForDate(DateTime date) async {
    return _repository.getMealsForDate(date);
  }

  /// Fetch tremor data for a specific date range (for history page).
  /// Falls back to a one-per-session cloud restore when the local DB has
  /// nothing for the range — mirrors fetchHistory's fallback so the tremor
  /// page isn't empty on a fresh install while the server has data.
  Future<List<DailyTremorSummary>> fetchTremorDataForRange(int days) async {
    final now = DateTime.now();
    final start = now.subtract(Duration(days: days - 1));

    var summaries = await _repository.getDailyTremorSummaries(
      start: start,
      end: now,
    );

    if (summaries.isEmpty && !_cloudRestoreAttempted) {
      if (kDebugMode) {
        print(
          '[IC] No local tremor data for $days-day range — restoring from cloud...',
        );
      }
      final result = await SyncService().restoreFromCloud();
      if (result.completed) _cloudRestoreAttempted = true;
      summaries = await _repository.getDailyTremorSummaries(
        start: start,
        end: now,
      );
    }

    return summaries;
  }
}
