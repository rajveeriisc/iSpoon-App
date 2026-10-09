// unified_data_service.dart — central hub blending live BLE data with stored meals.
//
// The app's main real-time data brain (a ChangeNotifier). It owns per-device
// meal sessions (DeviceSessionState), auto-starts/ends sessions from the
// hardware bite counter, writes bites + meals to SQLite, and maintains today's
// aggregates. It fuses live values (battery, temperature, tremor, bite pace)
// from McuBleService/TremorDetectionService with the DB snapshot so the UI shows
// correct numbers whether or not a spoon is connected. Also computes eating
// speed, fires eating/temperature/tremor alerts, persists sessions across app
// kills, and exposes the per-device getters the home/insights cards read.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';
import 'package:smartspoon/core/models/meal.dart';
import 'package:smartspoon/core/models/bite.dart';
import 'package:smartspoon/core/services/database_service.dart';
import 'package:smartspoon/core/services/sync_service.dart';
import 'package:smartspoon/features/devices/index.dart';
import 'package:smartspoon/features/devices/domain/heater_command.dart';
import 'package:smartspoon/features/insights/index.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartspoon/features/notifications/domain/services/in_app_alert_service.dart';
import 'package:smartspoon/features/notifications/domain/services/notification_service.dart';
import 'package:smartspoon/features/notifications/domain/services/smart_reminder_service.dart';
import 'package:smartspoon/features/insights/domain/services/device_session_state.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_service.dart';
import 'package:smartspoon/features/ai_lab/domain/services/personalized_eating_model.dart';
import 'package:smartspoon/features/insights/domain/session_integrity.dart';
import 'package:smartspoon/main.dart' show navigatorKey;
import 'package:smartspoon/core/utils/temperature_format.dart';

/// Unified Data Service - Provides data from insights and real-time BLE
class UnifiedDataService extends ChangeNotifier with WidgetsBindingObserver {
  InsightsController? insightsController;
  final SpoonRuntime _runtime;
  final TremorDetectionService _tremorService;

  // ── AI Lab is the single source of bites and steadiness ─────────────────
  // Three producers used to disagree: the firmware's own bite counter, the
  // app's MotionAnalysisService, and the AI Lab model. Home said one number,
  // AI Lab another. Now every bite this service records comes from the AI Lab
  // model (trained on 8 people; leave-one-person-out F1 0.963), and the tremor
  // index comes from its steadiness measure. The old producers are commented
  // out rather than deleted, right where they used to run.
  //
  // The cost, chosen deliberately: the model only sees bites while the IMU
  // stream is running. With the app closed, or the spoon used away from the
  // phone, nothing is counted at all — the firmware counter is no longer a
  // fallback.
  AiLabService get _aiLab => AiLabService();

  /// Movement numbers for the meal row: the running meal's figures while it
  /// lasts, and the just-finished meal's afterwards (endSession runs after AI
  /// Lab has already closed its meal).
  ({double? steady, double? hz, int seconds}) get _mealMovement {
    final live = _aiLab.mealSteadyPct;
    if (live != null) {
      return (
        steady: live,
        hz: _aiLab.mealRhythmHz,
        // ACTIVE windows: this becomes meals.measured_seconds, and the daily
        // rollup weights each meal's steady_pct by it (see dailySummarySql).
        // Counting windows where the spoon was not moving inflated a meal's
        // weight with time nobody was eating.
        seconds: _aiLab.mealActiveWindowCount,
      );
    }
    return (
      steady: _aiLab.finishedMealSteadyPct,
      hz: _aiLab.finishedMealRhythmHz,
      seconds: _aiLab.finishedMealMeasuredSeconds,
    );
  }
  final MotionAnalysisService _motionService = MotionAnalysisService();

  // Device Sessions
  final Map<String, DeviceSessionState> _sessions = {};

  /// Cached device ID for the currently active meal session.
  /// This prevents session state from being orphaned when BLE disconnects
  /// mid-meal (primaryDeviceId becomes null on disconnect).
  String? _activeSessionDeviceId;

  DeviceSessionState getSession(String deviceId) {
    if (!_sessions.containsKey(deviceId)) {
      _sessions[deviceId] = DeviceSessionState(deviceId);
    }
    return _sessions[deviceId]!;
  }

  /// The device ID to use for session state lookups.
  /// During an active meal session, returns the cached device ID so that a
  /// BLE disconnect doesn't orphan the session data.
  String get _sessionDeviceId =>
      _activeSessionDeviceId ?? primaryDeviceId ?? '';

  String? get primaryDeviceId => _runtime.connectedDeviceId;

  // --- Per-spoon (per-person) attribution -----------------------------------
  // Every paired spoon is a different person (spoon = person), so analytics are
  // bucketed by a STABLE spoon key — the hardware product id — not the volatile
  // BLE address. This is what makes each home card show its OWN spoon's numbers
  // instead of one global total shared by every spoon.

  /// Stable per-spoon key for [deviceId]: the paired spoon's hardware product
  /// id, or the deviceId itself when no product id is known yet. Survives BLE
  /// address rotation and firmware reflash.
  String spoonKeyFor(String deviceId) {
    if (deviceId.isEmpty) return '';
    try {
      final saved =
          SpoonRuntime().previousDevices.where((d) => d.id == deviceId).firstOrNull;
      final pid = saved?.productId;
      if (pid != null && pid.isNotEmpty) return pid;
    } catch (_) {}
    return deviceId;
  }

  /// Per-spoon today aggregates, keyed by spoon_key. Populated by
  /// [_loadTodaySnapshot] from the DB (bites grouped by the owning spoon), so a
  /// disconnected spoon still shows its OWN last data — never another spoon's.
  final Map<String, Map<String, dynamic>> _todayBySpoon = {};

  /// Guards the one-time legacy-meal spoon_key backfill to once per app run.
  bool _spoonBackfillDone = false;

  // --- Selected spoon (home shows ONE spoon at a time) -----------------------
  // The home page is a single selected-spoon view, not a list of every spoon.
  // The user picks a spoon and the WHOLE page follows it — connected or not.
  String? _selectedDeviceId;
  String? get selectedDeviceId => _selectedDeviceId;

  /// Resolve which spoon the home page shows:
  /// 1. If a spoon is ACTUALLY CONNECTED, that spoon ALWAYS takes immediate priority.
  /// 2. If no spoon is currently connected, show the user's last picked / active spoon.
  /// 3. Otherwise fall back to the first paired spoon.
  String selectedDeviceIdAmong(List<String> pairedIds, String? connectedId) {
    // User's explicit pick wins while a switch is in flight. Preferring the
    // still-connected spoon here snapped the chip back to A the moment the
    // user tapped B, which made the switch look stuck and invited a second
    // tap that aborted the first attempt.
    final picked = _selectedDeviceId;
    if (picked != null && picked.isNotEmpty && pairedIds.contains(picked)) {
      return picked;
    }

    if (connectedId != null &&
        connectedId.isNotEmpty &&
        pairedIds.contains(connectedId)) {
      _selectedDeviceId = connectedId;
      SharedPreferences.getInstance().then((p) {
        p.setString('home_selected_device_id', connectedId);
      }).catchError((_) {});
      SmartSpoonBleService().notifyPreferredDevice(connectedId);
      return connectedId;
    }

    return pairedIds.isNotEmpty ? pairedIds.first : '';
  }

  /// User picked a spoon on the home page → the whole page follows it. Persisted.
  Future<void> selectSpoon(String deviceId) async {
    if (deviceId.isEmpty || _selectedDeviceId == deviceId) return;
    _selectedDeviceId = deviceId;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('home_selected_device_id', deviceId);
      // Synchronize with background isolate
      SmartSpoonBleService().notifyPreferredDevice(deviceId);
    } catch (_) {}
  }

  /// The effective selected device id used by EVERY analytics surface (home,
  /// insights, meals, movement, goals): connected spoon takes precedence,
  /// else the explicit pick, else the first paired spoon.
  String get selectedDeviceIdResolved {
    final conn = primaryDeviceId;
    if (conn != null && conn.isNotEmpty) return conn;
    final picked = _selectedDeviceId;
    if (picked != null && picked.isNotEmpty) return picked;
    final paired = SpoonRuntime().previousDevices;
    return paired.isNotEmpty ? paired.first.id : '';
  }

  /// Stable spoon_key of the selected spoon — the filter passed to all history
  /// queries so Insights/Meals/Movement/etc. show ONLY the selected spoon.
  /// Empty when no spoon is known (then queries fall back to unfiltered).
  String get selectedSpoonKey => spoonKeyFor(selectedDeviceIdResolved);

  // Live "today" values for the SELECTED spoon — used by the insights view-model
  // to blend live counts into the daily summary for the right spoon.
  int get selectedTotalBites => totalBitesFor(selectedDeviceIdResolved);
  int get selectedBreakfastBites =>
      breakfastTotalBitesFor(selectedDeviceIdResolved);
  int get selectedLunchBites => lunchTotalBitesFor(selectedDeviceIdResolved);
  int get selectedDinnerBites => dinnerTotalBitesFor(selectedDeviceIdResolved);
  int get selectedSnackBites => snackTotalBitesFor(selectedDeviceIdResolved);
  double get selectedAvgBiteTime => avgBiteTimeFor(selectedDeviceIdResolved);

  /// Restore the last selected spoon (call once at startup).
  Future<void> loadSelectedSpoon() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString('home_selected_device_id');
      if (id != null && id.isNotEmpty) {
        _selectedDeviceId = id;
        notifyListeners();
      }
    } catch (_) {}
  }

  Map<String, dynamic> _todayStatsForDevice(String deviceId) =>
      _todayBySpoon[spoonKeyFor(deviceId)] ?? const {};

  // --- Per-Device Getters ---
  int batteryLevelFor(String deviceId) => _runtime.isConnectedTo(deviceId)
      ? _runtime.batteryPercentFor(deviceId)
      : getSession(deviceId).bgBattery;
  double foodTempCFor(String deviceId) => _runtime.isConnectedTo(deviceId)
      ? _runtime.temperatureFor(deviceId)
      : getSession(deviceId).bgTemperature;
  bool isHeaterOnFor(String deviceId) {
    // The firmware switches the heater off the moment the link drops, and the
    // last status is never cleared — so a disconnected spoon is always "off",
    // whatever its final packet said.
    if (!_runtime.isConnectedTo(deviceId)) return false;
    final status = _runtime.heaterStatusFor(deviceId);
    if (status != null) return status.maintainOn || status.railOn;
    return _localHeaterState;
  }

  String heaterHomeLabelFor(String deviceId) {
    if (!_runtime.isConnectedTo(deviceId)) return 'Off';
    final status = _runtime.heaterStatusFor(deviceId);
    if (status == null) return _localHeaterState ? 'On' : 'Off';
    switch (heaterUiPhase(
      maintainOn: status.maintainOn,
      railOn: status.railOn,
      vbusPresent: status.vbusPresent,
      fault: status.fault,
    )) {
      case HeaterUiPhase.off:
        return 'Off';
      case HeaterUiPhase.heating:
        return 'Heating';
      case HeaterUiPhase.holding:
        return 'Holding';
      case HeaterUiPhase.pausedUsb:
        return 'Paused';
      case HeaterUiPhase.fault:
        return 'Fault';
    }
  }
  bool isSessionActiveFor(String deviceId) =>
      getSession(deviceId).sessionStartTime != null;
  /// Movement reading for [deviceId], 0–3.
  ///
  /// No longer gated on an active meal session: the model reads the spoon's
  /// movement as soon as it streams, and waiting for the session meant Hand
  /// movement sat on "—" until the second bite of a meal. It IS gated on the
  /// spoon the model is following, so one spoon never shows another's reading.
  double tremorIndexFor(String deviceId) {
    if (!hasTremorReadingFor(deviceId)) return 0.0;
    return lastTremorResult.score.clamp(0.0, 3.0);
  }

  /// True when [deviceId] has a reading good enough to show and to store.
  bool hasTremorReadingFor(String deviceId) {
    final active = _aiLab.activeDeviceId;
    if (active != null && deviceId.isNotEmpty && deviceId != active) {
      return false;
    }
    final res = lastTremorResult;
    return res.measured && res.isFresh && res.confidence >= 0.5;
  }

  /// Share of the measured time that carried no rhythmic shake, 0–100, or null
  /// when there is no reading yet. The inverse of the 0–3 index, and the same
  /// number the AI Lab page shows.
  double? steadyPctFor(String deviceId) {
    if (!hasTremorReadingFor(deviceId)) return null;
    return (100.0 - lastTremorResult.score / 3.0 * 100.0).clamp(0.0, 100.0);
  }

  int totalBitesFor(String deviceId) {
    // Per-spoon today total from the DB (bites grouped by the owning spoon).
    final base = (_todayStatsForDevice(deviceId)['total_bites'] as int?) ?? 0;
    if (isSessionActiveFor(deviceId)) {
      // uncommittedBites (per-device) bridges the gap before the async DB write
      // completes. It is non-zero only for the spoon whose session is live, so
      // it never leaks another spoon's live bites into this one's total.
      return base + getSession(deviceId).uncommittedBites;
    }
    // Do NOT fall back to session.bgBiteCount — that is the device's ABSOLUTE,
    // power-cycle-lifetime counter, not today's count. Background bites are
    // reconciled into the DB on takeover, so the per-spoon snapshot already
    // includes them.
    return base;
  }

  // Per-spoon meal-type breakdown for the home Eating Analysis card. Each home
  // section passes its own deviceId, so these resolve to that spoon's numbers.
  int _liveBitesForDeviceMeal(String deviceId, String mealType) {
    // Bridge live (not-yet-written) bites only for the spoon whose session is
    // active right now, and only into the meal type that corresponds to now.
    if (!isSessionActiveFor(deviceId)) return 0;
    if (getSession(deviceId).currentMealUuid == null) return 0;
    if (_getMealTypeByTime() != mealType) return 0;
    // AI Lab only — the MotionAnalysisService fallback counted differently
    // and made this card disagree with the AI Lab page.
    // return _runtime.hardwareBiteCount == 0
    //     ? _motionService.currentBiteCount
    //     : getSession(deviceId).uncommittedBites;
    return getSession(deviceId).uncommittedBites;
  }

  int _todayMealBitesFor(String deviceId, String column, String mealType) =>
      ((_todayStatsForDevice(deviceId)[column] as int?) ?? 0) +
      _liveBitesForDeviceMeal(deviceId, mealType);

  int breakfastTotalBitesFor(String deviceId) =>
      _todayMealBitesFor(deviceId, 'breakfast_bites', 'Breakfast');
  int lunchTotalBitesFor(String deviceId) =>
      _todayMealBitesFor(deviceId, 'lunch_bites', 'Lunch');
  int dinnerTotalBitesFor(String deviceId) =>
      _todayMealBitesFor(deviceId, 'dinner_bites', 'Dinner');
  int snackTotalBitesFor(String deviceId) =>
      _todayMealBitesFor(deviceId, 'snack_bites', 'Snack');

  double avgBiteTimeFor(String deviceId) {
    final bites = getSession(deviceId).biteTimestamps;
    if (bites.length >= 2) {
      double totalSeconds = 0;
      for (int i = 1; i < bites.length; i++) {
        totalSeconds += bites[i].difference(bites[i - 1]).inSeconds;
      }
      return totalSeconds / (bites.length - 1);
    }
    // Fall back to this spoon's today snapshot: avg seconds per bite.
    final stats = _todayStatsForDevice(deviceId);
    final b = (stats['total_bites'] as int?) ?? 0;
    final min = (stats['total_eating_min'] as num?)?.toDouble() ?? 0.0;
    if (b > 0 && min > 0) return (min * 60) / b;
    return 0;
  }

  String? currentMealTypeFor(String deviceId) {
    if (!isSessionActiveFor(deviceId)) return null;
    return _getMealTypeByTime();
  }
  // --------------------------

  // Matches the AI Lab meal tracker's own end-of-meal wait, so the two cannot
  // disagree about whether a meal is still running. AI Lab ending its meal is
  // what normally closes the session (see _onTremorUpdate); this is a backstop.
  static const Duration _inactivityTimeout = Duration(minutes: 3);
  Timer? _usageTimer;
  Timer? _bgPollTimer;

  /// Legacy getters for backwards compatibility with UI
  bool get isReceivingBgData =>
      primaryDeviceId != null &&
      getSession(primaryDeviceId!).bgLastUpdate != null &&
      DateTime.now()
              .difference(getSession(primaryDeviceId!).bgLastUpdate!)
              .inSeconds <
          30;
  int get bgBiteCount =>
      primaryDeviceId != null ? getSession(primaryDeviceId!).bgBiteCount : 0;
  double get bgAvgAccel =>
      primaryDeviceId != null ? getSession(primaryDeviceId!).bgAvgAccel : 0.0;
  int get bgBattery =>
      primaryDeviceId != null ? getSession(primaryDeviceId!).bgBattery : 0;
  double get bgTemperature => primaryDeviceId != null
      ? getSession(primaryDeviceId!).bgTemperature
      : 0.0;
  DateTime? get bgLastUpdate => primaryDeviceId != null
      ? getSession(primaryDeviceId!).bgLastUpdate
      : null;

  double _targetHeaterTemp = 40.0; // Default: target heater temperature 40°C

  // Goals (Persisted in SharedPreferences)
  double _breakfastGoal = 12.5;
  double _lunchGoal = 12.5;
  double _dinnerGoal = 12.5;
  double _snackGoal = 12.5;

  double get breakfastGoal => _breakfastGoal;
  double get lunchGoal => _lunchGoal;
  double get dinnerGoal => _dinnerGoal;
  double get snackGoal => _snackGoal;
  int get dailyBiteGoal =>
      (_breakfastGoal + _lunchGoal + _dinnerGoal + _snackGoal).toInt();

  // Resume-reconciliation state: the HW-count anchor persisted at the last
  // recorded bite before the app was killed, and that bite's timestamp. Set in
  // _loadPrefs on resume, consumed exactly once by _reconcileBackgroundBites.
  int? _resumeReconcileAnchor;
  DateTime? _resumeReconcileLastBite;

  /// Null-safe ISO-8601 parse — returns null on missing/corrupt values so a
  /// partially-written prefs state can never crash startup.
  DateTime? _tryParseDate(String? value) =>
      value == null ? null : DateTime.tryParse(value);

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _breakfastGoal = prefs.getDouble('breakfastGoal') ?? 12.5;
    _lunchGoal = prefs.getDouble('lunchGoal') ?? 12.5;
    _dinnerGoal = prefs.getDouble('dinnerGoal') ?? 12.5;
    _snackGoal = prefs.getDouble('snackGoal') ?? 12.5;

    // Check if we can resume an active session after app restart
    final sessionActive = prefs.getBool('session_active') ?? false;
    if (sessionActive) {
      final lastBite = _tryParseDate(prefs.getString('session_last_bite_time'));
      final startTime = _tryParseDate(prefs.getString('session_start_time'));
      if (lastBite != null && startTime != null) {
        if (DateTime.now().difference(lastBite) < _inactivityTimeout) {
          // Pin the session bucket now (BLE is not connected yet at cold start)
          // so a later reconnect under the real device ID can't orphan it.
          // Never persist/restore an empty device id — home cards key off the
          // real BLE address and would miss the resumed meal.
          _activeSessionDeviceId = pinSessionDeviceId(
            prefs.getString('session_device_id') ?? _sessionDeviceId,
          );
          if (_activeSessionDeviceId == null) {
            prefs.setBool('session_active', false);
          } else {
            getSession(_sessionDeviceId).sessionStartTime = startTime;
            getSession(_sessionDeviceId).currentMealUuid = prefs.getString(
              'session_meal_uuid',
            );
            // Stage the resume reconciliation: the HW-count anchor at the last
            // recorded bite before the kill, and that bite's time. On the first
            // foreground HW reading, _reconcileBackgroundBites backfills the gap.
            _resumeReconcileAnchor = prefs.getInt('session_last_hw_count');
            _resumeReconcileLastBite = lastBite;
            debugPrint(
              '[UDS] 🔄 Resumed meal session ${getSession(_sessionDeviceId).currentMealUuid} (anchor=$_resumeReconcileAnchor)',
            );
            _resetInactivityTimer();
          }
        } else {
          // Expired in background/killed state
          prefs.setBool('session_active', false);
        }
      } else {
        // Inconsistent persisted state (partial write / selective clear) — reset
        prefs.setBool('session_active', false);
      }
    }
    notifyListeners();
  }

  Future<void> setDailyGoals(
    double breakfast,
    double lunch,
    double dinner,
    double snack,
  ) async {
    _breakfastGoal = breakfast;
    _lunchGoal = lunch;
    _dinnerGoal = dinner;
    _snackGoal = snack;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('breakfastGoal', breakfast);
    await prefs.setDouble('lunchGoal', lunch);
    await prefs.setDouble('dinnerGoal', dinner);
    await prefs.setDouble('snackGoal', snack);
    notifyListeners();
  }

  // App cycle management
  /// Firebase auth changes, or null when no Firebase app is configured.
  Stream<User?>? _tryAuthStateChanges() {
    try {
      return FirebaseAuth.instance.authStateChanges();
    } catch (e) {
      debugPrint('[UDS] Firebase auth unavailable — skipping auth listener: $e');
      return null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (isSessionActive) {
        debugPrint(
          '📱 App backgrounded/killed. Auto-saving meal session to prevent data loss...',
        );
        // The meal row is already upserted after every bite (in _onTremorUpdate), so
        // bite data is safe. We do NOT end the session here so the user can transiently
        // leave the app. The 2-minute inactivity timer or the next restart will handle it.
      }
    } else if (state == AppLifecycleState.resumed) {
      // On resume the foreground BLE takeover is still in flight, so poll the
      // background isolate's data immediately (don't wait up to 10s for the
      // periodic timer) — this makes a bg-connected spoon show as connected
      // right away instead of briefly flashing "disconnected".
      _pollBgData();
    }
  }

  UnifiedDataService({
    this.insightsController,
    required SpoonRuntime runtime,
    required TremorDetectionService tremorService,
  }) : _runtime = runtime,
       _tremorService = tremorService {
    // Register lifecycle observer to prevent ghost sessions on app kill
    WidgetsBinding.instance.addObserver(this);

    // Poll BLE data + tremor every 5 seconds for safe UI updates
    _startPeriodicRefresh();

    // Direct listen to MCU service for ultra-fast UI updates
    _runtime.addListener(_onMcuUpdate);

    // Listen to TremorDetectionService so UI updates immediately when a
    // tremor result arrives — without waiting for a hardware bite event.
    _tremorService.addListener(_onTremorServiceUpdate);
    // A bite should appear on Home the moment the model reports it, not up to
    // a second later. AI Lab notifies on every batch (10 Hz), so only a change
    // in its bite total is acted on.
    _aiLab.addListener(_onAiLabUpdate);

    // Listen to BLE sensor batch stream and forward to motion analysis (for bites)
    // Throttled to 2Hz (every 500ms) to avoid overwhelming the main thread
    // Raw stream fires at 30Hz — processing every packet causes ANR
    DateTime lastProcessTime = DateTime.now();
    _sensorBatchSub = _runtime.sensorBatchStream.listen((packet) {
      final now = DateTime.now();
      if (now.difference(lastProcessTime).inMilliseconds >= 500) {
        lastProcessTime = now;
        // MotionAnalysisService no longer counts anything the UI shows.
        // _motionService.processPacket(packet);
      }
    });

    // Poll background isolate results every 10s…
    _bgPollTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _pollBgData(),
    );
    // …and once RIGHT NOW. didChangeAppLifecycleState is not called for the
    // initial `resumed` state, so on a cold start (OS killed the UI process
    // while the foreground service kept the spoon connected — the normal case on
    // vivo/Xiaomi/Oppo) nothing polled the bridge for the first 10 s and the
    // Home card showed "Unavailable" for a spoon that was connected throughout.
    _pollBgData();

    // Load today's aggregated data from SQLite on startup
    _loadTodaySnapshot();
    _loadPrefs(); // Load saved goals
    loadSelectedSpoon(); // Restore which spoon the home page was showing
    PersonalizedEatingModel().load(); // Restore per-person learned profiles

    // Re-load snapshot once Firebase Auth session is restored (cold-start race fix).
    // On first call above, currentUser is null → userId = 'demo_user' → 0 rows returned.
    // This listener fires ~200ms later with the real UID so the actual data shows up.
    // Also re-tag any meals written as offline_user before auth restored.
    // Guarded because the constructor must not require a live Firebase app.
    // A widget test builds this service to render a screen; throwing here takes
    // the whole screen down for a reason that has nothing to do with the
    // screen, and the auth listener is a refresh optimisation, not a
    // dependency — without it the snapshot still loads, just once.
    _authStateSub = _tryAuthStateChanges()?.listen((
      user,
    ) async {
      if (user != null) {
        debugPrint(
          '[UDS] Auth restored (uid=${user.uid}), repairing offline tags + reloading snapshot...',
        );
        try {
          await DatabaseService().repairLegacyUserIdTags(user.uid);
        } catch (e) {
          debugPrint('[UDS] Legacy user-id repair failed: $e');
        }
        _loadTodaySnapshot();
      }
    });
  }

  StreamSubscription<dynamic>? _sensorBatchSub;
  StreamSubscription<User?>? _authStateSub;

  void _onMcuUpdate() {
    // We intentionally DO NOT auto-end the meal session on disconnect here anymore.
    // This allows the user to transiently disconnect/reconnect and have new bites
    // seamlessly continue attaching to the exact same Meal record.
    notifyListeners();
  }

  void _onTremorServiceUpdate() {
    // TremorDetectionService produced a new result — push it to UI immediately.
    notifyListeners();
  }

  /// Device IDs the background isolate tracks. BleService keeps this
  /// SharedPreferences list ('smart_spoon_ids') in sync on pair/forget; we read
  /// it here so the foreground can poll each device's background bridge keys.
  List<String> _readBackgroundDeviceIds(SharedPreferences prefs) {
    try {
      final json = prefs.getString('smart_spoon_ids');
      if (json != null && json.isNotEmpty) {
        final ids = (jsonDecode(json) as List<dynamic>)
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList();
        if (ids.isNotEmpty) return ids;
      }
    } catch (_) {}
    // Fallbacks: legacy single-device key + the current primary device.
    final legacy = prefs.getString('smart_spoon_id');
    final primary = primaryDeviceId;
    return <String>{
      if (legacy != null && legacy.isNotEmpty) legacy,
      if (primary != null && primary.isNotEmpty) primary,
    }.toList();
  }

  /// Poll SharedPreferences for data written by the background BLE isolate.
  /// Runs every 10s (and once on resume). The isolate writes PER-DEVICE keys
  /// (`bg_updated_at_<id>`, …); we must read the same suffixed keys — reading
  /// the un-suffixed base keys silently dropped all background data, so the UI
  /// showed "disconnected" even while the isolate was connected and streaming.
  Future<void> _pollBgData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // CRITICAL: SharedPreferences.getInstance() returns a process-cached map
      // loaded once. The background isolate writes bg_*_<id> keys in a SEPARATE
      // isolate/process; those writes do NOT invalidate this foreground cache.
      // Without reload(), a WARM resume (app suspended, not killed, while the
      // isolate took over BLE) never sees the new data → the UI flashes
      // "disconnected". reload() re-reads the store so cross-isolate writes show.
      await prefs.reload();
      final ids = _readBackgroundDeviceIds(prefs);
      if (ids.isEmpty) return;

      final now = DateTime.now();
      var changed = false;

      for (final deviceId in ids) {
        // Foreground live data is authoritative — never override a device we
        // are actively streaming from in-process.
        if (_runtime.isConnectedTo(deviceId)) continue;

        final updatedAt = prefs.getInt('${kBgUpdatedAt}_$deviceId');
        if (updatedAt == null) continue;

        final updated = DateTime.fromMillisecondsSinceEpoch(updatedAt);
        if (now.difference(updated).inSeconds > 60) continue; // stale
        final session = getSession(deviceId);
        if (session.bgLastUpdate != null &&
            !updated.isAfter(session.bgLastUpdate!)) {
          continue; // nothing newer since last poll
        }

        session.bgBiteCount =
            prefs.getInt('${kBgBiteCount}_$deviceId') ?? session.bgBiteCount;
        session.bgAvgAccel =
            prefs.getDouble('${kBgAvgAccel}_$deviceId') ?? session.bgAvgAccel;
        session.bgBattery =
            prefs.getInt('${kBgBattery}_$deviceId') ?? session.bgBattery;
        session.bgTemperature =
            prefs.getDouble('${kBgTemperature}_$deviceId') ??
            session.bgTemperature;
        session.bgLastUpdate = updated;
        changed = true;

        debugPrint(
          '[UDS] BG data polled ($deviceId): bites=${session.bgBiteCount} '
          'temp=${session.bgTemperature.toStringAsFixed(1)}°C '
          'bat=${session.bgBattery}%',
        );

        // Do not advance lastHardwareBiteCount here. The isolate only writes
        // prefs — consuming the anchor without inserting bites makes the next
        // 1s tick see a non-positive delta and those bites are lost.
      }

      if (changed) notifyListeners();
    } catch (e) {
      debugPrint('[UDS] BG poll error: $e');
    }
  }

  /// True when [deviceId] is either streaming live in the foreground OR the
  /// background isolate produced data for it within the last 30 s. The UI uses
  /// this so a spoon that is connected only via the background service still
  /// shows as connected instead of "disconnected".
  bool isEffectivelyConnectedFor(String deviceId) {
    if (_runtime.isConnectedTo(deviceId)) return true;
    // NOT "linking + a temperature above zero": the temperature is the last
    // value from the PREVIOUS session and is never cleared, so every reconnect
    // attempt — even to a spoon that was not there — made the home card say
    // "Connected". Only a live session is connected.
    final u = getSession(deviceId).bgLastUpdate;
    // The background isolate writes every ~10s while connected, so a 20s window
    // keeps a genuinely bg-connected spoon "fresh" continuously, but lets a
    // stopped isolate (e.g. after the foreground takeover on app resume) go
    // stale quickly instead of showing "connected" for a lingering 30s.
    return u != null && DateTime.now().difference(u).inSeconds < 20;
  }

  /// True when [deviceId] is served by the background isolate (fresh bg data)
  /// but is NOT currently streaming in the foreground — used to label the UI.
  bool isBackgroundOnlyFor(String deviceId) =>
      !_runtime.isConnectedTo(deviceId) &&
      isEffectivelyConnectedFor(deviceId);

  // Periodic refresh timer (every 1 second) — pushes battery/temp/tremor to UI
  Timer? _periodicRefreshTimer;

  void _startPeriodicRefresh() {
    _periodicRefreshTimer?.cancel();
    _periodicRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Collect temp reading during active session
      if (isSessionActive && _runtime.currentData != null) {
        _addTempReading(_runtime.currentData!.temperature);
      }
      // Push tremor + BLE data update to UI
      _onTremorUpdate();
    });
  }

  // ─── TODAY'S SNAPSHOT ────────────────────────────────────────────────────────
  // Loaded from daily_summaries on startup and after each session ends.
  // Used as fallback when no BLE session is active.

  int _todayBites = 0;
  int _todayBreakfastBites = 0;
  int _todayLunchBites = 0;
  int _todayDinnerBites = 0;
  int _todaySnackBites = 0;
  double _todayEatingMin = 0;
  double _todayAvgTemp = 0;

  /// Public callable — refreshes today's data snapshot from the DB.
  void refreshTodaySnapshot() => _loadTodaySnapshot();

  Future<void> _loadTodaySnapshot() async {
    try {
      final userId = FirebaseAuth.instance.currentUser?.uid ?? 'demo_user';
      final today = DateTime.now();
      final db = DatabaseService();
      // Per-spoon (per-person) snapshot first, so each home card has its own
      // spoon's numbers regardless of the global daily_summaries below.
      await _loadPerSpoonToday(userId, today, db);
      final rows = await db.getDailySummaries(
        userId: userId,
        start: DateTime(today.year, today.month, today.day),
        end: today,
      );
      if (rows.isEmpty) {
        _todayBites = 0;
        _todayBreakfastBites = 0;
        _todayLunchBites = 0;
        _todayDinnerBites = 0;
        _todaySnackBites = 0;
        _todayEatingMin = 0;
        _todayAvgTemp = 0;
        notifyListeners();
        return;
      }
      final r = rows.first;
      _todayBites = (r['total_bites'] as num?)?.toInt() ?? 0;
      _todayBreakfastBites = (r['breakfast_bites'] as num?)?.toInt() ?? 0;
      _todayLunchBites = (r['lunch_bites'] as num?)?.toInt() ?? 0;
      _todayDinnerBites = (r['dinner_bites'] as num?)?.toInt() ?? 0;
      _todaySnackBites = (r['snack_bites'] as num?)?.toInt() ?? 0;
      _todayEatingMin = (r['total_eating_min'] as num?)?.toDouble() ?? 0;
      _todayAvgTemp = (r['avg_food_temp_c'] as num?)?.toDouble() ?? 0;
      notifyListeners();
      debugPrint(
        '[UDS] Today snapshot: $_todayBites bites, ${_todayEatingMin.toStringAsFixed(1)} min, ${_todayAvgTemp.toStringAsFixed(1)}°C avg temp',
      );
    } catch (e) {
      debugPrint('[UDS] Could not load today snapshot: $e');
    }
  }

  /// Load today's per-spoon aggregates into [_todayBySpoon]. One DB query per
  /// distinct paired-spoon key (there are only a handful of spoons per account),
  /// so each home card can render its own spoon's numbers even when that spoon
  /// is disconnected. Runs independently of the global daily_summaries so a
  /// spoon that has data today always shows it.
  Future<void> _loadPerSpoonToday(
    String userId,
    DateTime today,
    DatabaseService db,
  ) async {
    try {
      // Distinct stable keys across all paired spoons (+ any active session).
      final paired = SpoonRuntime().previousDevices;
      final keys = <String>{};
      for (final d in paired) {
        keys.add(spoonKeyFor(d.id));
      }
      final active = _sessionDeviceId;
      if (active.isNotEmpty) keys.add(spoonKeyFor(active));
      keys.removeWhere((k) => k.isEmpty);

      // One-time: attribute legacy meals (no spoon_key, recorded before
      // per-spoon tracking) to the primary spoon so existing history keeps
      // showing instead of dropping to zero. Idempotent + guarded to once/run.
      if (!_spoonBackfillDone && paired.isNotEmpty) {
        _spoonBackfillDone = true;
        final primaryKey = spoonKeyFor(paired.first.id);
        if (primaryKey.isNotEmpty) {
          final n = await db.backfillNullSpoonKeys(
            userId: userId,
            spoonKey: primaryKey,
          );
          if (n > 0) {
            debugPrint('[UDS] Backfilled $n legacy meal(s) → spoon $primaryKey');
          }
        }
      }

      final next = <String, Map<String, dynamic>>{};
      for (final key in keys) {
        next[key] = await db.getTodayStatsForSpoon(
          userId: userId,
          spoonKey: key,
          day: today,
        );
      }
      _todayBySpoon
        ..clear()
        ..addAll(next);
    } catch (e) {
      debugPrint('[UDS] Could not load per-spoon today snapshot: $e');
    }
  }

  // Getters that combine live session data + today's DB snapshot
  // When a session IS active  → use _currentSessionBites (updated live from DB after each bite insert)
  // When no session is active → shows today's total from daily_summaries
  int get totalBites {
    if (isSessionActive) {
      // AI Lab only — no MotionAnalysisService fallback:
      // if (_runtime.hardwareBiteCount == 0) {
      //   return _todayBites + _motionService.currentBiteCount;
      // }
      // _todayBites is updated in-place after every bite DB insert (line ~758),
      // so it already reflects the current session's bites.
      // getSession(primaryDeviceId ?? "").uncommittedBites bridges the tiny gap between BLE arrival and DB write.
      return _todayBites + getSession(_sessionDeviceId).uncommittedBites;
    }
    return _todayBites;
  }

  // Getters for specific meal types combining DB and live session
  int _getLiveBitesForMeal(String mealType) {
    int liveBites = getSession(_sessionDeviceId).uncommittedBites;

    // AI Lab only — the software-motion fallback is gone:
    // if (isSessionActive &&
    //     getSession(_sessionDeviceId).currentMealUuid != null &&
    //     _runtime.hardwareBiteCount == 0) {
    //   liveBites = _motionService.currentBiteCount;
    // }

    // Only add these live unsaved bites to the meal type if it corresponds to right now
    final currentMeal = _getMealTypeByTime();
    if (currentMeal == mealType) {
      return liveBites;
    }
    return 0;
  }

  int get breakfastTotalBites =>
      _todayBreakfastBites + _getLiveBitesForMeal('Breakfast');
  int get lunchTotalBites => _todayLunchBites + _getLiveBitesForMeal('Lunch');
  int get snackTotalBites => _todaySnackBites + _getLiveBitesForMeal('Snack');
  int get dinnerTotalBites =>
      _todayDinnerBites + _getLiveBitesForMeal('Dinner');

  int get biteCount => totalBites;

  int get currentStreak {
    if (insightsController == null ||
        insightsController!.dailySummaries.isEmpty) {
      return 0;
    }

    // Sort descending by date
    final summaries = List<DailyBiteSummary>.from(
      insightsController!.dailySummaries,
    )..sort((a, b) => b.date.compareTo(a.date));

    int streak = 0;
    DateTime expectedDate = DateTime.now();
    bool foundToday = false;

    // Check if they have bites today:
    if (totalBites > 0) {
      streak = 1;
      expectedDate = expectedDate.subtract(const Duration(days: 1));
      foundToday = true;
    }

    for (var summary in summaries) {
      // Ignore today if we already counted it above OR if it's 0 (maybe not synced yet)
      if (summary.date.year == DateTime.now().year &&
          summary.date.month == DateTime.now().month &&
          summary.date.day == DateTime.now().day) {
        if (!foundToday && summary.totalBites > 0) {
          streak = 1;
          expectedDate = expectedDate.subtract(const Duration(days: 1));
          foundToday = true;
        }
        continue;
      }

      if (summary.date.year == expectedDate.year &&
          summary.date.month == expectedDate.month &&
          summary.date.day == expectedDate.day) {
        if (summary.totalBites > 0) {
          streak++;
          expectedDate = expectedDate.subtract(const Duration(days: 1));
        } else {
          break; // streak broke
        }
      } else if (summary.date.isBefore(expectedDate)) {
        break; // streak broke (missed a day)
      }
    }

    return streak;
  }

  double get avgBiteTime {
    if (isSessionActive) {
      final count = totalBites;
      if (count == 0 || getSession(_sessionDeviceId).sessionStartTime == null) {
        return 0.0;
      }
      return DateTime.now()
              .difference(getSession(_sessionDeviceId).sessionStartTime!)
              .inSeconds /
          count;
    }
    // When no session: show avg seconds per bite based on today's history
    if (_todayBites == 0 || _todayEatingMin == 0) return 0.0;
    return (_todayEatingMin * 60) / _todayBites;
  }

  // Live spoon temperature only. Do not substitute today's average — that
  // made the home/heater UI look like food was warm when the probe was '--'.
  double get foodTempC {
    final live = _runtime.temperature;
    return live > 0 ? live : 0;
  }

  // Heater NTC from MCU (command-echo status + batch temperature).
  double get heaterTempC =>
      _runtime.heaterStatus?.tempC ?? _runtime.temperature;

  // Prefer live MCU command-echo status; fall back to local UI state.
  bool _localHeaterState = false;
  bool get isHeaterOn {
    final status = _runtime.heaterStatus;
    if (status != null) return status.maintainOn || status.railOn;
    return _localHeaterState;
  }

  // Temperature Settings Getters
  double get targetHeaterTemp => _targetHeaterTemp;
  double get maxHeaterTemp => _targetHeaterTemp;

  // Heater Usage Duration
  Duration get heaterUsageDuration {
    if (!isHeaterOn || getSession(_sessionDeviceId).heaterStartTime == null) {
      return Duration.zero;
    }
    return DateTime.now().difference(
      getSession(_sessionDeviceId).heaterStartTime!,
    );
  }

  // Battery Level — live from BLE
  int get batteryLevel => _runtime.batteryLevel;

  // Eating Speed — rolling 3-min window, exponentially smoothed
  double get eatingSpeedBpm => getSession(_sessionDeviceId).smoothedSpeedBpm;
  double get eatingSpeed => getSession(_sessionDeviceId).smoothedSpeedBpm;

  /// Recomputes eating speed every second using inter-bite intervals (IBI).
  ///
  /// IBI-based approach:
  ///   - Uses the mean of the last 5 intervals between consecutive bites.
  ///   - Responds quickly to pace changes (not dragged by bites from minutes ago).
  ///   - Decays naturally to 0 when all bites age out of the 90 s window.
  ///
  /// Called every 1 s from the periodic timer so the gauge decays smoothly
  /// when the user stops eating — not just when new bites arrive.
  void _updateSmoothedSpeed() {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(seconds: 90));
    getSession(
      _sessionDeviceId,
    ).biteTimestamps.removeWhere((t) => t.isBefore(cutoff));

    double raw = 0.0;
    if (getSession(_sessionDeviceId).biteTimestamps.length >= 2) {
      // Use last 6 timestamps → last 5 IBI values (most-recent pace window)
      final recent = getSession(_sessionDeviceId).biteTimestamps.length > 6
          ? getSession(_sessionDeviceId).biteTimestamps.sublist(
              getSession(_sessionDeviceId).biteTimestamps.length - 6,
            )
          : getSession(_sessionDeviceId).biteTimestamps;
      double totalSec = 0;
      for (int i = 1; i < recent.length; i++) {
        totalSec += recent[i].difference(recent[i - 1]).inMilliseconds / 1000.0;
      }
      final meanIbiSec = totalSec / (recent.length - 1);
      if (meanIbiSec > 0) raw = 60.0 / meanIbiSec;
    } else if (getSession(_sessionDeviceId).biteTimestamps.length == 1 &&
        getSession(_sessionDeviceId).sessionStartTime != null) {
      final elapsedMin =
          now
              .difference(getSession(_sessionDeviceId).sessionStartTime!)
              .inSeconds /
          60.0;
      if (elapsedMin > 0) raw = 1.0 / elapsedMin;
    }
    // raw == 0.0 when all timestamps aged out → smoothing drives gauge to 0.

    // Exponential smoothing α=0.5: responsive to real pace changes, not jumpy.
    getSession(
      _sessionDeviceId,
    ).smoothedSpeedBpm = getSession(_sessionDeviceId).smoothedSpeedBpm == 0.0
        ? raw
        : 0.5 * raw + 0.5 * getSession(_sessionDeviceId).smoothedSpeedBpm;
  }

  /// Resets the 20-minute inactivity watchdog. Called on every new bite.
  void _resetInactivityTimer() {
    getSession(_sessionDeviceId).sessionInactivityTimer?.cancel();
    getSession(_sessionDeviceId).sessionInactivityTimer = Timer(
      _inactivityTimeout,
      () {
        if (isSessionActive) {
          debugPrint('[UDS] ⏱️ No bites for 2 min — auto-ending session');
          endSession();
        }
      },
    );
  }

  // ─── EATING ALERTS ───────────────────────────────────────────────────────────
  // Thresholds
  //
  // These two are the FALLBACK pair, used only until the per-person model can
  // personalize. A fixed 25 bites/min is wrong in both directions: someone
  // whose ordinary lunch runs at 28 would be told off at every meal, and
  // someone whose ordinary pace is 8 could double it without ever crossing
  // 25. _speedAlertBand() derives the real pair from this eater's own
  // baseline once there is one.
  static const double _fastEatingThreshold = 25.0; // bites/min — alert ON
  static const double _fastEatingClearThreshold =
      18.0; // bites/min — alert OFF (hysteresis)

  /// Where the personalized alert clears, in standard deviations above this
  /// eater's baseline. It arms at [PersonalizedEatingModel.zFlag] (2.0), so
  /// this keeps the same hysteresis gap the fixed pair had — 18 of 25 is 0.72
  /// of the arming threshold, and 1.0 of 2.0 sigma is a comparable step back
  /// expressed in the person's own spread instead of absolute bites.
  static const double _speedAlertClearZ = 1.0;
  static const double _hotFoodThreshold = 60.0; // °C
  static const double _veryHotFoodThreshold = 70.0; // °C
  static const double _tremorAlertThreshold = 1.5; // score 0–3

  // Hysteresis state — prevents the speed alert from re-firing on every bite
  // while the user is already eating fast.
  bool _speedAlertActive = false;

  /// The speed band for the spoon in this session, and the phrase the alert
  /// uses to justify itself.
  ///
  /// Personalized once the model can personalize, because "too fast" only
  /// means anything relative to how this person normally eats, and against
  /// the baseline for THIS meal type — breakfast and dinner paces differ
  /// enough in practice that one daily average fires on the wrong meal.
  /// Until then the fixed pair stands in, and the alert says so rather than
  /// implying a personal reading it does not have.
  ({double arm, double clear, String reference}) _speedAlertBand() {
    final key = spoonKeyFor(_sessionDeviceId);
    return speedAlertBandFor(
      key.isEmpty ? null : PersonalizedEatingModel().profileFor(key),
      at: DateTime.now(),
    );
  }

  /// The band itself, as a function of the profile and the clock — separated
  /// from the singletons above so the thresholds can actually be checked
  /// against a known profile rather than only in a running app.
  @visibleForTesting
  static ({double arm, double clear, String reference}) speedAlertBandFor(
    PersonalizedProfile? p, {
    required DateTime at,
  }) {
    if (p == null || !p.canPersonalize) {
      return (
        arm: _fastEatingThreshold,
        clear: _fastEatingClearThreshold,
        reference: 'above the general guide of '
            '${_fastEatingThreshold.toStringAsFixed(0)}',
      );
    }
    final mealType = PersonalizedEatingModel.mealTypeForHour(at.hour);
    final baseline = p.baselinePaceFor(mealType);
    final std =
        math.max(p.paceStd, PersonalizedEatingModel.paceStdFloor);
    return (
      arm: baseline + PersonalizedEatingModel.zFlag * std,
      clear: baseline + _speedAlertClearZ * std,
      reference: 'your usual ${mealType.toLowerCase()} is about '
          '${baseline.toStringAsFixed(0)}',
    );
  }

  /// Fires in-app overlay when foreground, OS notification when backgrounded.
  /// Called after every bite is recorded.
  void _checkEatingAlerts() {
    if (!isSessionActive) return;
    final context = navigatorKey.currentContext;

    // Speed alert with hysteresis:
    //   Arms   when speed crosses ABOVE 25 bpm  → show alert once.
    //   Clears when speed drops  BELOW 18 bpm   → ready to arm again.
    // This prevents the alert from re-firing on every bite while already fast.
    final band = _speedAlertBand();
    // The pace that tripped the alert and the pace quoted in it must come
    // from the SAME session. This read used to be _sessionDeviceId for the
    // comparison and primaryDeviceId for the message, so with two spoons
    // paired the alert could name a figure that had nothing to do with why
    // it fired.
    final speed = getSession(_sessionDeviceId).smoothedSpeedBpm;
    final wasActive = _speedAlertActive;
    if (speed > band.arm) {
      _speedAlertActive = true;
    } else if (speed < band.clear) {
      _speedAlertActive = false;
    }

    if (_speedAlertActive && !wasActive) {
      final observed = speed.toStringAsFixed(0);
      if (context != null && context.mounted) {
        InAppAlertService().show(
          context,
          InAppAlert(
            title: 'Faster than usual',
            body: 'Slow down — $observed bites/min, ${band.reference}',
            severity: AlertSeverity.warning,
          ),
          throttleKey: 'speed_alert',
        );
      } else {
        NotificationService().showLocalAlert(
          title: 'Faster than usual',
          body: '$observed bites/min, ${band.reference}',
          type: 'eating_alerts',
          priority: 'HIGH',
        );
      }
    }

    // Temperature alert
    final temp = foodTempC;
    if (temp > _veryHotFoodThreshold) {
      if (context != null && context.mounted) {
        InAppAlertService().show(
          context,
          InAppAlert(
            title: 'Food Very Hot — ${formatSpoonTempC(temp)}°C',
            body: 'Wait before eating to avoid burns',
            severity: AlertSeverity.danger,
          ),
          throttleKey: 'temp_danger',
        );
      } else {
        NotificationService().showLocalAlert(
          title: 'Food Very Hot',
          body: '${formatSpoonTempC(temp)}°C — wait before eating',
          type: 'eating_alerts',
          priority: 'CRITICAL',
        );
      }
    } else if (temp > _hotFoodThreshold) {
      if (context != null && context.mounted) {
        InAppAlertService().show(
          context,
          InAppAlert(
            title: 'Food is Hot — ${formatSpoonTempC(temp)}°C',
            body: 'Be careful while eating',
            severity: AlertSeverity.warning,
          ),
          throttleKey: 'temp_warning',
        );
      }
    }

    // Repeated rhythmic-movement alert. This is a wellness observation, not a
    // diagnosis; user-facing copy intentionally avoids disease terminology.
    final ti = tremorIndex;
    if (ti > _tremorAlertThreshold) {
      if (context != null && context.mounted) {
        InAppAlertService().show(
          context,
          const InAppAlert(
            title: 'Hand movement increased',
            body: 'More rhythmic movement than usual was measured while eating',
            severity: AlertSeverity.danger,
            duration: Duration(seconds: 6),
          ),
          throttleKey: 'tremor_alert',
        );
      } else {
        NotificationService().showLocalAlert(
          title: 'Hand movement increased',
          body: 'Review the movement trend for this meal when convenient',
          type: 'health_alerts',
          priority: 'HIGH',
        );
      }
    }
  }

  // OLD display state for the TremorDetectionService reading: the score was
  // held for 3 s to stop the badge flickering. The AI Lab reading is a rolling
  // one-minute average, so it cannot flicker and needs no hold.
  // TremorResult _cachedDisplayResult = TremorResult.empty();
  // DateTime _lastPositiveDetectionTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// Built from the AI Lab steadiness measure so every screen reads the same
  /// number as the AI Lab page. `score` keeps the 0–3 shape the UI and the DB
  /// already use: it is the share of the last minute that carried a rhythmic
  /// shake, times three.
  ///
  /// OLD (TremorDetectionService + a 3 s flicker hold) kept below for
  /// reference; that service still runs but no longer feeds any screen.
  //   final current = _tremorService.lastResult;
  //   if (current.detected) { … 3-second hold … }
  TremorResult get lastTremorResult {
    // While a meal is running, use the meal's own figure — the very number the
    // AI Lab page shows — so no two screens can disagree. Between meals fall
    // back to the rolling last minute, which is all there is.
    final meal = _aiLab.mealSteadyPct;
    return aiLabTremorResult(
      steadyPct: meal ?? _aiLab.recentSteadyPct,
      rhythmHz: meal != null ? _aiLab.mealRhythmHz : _aiLab.recentRhythmHz,
      // ACTIVE windows, not elapsed ones. Confidence is meant to say how much
      // movement the reading rests on; feeding it every analysed window let a
      // motionless spoon reach full confidence purely by staying connected.
      windowCount: meal != null
          ? _aiLab.mealActiveWindowCount
          : _aiLab.recentActiveWindowCount,
      at: _aiLab.lastWindowAt,
    );
  }

  /// The reading stored against one bite — always the rolling window, never
  /// the meal aggregate.
  ///
  /// [lastTremorResult] answers "what do the screens show for this meal", and
  /// its span grows for as long as the meal lasts. A bite row answers a
  /// different question: how steady was the hand *around this bite*. Writing
  /// the meal figure into it made `tremor_window_ms` grow without limit, which
  /// broke the column's CHECK 30 s into every meal. The whole-meal numbers now
  /// have their own columns on the meal row, so this one can stay local and
  /// bounded — [AiLabService] caps the rolling buffer at 60 windows, which is
  /// exactly the widened bound in migration 021.
  TremorResult get biteTremorResult => aiLabTremorResult(
        steadyPct: _aiLab.recentSteadyPct,
        rhythmHz: _aiLab.recentRhythmHz,
        windowCount: _aiLab.recentActiveWindowCount,
        at: _aiLab.lastWindowAt,
      );

  /// Bounds of the `tremor_window_ms` column, identical in the local SQLite
  /// CHECK, migration 017 on Postgres and the backend's Zod schema. A value
  /// outside them does not degrade — it aborts the whole bite+meal
  /// transaction, so every value written here must already be inside.
  static const int minTremorWindowMs = 3000;

  /// Matches AiLabService._recentWindowLimit (60 rolling windows) and the
  /// widened CHECK in migration 021 / local schema v17.
  static const int maxTremorWindowMs = 60000;

  /// The window a stored per-bite reading may claim, in ms.
  ///
  /// The AI Lab reading is a running meal aggregate, so its measured span
  /// grows for as long as the meal lasts. The column describes a bounded
  /// analysis window, so a long meal is reported as the longest window the
  /// contract allows rather than its true span — [Meal.measuredSeconds] keeps
  /// the honest figure. Before this clamp existed, every bite after the 30th
  /// second of a meal threw a CHECK violation, the transaction rolled back,
  /// the anchor rolled back with it, and the next tick retried the same
  /// doomed write forever: no bite past 0:30 was ever stored, and the live
  /// count visibly climbed and fell as each optimistic increment was undone.
  @visibleForTesting
  static int storableTremorWindowMs(int windowDurationMs) =>
      windowDurationMs.clamp(minTremorWindowMs, maxTremorWindowMs);

  /// Pure mapping, so it can be tested without a spoon, a database or a clock.
  @visibleForTesting
  static TremorResult aiLabTremorResult({
    required double? steadyPct,
    required double? rhythmHz,
    required int windowCount,
    required DateTime? at,
  }) {
    if (steadyPct == null || at == null) return TremorResult.empty();
    final shakeShare = ((100.0 - steadyPct) / 100.0).clamp(0.0, 1.0);
    return TremorResult(
      measured: true,
      // The same line the AI Lab page calls "frequent rhythmic shaking".
      detected: shakeShare > 0.25,
      frequency: rhythmHz ?? 0.0,
      score: (shakeShare * 3.0).clamp(0.0, 3.0),
      // Confidence grows with how much MOVEMENT the reading is based on: half
      // at 5 active windows, full at 10. It used to need 30, which left the
      // first half minute of every meal with no reading on any screen and no
      // tremor value stored against those bites (the DB write needs >= 0.5).
      // windowCount is now the ACTIVE count, so this finally measures what
      // this comment always claimed — before, a spoon left on a table reached
      // full confidence in ten seconds without anyone touching it.
      confidence: (windowCount / 10.0).clamp(0.0, 1.0),
      windowDurationMs: windowCount * 1000,
      source: 'ai_lab',
      timestamp: at,
    );
  }

  // Tremor Index — 0–3 continuous scale directly from TremorResult.score.
  // score is already on a 0–3 scale (tremor-band power fraction, normalised).
  double get tremorIndex {
    final result = lastTremorResult;
    if (!result.measured || !result.isFresh) return 0.0;
    return result.score.clamp(0.0, 3.0);
  }

  /// Update heater UI/session state after a successful BLE write.
  /// Does not send another GATT command — [HeaterControlPage] used to call
  /// [setHeaterState] then [setHeaterParameters] again and crash/drop the link.
  void recordHeaterCommand({required bool on, required double maxTemp}) {
    _localHeaterState = on;
    _targetHeaterTemp = maxTemp.clamp(30.0, 70.0);
    if (on) {
      getSession(_sessionDeviceId).heaterStartTime = DateTime.now();
      _startUsageTimer();
    } else {
      getSession(_sessionDeviceId).heaterStartTime = null;
      _stopUsageTimer();
    }
    notifyListeners();
  }

  // Control Methods — always go through MCU BLE (firmware 30–70 °C).
  Future<bool> setHeaterState(bool on) async {
    final target = on ? _targetHeaterTemp.round().clamp(30, 70) : 0;
    final ok = await _runtime.setHeaterParameters(
      target,
      target,
      deviceId: pinSessionDeviceId(primaryDeviceId),
    );
    if (!ok) return false;

    _localHeaterState = on;
    if (on) {
      getSession(_sessionDeviceId).heaterStartTime = DateTime.now();
      _startUsageTimer();
    } else {
      getSession(_sessionDeviceId).heaterStartTime = null;
      _stopUsageTimer();
    }
    notifyListeners();
    return true;
  }

  Future<bool> setTemperature(double temp) async {
    return setMaxHeaterTemp(temp);
  }

  /// Set target heater temperature (firmware clamp 30–70 °C).
  Future<bool> setMaxHeaterTemp(double temp) async {
    if (temp < 30 || temp > 70) {
      debugPrint(
        '[UDS] ⚠️ setMaxHeaterTemp($temp) out of firmware range 30–70°C',
      );
      return false;
    }
    _targetHeaterTemp = temp;
    if (_localHeaterState || (_runtime.heaterStatus?.railOn ?? false)) {
      final t = temp.round().clamp(30, 70);
      final ok = await _runtime.setHeaterParameters(
        t,
        t,
        deviceId: pinSessionDeviceId(primaryDeviceId),
      );
      if (!ok) return false;
    }
    notifyListeners();
    return true;
  }

  void _stopUsageTimer() {
    _usageTimer?.cancel();
    _usageTimer = null;
  }

  // Session State

  bool _isEndingSession = false; // Guard against concurrent endSession() calls
  final List<double> _sessionTempReadings =
      []; // Store raw values for averaging

  // Per-bite tracking: last hardware bite_count we saw; used to detect new bites

  bool get isSessionActive =>
      getSession(_sessionDeviceId).sessionStartTime != null;

  String? get currentMealUuid => getSession(_sessionDeviceId).currentMealUuid;

  /// Returns the current meal type based on time of day:
  /// - When session is active, or
  /// - When hardware bite data is flowing from the device
  String? get currentMealType {
    // AI Lab's bites, not the firmware counter's.
    if (isSessionActive || _aiLab.detectedBiteCount > 0) {
      return _getMealTypeByTime();
    }
    return null;
  }

  /// Public method to trigger UI updates
  void notifyUpdate() => notifyListeners();

  // Buffer for instant UI feedback while async DB write happens (per device handled in Session state)

  int _lastSeenAiLabBites = 0;

  void _onAiLabUpdate() {
    final total = _aiLab.detectedBiteCount;
    if (total == _lastSeenAiLabBites) return;
    _lastSeenAiLabBites = total;
    _onTremorUpdate();
  }

  void _onTremorUpdate() {
    // Only push a UI update when there's live state that changes over time
    // (active session clock/speed decay, or a connected device streaming
    // battery/temp). When idle and disconnected, nothing below can change —
    // notifying every second would rebuild every listener forever.
    if (isSessionActive || _runtime.isConnected) {
      notifyListeners();
    }

    // AI Lab decides when a meal is over. Ending the app's session here keeps
    // Home and AI Lab from disagreeing — one showing a finished meal while the
    // other still counts. Only once AI Lab has actually counted a bite in this
    // run, so a session resumed after a restart is not closed on sight.
    final aiHasCounted = (_aiLab.detectedBiteCountOrNull ?? 0) > 0;
    if (isSessionActive && !_isEndingSession && aiHasCounted && !_aiLab.inMeal) {
      debugPrint('[UDS] AI Lab meal ended — closing the session with it');
      unawaited(endSession());
      return;
    }

    // ── Bites come from the AI Lab model, not the firmware counter ────────
    // The decision itself lives in session_integrity.dart so it can be tested
    // without BLE or a database: see decideBiteTick + session_integrity_test.
    // OLD: final currentHwCount = _runtime.hardwareBiteCount;
    final session = getSession(_sessionDeviceId);
    final decision = decideBiteTick(
      // Null until the model has really seen sensor data. A real zero and
      // "nothing streaming" must not look the same, or the anchor is burned
      // against a count that never happened.
      total: _aiLab.detectedBiteCountOrNull,
      anchor: session.lastHardwareBiteCount,
      initialized: session.hwBiteInitialized,
    );

    switch (decision.action) {
      case BiteTickAction.waitForData:
        return;
      case BiteTickAction.baseline:
        // First reading of this session: remember where the model is, count
        // nothing. Only bites from here on belong to this meal.
        session.lastHardwareBiteCount = decision.anchor;
        session.hwBiteInitialized = true;
        debugPrint('🔑 Baselined AI Lab bite total at ${decision.anchor}.');
        return;
      case BiteTickAction.rebaseline:
        session.lastHardwareBiteCount = decision.anchor;
        if (isSessionActive) _updateSmoothedSpeed();
        return;
      case BiteTickAction.ignore:
        // Decay speed every tick — drives the gauge smoothly to 0 after 90 s
        // without a bite.
        if (isSessionActive) _updateSmoothedSpeed();
        return;
      case BiteTickAction.count:
        break;
    }

    if (isSessionActive) _updateSmoothedSpeed();
    final currentHwCount = decision.anchor;
    final newBites = decision.newBites;

    // === STEP 3: Auto-start session if needed (same tick, don't return) ===
    // Guard: don't start a new session while endSession() is running its DB ops.
    // Without this, the 1s timer fires mid-endSession (after getSession(primaryDeviceId ?? "").sessionStartTime=null),
    // sees !isSessionActive, and creates a duplicate meal record.
    if (!isSessionActive && !_isEndingSession) {
      final pinned = pinSessionDeviceId(primaryDeviceId);
      if (pinned == null) return;
      _activeSessionDeviceId = pinned;
      getSession(_sessionDeviceId).sessionStartTime = DateTime.now();
      getSession(_sessionDeviceId).currentMealUuid = const Uuid().v4();
      _sessionTempReadings.clear();
      getSession(_sessionDeviceId).biteTimestamps.clear();
      getSession(_sessionDeviceId).smoothedSpeedBpm = 0.0;
      // _tremorService.clearBiteHistory(); // AI Lab keeps its own history
      // _motionService.startMeal();
      debugPrint('🍽️ Auto-started meal session (${_getMealTypeByTime()}).');
      unawaited(_persistActiveSession());
    }

    // === STEP 4: Record bite delta ===
    final now = DateTime.now();
    // OLD: final tremorResult = _tremorService.lastResult;
    // The bite row records the hand around THIS bite, so it takes the rolling
    // reading. The meal's own figures ride on the meal row instead.
    final tremorResult = biteTremorResult;
    final hasUsableTremorReading =
        tremorResult.measured &&
        tremorResult.isFresh &&
        tremorResult.confidence >= 0.5;

    // Immediately show in UI via buffer
    getSession(_sessionDeviceId).uncommittedBites += newBites;
    // Captured so a failed write (see catchError below) can roll the anchor
    // back — advancing it here is optimistic, ahead of the DB commit.
    final previousHwBiteCount = getSession(
      _sessionDeviceId,
    ).lastHardwareBiteCount;
    getSession(_sessionDeviceId).lastHardwareBiteCount = currentHwCount;

    // Capture session state synchronously before any async gap.
    // endSession() may run concurrently and null out getSession(primaryDeviceId ?? "").sessionStartTime/getSession(primaryDeviceId ?? "").currentMealUuid.
    final mealUuid = getSession(_sessionDeviceId).currentMealUuid!;
    final sessionStart = getSession(
      _sessionDeviceId,
    ).sessionStartTime!; // safe: we just confirmed isSessionActive above
    final capturedMealType = _getMealTypeByTime();
    final capturedUserId = mealWriteUserId(
      FirebaseAuth.instance.currentUser?.uid,
    );
    // Stable per-spoon key for THIS session's spoon, so the meal (and its bites)
    // are attributed to the right spoon/person.
    final capturedDeviceId = _sessionDeviceId;
    final capturedSpoonKey = spoonKeyFor(capturedDeviceId);

    // Record timestamps for IBI-based speed calculation.
    // Minimum IBI guard: ≥ 2 s between timestamps (30 bpm max firmware glitch rate).
    // Prevents BLE-burst duplicates or rapid double-counts from inflating speed.
    // Speed was already updated by the decay call above — no second call needed here.
    DateTime? prevTs = getSession(_sessionDeviceId).biteTimestamps.isNotEmpty
        ? getSession(_sessionDeviceId).biteTimestamps.last
        : null;
    // The model knows when the spoon actually reached the mouth, which is ~1.7 s
    // before it reports the bite. Using that keeps pace (IBI) honest; `now` is
    // only the fallback for the rare tick that carries more than one bite.
    final newestBiteAt = _aiLab.lastBiteAt ?? now;
    for (int i = 0; i < newBites; i++) {
      final ts = newestBiteAt.subtract(Duration(seconds: newBites - 1 - i));
      final ibiOk =
          prevTs == null || ts.difference(prevTs).inMilliseconds >= 2000;
      if (ibiOk) {
        getSession(_sessionDeviceId).biteTimestamps.add(ts);
        prevTs = ts;
      }
    }

    // Save last bite time + the absolute HW-count ANCHOR for session resumption.
    // The anchor lets a resumed session (after the app was killed while the
    // background isolate kept counting) reconcile the bites that happened during
    // the gap, instead of baselining them away (see _reconcileBackgroundBites).
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('session_last_bite_time', now.toIso8601String());
      prefs.setInt('session_last_hw_count', currentHwCount);
    });

    _resetInactivityTimer(); // Reset 2-min auto-end watchdog
    _checkEatingAlerts();

    final bites = List.generate(newBites, (i) {
      return Bite(
        mealUuid: mealUuid,
        timestamp: now.subtract(Duration(seconds: newBites - 1 - i)),
        sequenceNumber:
            getSession(_sessionDeviceId).lastHardwareBiteCount -
            newBites +
            i +
            1,
        foodTempC: _runtime.temperature > 0 ? _runtime.temperature : null,
        // Legacy DB/API column name: this stores the 0–3 movement-variation
        // index, not physical acceleration amplitude.
        tremorMagnitude: hasUsableTremorReading ? tremorResult.score : null,
        tremorFrequency: hasUsableTremorReading && tremorResult.detected
            ? tremorResult.frequency
            : null,
        tremorConfidence: hasUsableTremorReading
            ? tremorResult.confidence
            : null,
        tremorWindowMs: hasUsableTremorReading
            ? storableTremorWindowMs(tremorResult.windowDurationMs)
            : null,
        // How steady the hand was around this bite — the model measures the
        // moments either side of it, so this says more than the meal average.
        steadyPct: hasUsableTremorReading
            ? ((1.0 - _aiLab.lastBiteRhythmicShare) * 100).clamp(0.0, 100.0)
            : null,
        isValid: true,
        isSynced: false,
      );
    });

    // Bites AND the meal row that owns them commit together. Separately, a kill
    // in between left the bites unreachable behind a missing `meals` row — see
    // DatabaseService.insertBitesAndUpsertMeal.
    DatabaseService()
        .insertBitesAndUpsertMeal(
          bites: bites,
          mealUuid: mealUuid,
          // Runs INSIDE the transaction: pure, no DB calls, no notifyListeners.
          buildMeal: (stats) {
            final count = (stats['total_bites'] as num?)?.toInt() ?? 0;
            // avg_tremor_magnitude is the mean of stored score values (0–3
            // scale). No remapping needed — clamp directly to 0–3.
            // NULL means no bite carried a tremor reading; it must stay null
            // rather than becoming a measured 0.0 (see getMealStats).
            final avgMag = (stats['avg_tremor_magnitude'] as num?)?.toDouble();
            final avgFoodTemp = (stats['avg_food_temp'] as num?)?.toDouble();

            // Cumulative stats so far — survives app kill. endSession()
            // overwrites with the identical formula + final duration/temp.
            final elapsedSeconds = DateTime.now()
                .difference(sessionStart)
                .inSeconds;
            final eatingSpeed = (elapsedSeconds > 0 && count > 0)
                ? (count / elapsedSeconds) * 60.0
                : 0.0;

            final movement = _mealMovement;
            return Meal(
              uuid: mealUuid,
              userId: capturedUserId,
              // deviceId stays null: the backend's device_id is a UUID FK, not a
              // BLE address. Per-spoon attribution rides on spoonKey instead.
              spoonKey: capturedSpoonKey.isNotEmpty ? capturedSpoonKey : null,
              startedAt: sessionStart,
              mealType: capturedMealType,
              totalBites: count,
              tremorIndex: avgMag?.clamp(0.0, 3.0),
              // The same numbers the AI Lab page shows, stored as the user
              // reads them instead of only as a 0–3 index.
              steadyPct: movement.steady,
              rhythmHz: movement.hz,
              measuredSeconds: movement.seconds,
              movementSource: 'ai_lab',
              avgPaceBpm: eatingSpeed,
              avgFoodTemp: (avgFoodTemp != null && avgFoodTemp > 0)
                  ? avgFoodTemp
                  : null,
              durationMinutes: elapsedSeconds / 60.0,
            );
          },
        )
        .then((stats) {
          // Committed. Only now is it safe to move UI state forward.
          debugPrint(
            '[UDS] ✅ Saved $newBites new bite(s). Total HW count: $currentHwCount',
          );
          getSession(_sessionDeviceId).uncommittedBites =
              (getSession(_sessionDeviceId).uncommittedBites - newBites).clamp(
                0,
                9999,
              );

          final count = (stats['total_bites'] as num?)?.toInt() ?? 0;
          final avgMag = (stats['avg_tremor_magnitude'] as num?)?.toDouble();
          unawaited(_loadTodaySnapshot());

          debugPrint(
            '[UDS] 💾 Meal upserted: $count bites, '
            'avgMag=${avgMag?.toStringAsFixed(3) ?? "n/a"}',
          );
          notifyListeners();
        })
        .catchError((e) {
          // H7 (and worse than reported): the old comment here claimed "the
          // next tick retries cleanly", but lastHardwareBiteCount was already
          // advanced to currentHwCount synchronously ABOVE, before this write
          // even started. Without this rollback, the next tick's delta is
          // computed from that already-advanced anchor and no longer includes
          // this batch — the transaction rolled back in SQLite, but the bites
          // were gone from the app's perspective anyway. Not a display
          // glitch: permanent data loss on every write failure. Rolling the
          // anchor back — in memory AND in the persisted resume-anchor, so a
          // kill right after this failure doesn't strand the same wrong
          // value — puts this batch back into the next tick's delta.
          final session = getSession(_sessionDeviceId);
          session.uncommittedBites = (session.uncommittedBites - newBites)
              .clamp(0, 9999);
          session.lastHardwareBiteCount = previousHwBiteCount;
          SharedPreferences.getInstance().then((prefs) {
            prefs.setInt('session_last_hw_count', previousHwBiteCount);
          });
          debugPrint(
            '[UDS] ❌ Error saving bites — rolled back, will retry next tick: $e',
          );
        });
  }

  /// One-shot backfill of bites the background isolate counted while the app was
  /// KILLED. Called from STEP 1 on the first foreground hardware reading of a
  /// RESUMED session. Inserts (currentHwCount − anchor) synthesized bite rows
  /// (null tremor/temp, timestamps spread across the gap) into the resumed meal,
  /// then reloads today's snapshot so the daily total reflects them.
  ///
  /// Safety: consumes the anchor exactly once; only runs for a positive,
  /// plausible gap; the caller sets lastHardwareBiteCount = currentHwCount so
  /// future ticks count forward — the gap can never be double-counted.
  /// Backfills bites counted by the background isolate while the app was dead.
  ///
  /// PRECONDITION: [currentHwCount] must be a REAL packet reading, never the
  /// placeholder 0 that [McuBleService.hardwareBiteCount] returns when nothing
  /// is connected. The sole caller enforces this via hardwareBiteCountOrNull.
  /// Violating it burns the anchor against a phantom count and the background
  /// bites are gone for good — the anchor is deliberately single-use.
  ///
  /// UNUSED since AI Lab became the only bite source: the background isolate
  /// counted with the firmware counter, which no longer reaches any screen.
  /// Kept for the day a background AI Lab source exists to backfill from.
  // ignore: unused_element
  Future<void> _reconcileBackgroundBites(int currentHwCount) async {
    final anchor = _resumeReconcileAnchor;
    _resumeReconcileAnchor = null; // consume exactly once
    final lastBite = _resumeReconcileLastBite;
    _resumeReconcileLastBite = null;
    if (anchor == null) return;

    final session = getSession(_sessionDeviceId);
    final mealUuid = session.currentMealUuid;
    final sessionStart = session.sessionStartTime;
    if (mealUuid == null || sessionStart == null) return;

    final gap = currentHwCount - anchor;
    // gap<=0: nothing happened in the background. gap huge: implausible
    // (firmware reflash / counter reset) — never inject phantom rows.
    if (gap <= 0 || gap > 5000) return;

    final start = lastBite ?? sessionStart;
    final end = DateTime.now();
    final spanMs = end.difference(start).inMilliseconds;
    final stepMs = spanMs > 0 ? spanMs / gap : 0;

    final bites = List.generate(gap, (i) {
      var ts = start.add(Duration(milliseconds: (stepMs * (i + 1)).round()));
      if (ts.isAfter(end)) ts = end;
      return Bite(
        mealUuid: mealUuid,
        timestamp: ts,
        sequenceNumber: anchor + i + 1,
        foodTempC: null,
        tremorMagnitude: null,
        tremorFrequency: null,
        isValid: true,
        isSynced: false,
      );
    });

    try {
      await DatabaseService().insertBites(bites);
      // getDailySummaries counts COUNT(b.id) from the bites table, so reloading
      // today's snapshot now includes the backfilled bites in the daily total.
      await _loadTodaySnapshot();
      debugPrint(
        '[UDS] 🔁 Reconciled $gap background bite(s) into meal $mealUuid',
      );
    } catch (e) {
      debugPrint('[UDS] ❌ Background-bite reconciliation failed: $e');
    }
  }

  Future<void> _persistActiveSession() async {
    final deviceId = pinSessionDeviceId(_activeSessionDeviceId);
    final session = deviceId == null ? null : getSession(deviceId);
    if (deviceId == null ||
        session?.sessionStartTime == null ||
        session?.currentMealUuid == null) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('session_active', true);
    await prefs.setString('session_device_id', deviceId);
    await prefs.setString(
      'session_start_time',
      session!.sessionStartTime!.toIso8601String(),
    );
    await prefs.setString('session_meal_uuid', session.currentMealUuid!);
    await prefs.setString(
      'session_last_bite_time',
      DateTime.now().toIso8601String(),
    );
    await prefs.setInt('session_last_hw_count', session.lastHardwareBiteCount);
  }

  /// Drop in-memory patient state so a second account on the same device
  /// cannot inherit the previous user's live totals or Insights cache.
  void resetForUserChange() {
    for (final session in _sessions.values) {
      session.sessionInactivityTimer?.cancel();
      session.sessionStartTime = null;
      session.currentMealUuid = null;
      session.uncommittedBites = 0;
      session.biteTimestamps.clear();
    }
    _sessions.clear();
    _activeSessionDeviceId = null;
    _todayBites = 0;
    _todayBreakfastBites = 0;
    _todayLunchBites = 0;
    _todayDinnerBites = 0;
    _todaySnackBites = 0;
    _todayEatingMin = 0;
    _todayAvgTemp = 0;
    _resumeReconcileAnchor = null;
    _resumeReconcileLastBite = null;
    notifyListeners();
  }

  /// Start a new meal session
  Future<void> startSession() async {
    if (isSessionActive) return;

    final pinned = pinSessionDeviceId(primaryDeviceId);
    if (pinned == null) return;
    _activeSessionDeviceId = pinned;
    getSession(_sessionDeviceId).sessionStartTime = DateTime.now();
    getSession(_sessionDeviceId).currentMealUuid = const Uuid().v4();
    _sessionTempReadings.clear();
    getSession(_sessionDeviceId).biteTimestamps.clear();
    getSession(_sessionDeviceId).smoothedSpeedBpm = 0.0;
    // _tremorService.clearBiteHistory(); // AI Lab keeps its own history
    // MUST be the same counter _onTremorUpdate() compares against. Baselining
    // against the firmware counter here (which is far ahead of AI Lab's total)
    // silently stopped every bite from being counted for the rest of the meal.
    getSession(_sessionDeviceId).lastHardwareBiteCount =
        _aiLab.detectedBiteCount;

    await _persistActiveSession();

    // Legacy bite detection — AI Lab counts the bites now.
    // _motionService.startMeal();

    // Arm the inactivity watchdog — auto-ends session after 2 min of no bites
    _resetInactivityTimer();

    // Cancel breakfast/afternoon reminders since user is now active
    SmartReminderService().onMealLogged();

    notifyListeners();
  }

  /// End current session and save to Database
  Future<void> endSession() async {
    // Guard: prevent concurrent calls (background kill + user tap simultaneously)
    if (!isSessionActive || _isEndingSession) return;
    _isEndingSession = true;

    // Capture session state synchronously FIRST before any awaits.
    // This also prevents _onTremorUpdate from starting new bites on this session.

    // Trim the inactivity timeout off the end of the session to get true eating duration
    DateTime endTime = DateTime.now();
    if (getSession(_sessionDeviceId).biteTimestamps.isNotEmpty) {
      endTime = getSession(_sessionDeviceId).biteTimestamps.last;
    }
    // Safeguard: don't let endTime be before startTime
    if (endTime.isBefore(getSession(_sessionDeviceId).sessionStartTime!)) {
      endTime = DateTime.now();
    }

    final capturedStartTime = getSession(_sessionDeviceId).sessionStartTime!;
    final capturedMealUuid = getSession(_sessionDeviceId).currentMealUuid!;
    final capturedMealType = _getMealTypeByTime();
    // Attribute the final meal record to this session's spoon (per-person).
    final capturedDeviceId = _sessionDeviceId;
    final capturedSpoonKey = spoonKeyFor(capturedDeviceId);
    final sessionDurationSeconds = endTime
        .difference(capturedStartTime)
        .inSeconds;

    // Clear session immediately so _onTremorUpdate stops adding bites to this session
    getSession(_sessionDeviceId).sessionStartTime = null;
    getSession(_sessionDeviceId).currentMealUuid = null;
    getSession(_sessionDeviceId).uncommittedBites =
        0; // Reset buffer — final count comes from DB
    getSession(_sessionDeviceId).biteTimestamps.clear();
    getSession(_sessionDeviceId).smoothedSpeedBpm = 0.0;
    _tremorService.clearBiteHistory();

    // Cancel the inactivity watchdog BEFORE releasing the cached device ID —
    // after release, _sessionDeviceId may resolve to a different bucket
    // (e.g. '' when BLE disconnected) and the real timer would keep running.
    getSession(_sessionDeviceId).sessionInactivityTimer?.cancel();
    getSession(_sessionDeviceId).sessionInactivityTimer = null;

    _activeSessionDeviceId = null; // Release cached device ID
    _speedAlertActive = false;

    // Clear persisted session
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('session_active', false);
    });

    // End motion analysis meal session
    // _motionService.endMeal();

    try {
      final userId = mealWriteUserId(FirebaseAuth.instance.currentUser?.uid);

      // Single source of truth: compute ALL stats from the bites table.
      // This is identical to the formula used in the in-progress upserts above,
      // ensuring the final meal record is consistent with what was shown live.
      final stats = await DatabaseService().getMealStats(capturedMealUuid);
      final dbBiteCount = (stats['total_bites'] as num?)?.toInt() ?? 0;
      final avgMag = (stats['avg_tremor_magnitude'] as num?)?.toDouble();
      final avgFoodTemp = (stats['avg_food_temp'] as num?)?.toDouble();

      // avg_tremor_magnitude is the mean of stored score values (0–3 scale).
      // No remapping needed — clamp directly to 0–3. NULL (no bite carried a
      // tremor reading) stays NULL: this is the FINAL record a clinician reads,
      // so "not measured" must never be recorded as a measured 0.0.
      final finalTremorIndex = avgMag?.clamp(0.0, 3.0);

      // Eating speed from DB count + actual elapsed time
      final eatingSpeed = (sessionDurationSeconds > 0 && dbBiteCount > 0)
          ? (dbBiteCount / sessionDurationSeconds) * 60.0
          : 0.0;

      // Final meal record — overwrites in-progress upsert with complete stats
      final movement = _mealMovement;
      final meal = Meal(
        uuid: capturedMealUuid,
        userId: userId,
        // deviceId stays null (backend device_id is a UUID FK, not a BLE
        // address); spoonKey carries per-spoon attribution.
        spoonKey: capturedSpoonKey.isNotEmpty ? capturedSpoonKey : null,
        startedAt: capturedStartTime,
        endedAt: endTime,
        mealType: capturedMealType,
        totalBites: dbBiteCount,
        avgPaceBpm: eatingSpeed,
        tremorIndex: finalTremorIndex,
        steadyPct: movement.steady,
        rhythmHz: movement.hz,
        measuredSeconds: movement.seconds,
        movementSource: 'ai_lab',
        durationMinutes: sessionDurationSeconds / 60.0,
        avgFoodTemp: (avgFoodTemp != null && avgFoodTemp > 0)
            ? avgFoodTemp
            : null,
      );

      final db = DatabaseService();
      await db.insertMeal(meal);

      // Feed this completed meal into the per-person adaptive model so it learns
      // THIS spoon-owner's eating habits (pace, duration, bites, tremor) and can
      // personalize insights after enough meals. Fire-and-forget; ignores empty
      // meals internally.
      if (capturedSpoonKey.isNotEmpty && dbBiteCount > 0) {
        unawaited(PersonalizedEatingModel().recordMeal(
          spoonKey: capturedSpoonKey,
          bites: dbBiteCount,
          paceBpm: eatingSpeed,
          durationMinutes: sessionDurationSeconds / 60.0,
          tremor: finalTremorIndex ?? -1.0, // Issue #9: -1 = not measured (skip EWMA update)
          // Breakfast and dinner are not the same meal; the model keeps a
          // separate pace baseline per type and pools it toward the overall
          // mean until that type has enough samples of its own.
          mealType: capturedMealType,
        ));
      }

      // Reload snapshot so UI shows updated totals immediately
      await _loadTodaySnapshot();

      // Trigger sync only when connected
      SyncService().syncIfNeeded();

      // Show daily summary if this is the evening meal or goal just reached
      triggerDailySummary();

      // Cancel evening nudge if goal is reached
      if (dbBiteCount >= dailyBiteGoal) {
        SmartReminderService().onGoalReached();
      }

      debugPrint(
        '[UDS] ✅ Session ended: $dbBiteCount bites, ${sessionDurationSeconds}s, user=$userId',
      );
    } finally {
      // Always clean up session state and reset baseline, even if an error occurred
      _sessionTempReadings.clear();
      // Same counter as the tick reads — see the session-start note.
      getSession(_sessionDeviceId).lastHardwareBiteCount =
          _aiLab.detectedBiteCount;
      _isEndingSession = false;
      notifyListeners();
    }
  }

  void _startUsageTimer() {
    _usageTimer?.cancel();
    _usageTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Use debounced notification if high frequency updates are expected elsewhere
      // For seconds timer, it's okay, but let's be safe.
      notifyListeners();
    });
  }

  // Memory Safety: Limit stored temperature readings
  void _addTempReading(double temp) {
    if (temp <= 0) return;
    _sessionTempReadings.add(temp);
    // Keep only last 1000 readings (approx 16 mins at 1Hz) to prevent overflow
    if (_sessionTempReadings.length > 1000) {
      _sessionTempReadings.removeRange(0, _sessionTempReadings.length - 1000);
    }
  }

  // Helper: Determine Meal Type based on time of day
  String _getMealTypeByTime() =>
      PersonalizedEatingModel.mealTypeForHour(DateTime.now().hour);

  /// Build and show the daily summary notification from today's DB data.
  /// Only fires in the evening (after 18:00) to avoid noise during the day.
  Future<void> triggerDailySummary() async {
    final hour = DateTime.now().hour;
    if (hour < 18) return; // only show in the evening

    try {
      final userId = FirebaseAuth.instance.currentUser?.uid;
      if (userId == null) return;

      final today = DateTime.now();
      final summaries = await DatabaseService().getDailySummaries(
        userId: userId,
        start: DateTime(today.year, today.month, today.day),
        end: today,
      );

      if (summaries.isEmpty) return;
      final s = summaries.first;

      final totalBites = (s['total_bites'] as num?)?.toInt() ?? 0;
      if (totalBites == 0) return; // nothing to summarise

      final movementIndex = (s['avg_tremor_magnitude'] as num?)?.toDouble();
      final movementLevel = movementIndex == null
          ? 'Not measured'
          : movementIndex <= TremorResult.moderateThreshold
          ? 'No rhythm'
          : movementIndex <= TremorResult.highThreshold
          ? 'Some'
          : 'More';

      await NotificationService().showDailySummary({
        'total_bites': totalBites,
        'goal_bites': dailyBiteGoal,
        'breakfast': (s['breakfast_bites'] as num?)?.toInt() ?? 0,
        'lunch': (s['lunch_bites'] as num?)?.toInt() ?? 0,
        'dinner': (s['dinner_bites'] as num?)?.toInt() ?? 0,
        'snack': (s['snack_bites'] as num?)?.toInt() ?? 0,
        'movement_level': movementLevel,
        'avg_temp_c': s['avg_food_temp_c'],
      });
    } catch (e) {
      debugPrint('[UDS] triggerDailySummary error: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _runtime.removeListener(_onMcuUpdate);
    _tremorService.removeListener(_onTremorServiceUpdate);
    _aiLab.removeListener(_onAiLabUpdate);
    _sensorBatchSub?.cancel();
    _authStateSub?.cancel();
    _stopUsageTimer();
    _periodicRefreshTimer?.cancel();
    _bgPollTimer?.cancel();
    getSession(_sessionDeviceId).sessionInactivityTimer?.cancel();
    _motionService.dispose();
    super.dispose();
  }
}
