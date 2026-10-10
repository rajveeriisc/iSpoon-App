// ai_lab_service.dart — runs the AI Lab eating engine on the live spoon.
//
// Started with the app, so a meal begun on another tab is not missed. Its
// numbers are the app's only bite and steadiness source: UnifiedDataService
// reads them here, so Home, Insights, Meals Analysis and the AI Lab page all
// agree. Follows one spoon at a time: a
// different spoon takes over only after the current one has been silent for
// [_silentSwitch] (a make-before-break switch briefly streams both).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:smartspoon/ble/models/runtime_models.dart';
import 'package:smartspoon/ble/spoon_runtime.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/eating_engine.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/handedness.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/meal_tracker.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/steadiness_analyzer.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';
import 'package:smartspoon/features/ai_lab/domain/services/personalized_eating_model.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_profile_store.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_view_data.dart';
import 'package:smartspoon/features/ai_lab/domain/services/training_recorder.dart';

class AiLabService extends ChangeNotifier implements AiLabActions {
  static final AiLabService _instance = AiLabService._internal();
  factory AiLabService() => _instance;
  AiLabService._internal();

  static const Duration _silentSwitch = Duration(seconds: 2);
  static const Duration _streamingWithin = Duration(seconds: 3);
  static const Duration _chartPublishEvery = Duration(milliseconds: 200);
  static const int _chartLength = 200;

  final AiLabProfileStore profiles = AiLabProfileStore();
  final TrainingRecorder recorder = TrainingRecorder();
  final ValueNotifier<List<double>> _liveGyro = ValueNotifier(const []);

  @override
  ValueListenable<List<double>> get liveGyro => _liveGyro;

  AiLabModel? _model;
  EatingEngine? _engine;
  String? _error;
  Future<void>? _starting;
  StreamSubscription<List<McuSensorData>>? _sub;
  Timer? _ticker;

  String? _deviceId;
  String _spoonKey = '';
  DateTime? _lastSampleWall;
  bool _wasStreaming = false;
  MealPhase _lastPhase = MealPhase.idle;
  SteadinessResult? _lastWindow;
  final List<double> _chart = [];
  DateTime _chartPublishedAt = DateTime.fromMillisecondsSinceEpoch(0);

  // The meal that just ended: its tips were computed against the baseline as
  // it was BEFORE this meal was added to it.
  MealMetrics? _finishedMetrics;
  List<CoachTip> _finishedTips = const [];
  int _finishedMeasuredSeconds = 0;

  /// Steadiness of the meal that just ended, for the record the app writes to
  /// the database — by then the meal figure above is already cleared.
  double? get finishedMealSteadyPct => _finishedMetrics?.steadyPct;
  double? get finishedMealRhythmHz => _finishedMetrics?.rhythmHz;

  /// Seconds of that meal the model actually measured.
  int get finishedMealMeasuredSeconds => _finishedMeasuredSeconds;

  // ── What the rest of the app reads ──────────────────────────────────────
  // UnifiedDataService takes its bites and its tremor index from here, so
  // Home, Insights, Meals Analysis and AI Lab all show one set of numbers
  // instead of three services counting separately.
  int _detectedBites = 0;
  int _mealBitesSeen = 0;
  DateTime? _lastBiteAt;
  double _lastBiteRhythmicShare = 0;

  /// The last minute of steadiness windows, so a live tremor reading exists
  /// between meals too (the meal's own totals live in [MealTracker]).
  static const int _recentWindowLimit = 60;

  /// Fewer windows than this is not a reading. Defined once, in
  /// eating_insights.dart, alongside the formula that applies it.
  static const int minSteadyWindows = kMinSteadyWindows;
  final List<({bool rhythmic, bool active, double hz})> _recentWindows = [];
  DateTime? _lastWindowAt;

  /// Bites that belong to a meal, since the app started. Monotonic, like the
  /// firmware counter it replaces, so callers keep working in deltas.
  ///
  /// A single lift that never became a meal is NOT counted — the AI Lab page
  /// drops it, so no other screen may keep it. When a meal starts, its first
  /// two bites arrive together here, exactly as the page shows them.
  int get detectedBiteCount => _detectedBites;

  /// True while a meal is running, so the app's own meal session can end when
  /// this one does instead of on a separate timer.
  bool get inMeal => _engine?.tracker.inMeal ?? false;

  /// The spoon the model is following. Readings belong to this spoon only.
  String? get activeDeviceId => _deviceId;

  /// Null until the engine has actually seen sensor data. Callers must be able
  /// to tell "no data yet" apart from a real zero, or they baseline on nothing.
  int? get detectedBiteCountOrNull =>
      _engine == null || _lastSampleWall == null ? null : _detectedBites;

  DateTime? get lastBiteAt => _lastBiteAt;

  /// Share of the steadiness windows around the most recent bite that were
  /// rhythmic (0–1), stored with that bite.
  double get lastBiteRhythmicShare => _lastBiteRhythmicShare;

  DateTime? get lastWindowAt => _lastWindowAt;

  int get recentWindowCount => _recentWindows.length;

  /// Of the last minute's windows, how many carried real hand movement.
  /// This is the evidence base for every steadiness figure below.
  int get recentActiveWindowCount =>
      _recentWindows.where((w) => w.active).length;

  /// Steadiness over the last minute, or null before there is enough to say.
  ///
  /// Divides by ACTIVE windows only. Dividing by all of them let a spoon
  /// resting on a table report 100% steady after five seconds of streaming.
  double? get recentSteadyPct => steadyPctOf(
      recentActiveWindowCount,
      _recentWindows.where((w) => w.active && w.rhythmic).length);

  /// Steadiness of the meal in progress — the number the AI Lab page shows.
  /// Every other screen prefers this one while a meal is running, so Home and
  /// AI Lab can never disagree; the rolling minute above is the fallback
  /// between meals, where there is no meal figure yet.
  double? get mealSteadyPct {
    final t = _engine?.tracker;
    if (t == null || !t.inMeal) return null;
    return steadyPctOf(t.activeWindows, t.rhythmicWindows);
  }

  int get mealWindowCount => _engine?.tracker.windows ?? 0;

  /// Windows in the running meal that carried real movement.
  int get mealActiveWindowCount => _engine?.tracker.activeWindows ?? 0;

  double? get mealRhythmHz => _engine?.tracker.rhythmHz;

  /// Mean frequency of the rhythmic windows in the last minute.
  double? get recentRhythmHz {
    final shaky = _recentWindows.where((w) => w.active && w.rhythmic).toList();
    if (shaky.isEmpty) return null;
    return shaky.map((w) => w.hz).reduce((a, b) => a + b) / shaky.length;
  }

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    try {
      _model =
          AiLabModel.parse(await rootBundle.loadString(AiLabModel.assetPath));
    } catch (e) {
      _error = 'The eating model could not be loaded ($e).';
      debugPrint('[AiLab] $_error');
      notifyListeners();
      return;
    }
    await profiles.load();
    await recorder.loadSavedCount();
    profiles.addListener(notifyListeners);
    _engine = EatingEngine(_model!);
    _sub = SpoonRuntime().sensorBatchStream.listen(_onBatch);
    notifyListeners();
  }

  String _keyFor(String deviceId) {
    if (deviceId.isEmpty) return '';
    final saved = SpoonRuntime()
        .previousDevices
        .where((d) => d.id == deviceId)
        .firstOrNull;
    final pid = saved?.productId;
    return (pid != null && pid.isNotEmpty) ? pid : deviceId;
  }

  bool _isStreaming(DateTime now) {
    final last = _lastSampleWall;
    return last != null && now.difference(last) < _streamingWithin;
  }

  void _onBatch(List<McuSensorData> batch) {
    if (_engine == null || batch.isEmpty) return;
    final now = DateTime.now();
    var changed = false;
    for (final s in batch) {
      final id = s.deviceId;
      if (id.isNotEmpty && id != _deviceId) {
        final last = _lastSampleWall;
        final silent = _deviceId == null ||
            last == null ||
            now.difference(last) > _silentSwitch;
        if (!silent) continue;
        _switchTo(id, now);
        changed = true;
      }
      final engine = _engine!;
      final u = engine.feed(
        tsMs: s.timestamp.millisecondsSinceEpoch,
        ax: s.accelX,
        ay: s.accelY,
        az: s.accelZ,
        gx: s.gyroX,
        gy: s.gyroY,
        gz: s.gyroZ,
      );
      recorder.addSample(s,
          phase: engine.tracker.phase.name, share: _lastWindow?.share ?? 0);
      final window = u.window;
      if (window != null) {
        if (_lastWindow?.rhythmic != window.rhythmic) changed = true;
        _lastWindow = window;
        _recentWindows.add((
          rhythmic: window.rhythmic,
          active: window.active,
          hz: window.hz,
        ));
        if (_recentWindows.length > _recentWindowLimit) {
          _recentWindows.removeAt(0);
        }
        _lastWindowAt = now;
      }
      final bite = u.bite;
      if (bite != null) {
        recorder.markDetected(bite.time);
        _lastBiteAt = bite.time;
        _lastBiteRhythmicShare = bite.rhythmicShare;
        changed = true;
      }
      // Count only what the meal keeps. `bites.length` goes 0 → 2 when a meal
      // starts (the waiting first bite plus the one that confirmed it), then
      // +1 per bite, and back to 0 when the meal ends — so tracking increases
      // gives a monotonic total that matches the page exactly.
      final mealBites = engine.tracker.inMeal ? engine.tracker.bites.length : 0;
      if (mealBites > _mealBitesSeen) {
        _detectedBites += mealBites - _mealBitesSeen;
      }
      _mealBitesSeen = mealBites;
      final hand = u.decidedHand;
      if (hand != null) {
        unawaited(profiles.setDetectedHand(_spoonKey, hand));
        changed = true;
      }
      _chart.add(s.gyroMagnitude);
    }
    _lastSampleWall = now;
    if (_chart.length > _chartLength) {
      _chart.removeRange(0, _chart.length - _chartLength);
    }
    if (now.difference(_chartPublishedAt) >= _chartPublishEvery) {
      _chartPublishedAt = now;
      _liveGyro.value = List.unmodifiable(_chart);
    }
    final phase = _engine!.tracker.phase;
    if (phase != _lastPhase || !_wasStreaming) changed = true;
    _lastPhase = phase;
    _wasStreaming = true;
    _ensureTicker();
    if (changed) notifyListeners();
  }

  /// Feeds samples as if they had arrived from the spoon, so the wiring the
  /// rest of the app depends on (bite total, steadiness) can be tested with a
  /// recorded meal instead of a live device.
  @visibleForTesting
  void debugFeed(List<McuSensorData> batch) => _onBatch(batch);

  void _switchTo(String deviceId, DateTime now) {
    final old = _engine;
    if (old != null && _deviceId != null) {
      _endMeal(old, () => old.finish(now, MealEndReason.spoonChanged));
    }
    _deviceId = deviceId;
    _spoonKey = _keyFor(deviceId);
    final p = profiles.profileFor(_spoonKey);
    _engine = EatingEngine(
      _model!,
      voter: HandednessVoter(
        votesToDecide: _model!.votesToDecide,
        preference: p.handPreference,
        detected: p.detectedHand,
      ),
    );
    _lastWindow = null;
    _recentWindows.clear();
    _lastWindowAt = null;
    _finishedMetrics = null;
    _finishedTips = const [];
    _chart.clear();
  }

  /// The 1 s tick exists only while something needs timing: a running meal,
  /// a first bite waiting for its second, a recording, or a live stream. With
  /// the spoon idle there is no periodic wake-up at all.
  void _ensureTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _onTick() {
    final engine = _engine;
    if (engine == null) return;
    final now = DateTime.now();
    final meal = _endMeal(engine, () => engine.tick(now));
    final streaming = _isStreaming(now);
    final phase = engine.tracker.phase;
    final visible = meal != null ||
        streaming != _wasStreaming ||
        phase != _lastPhase ||
        engine.tracker.inMeal ||
        recorder.isRecording;
    _wasStreaming = streaming;
    _lastPhase = phase;
    if (!streaming &&
        !engine.tracker.inMeal &&
        !engine.tracker.hasPendingBite &&
        !recorder.isRecording) {
      _ticker?.cancel();
      _ticker = null;
    }
    if (visible) notifyListeners();
  }

  /// Ends a meal through one path, so the running total always agrees with
  /// what the meal actually recorded.
  ///
  /// Bites are counted optimistically as they arrive, because the page has to
  /// move while you eat. A meal under [MealTracker.minBites] is then thrown
  /// away and never becomes a [MealRecord] — so without this, its bites stayed
  /// in [detectedBiteCount] forever and Home read a total the AI Lab page
  /// could not account for. Every meal end runs through here: kept meals are
  /// saved, discarded ones hand their provisional bites back.
  ///
  /// [end] must perform the end and return the record, if any. It is called
  /// with the tracker still in its pre-end state.
  MealRecord? _endMeal(EatingEngine engine, MealRecord? Function() end) {
    final tracker = engine.tracker;
    final wasInMeal = tracker.inMeal;
    final provisional = wasInMeal ? tracker.bites.length : 0;
    final meal = end();
    final ended = wasInMeal && !tracker.inMeal;
    if (meal != null) {
      _saveMeal(meal, _spoonKey);
    } else if (ended && provisional > 0) {
      _detectedBites = (_detectedBites - provisional).clamp(0, _detectedBites);
    }
    // The next meal counts from zero. Left stale, a meal that ended while the
    // spoon was silent would swallow every bite of the next one up to its own
    // length, because the counter only ever adds an increase.
    if (ended) _mealBitesSeen = 0;
    return meal;
  }

  static MealMetrics _metricsOf(MealRecord r) => MealMetrics.from(
        biteTimes: [for (final b in r.bites) b.time],
        start: r.start,
        end: r.end,
        windows: r.activeWindows,
        rhythmicWindows: r.rhythmicWindows,
        rhythmHz: r.rhythmHz,
      );

  void _saveMeal(MealRecord meal, String spoonKey) {
    final m = _metricsOf(meal);
    _finishedMetrics = m;
    // Active windows only — this is the evidence the saved steady_pct rests
    // on, and the daily rollup weights by it. meal.windows includes time
    // the spoon was sitting still.
    _finishedMeasuredSeconds = meal.activeWindows;
    _finishedTips = coachTips(m,
        baseline: profiles.profileFor(spoonKey).baseline, live: false);
    unawaited(
        profiles.recordMeal(spoonKey, MealSummary.fromMetrics(meal.start, m)));
  }

  // ── Actions ─────────────────────────────────────────────────────────────

  @override
  void finishMeal() {
    final engine = _engine;
    if (engine == null) return;
    _endMeal(engine,
        () => engine.finish(DateTime.now(), MealEndReason.userFinished));
    _lastPhase = engine.tracker.phase;
    notifyListeners();
  }

  @override
  void setHandPreference(HandPreference preference) {
    _engine?.voter.preference = preference;
    unawaited(profiles.setHandPreference(_spoonKey, preference));
    notifyListeners();
  }

  @override
  void startRecording() {
    recorder.start();
    notifyListeners();
  }

  @override
  void markBite() {
    recorder.markBite();
    notifyListeners();
  }

  @override
  void undoMark() {
    recorder.undoMark();
    notifyListeners();
  }

  @override
  void cancelRecording() {
    recorder.cancel();
    notifyListeners();
  }

  @override
  Future<String?> saveRecording() async {
    final path = await recorder.stopAndSave();
    notifyListeners();
    return path;
  }

  // ── View ────────────────────────────────────────────────────────────────

  AiLabViewData get view {
    final now = DateTime.now();
    final engine = _engine;
    final model = _model;
    if (engine == null || model == null) {
      return AiLabViewData(now: now, error: _error);
    }
    final t = engine.tracker;
    final profile = _spoonKey.isEmpty ? null : profiles.profileFor(_spoonKey);
    var bites = const <BiteEvent>[];
    MealMetrics? metrics;
    var tips = const <CoachTip>[];
    DateTime? start, end;
    if (t.inMeal && t.start != null) {
      bites = t.bites;
      start = t.start;
      end = now;
      metrics = MealMetrics.from(
        biteTimes: [for (final b in bites) b.time],
        start: t.start!,
        end: now,
        windows: t.activeWindows,
        rhythmicWindows: t.rhythmicWindows,
        rhythmHz: t.rhythmHz,
      );
      tips = _withPersonalTip(
          coachTips(metrics, baseline: profile?.baseline, live: true),
          metrics);
    } else if (t.phase == MealPhase.finished && t.lastMeal != null) {
      final last = t.lastMeal!;
      bites = last.bites;
      start = last.start;
      end = last.end;
      metrics = _finishedMetrics ?? _metricsOf(last);
      tips = _withPersonalTip(_finishedTips, metrics, finishedAt: last.end);
    } else {
      tips = _idleTips();
    }
    final id = _deviceId;
    return AiLabViewData(
      now: now,
      ready: true,
      streaming: _isStreaming(now),
      spoonName: id == null ? null : SpoonRuntime().getDeviceById(id)?.name,
      phase: t.phase,
      mealStart: start,
      mealEnd: end,
      bites: bites,
      metrics: metrics,
      tips: tips,
      rhythmicNow: _lastWindow?.rhythmic ?? false,
      profile: profile,
      model: model,
      handPreference: engine.voter.preference,
      detectedHand: engine.voter.detected,
      handMode: engine.voter.mode,
      cyclePhase: engine.cyclePhase,
      calibrated: engine.calibrated,
      recorder: RecorderView(
        recording: recorder.isRecording,
        marks: recorder.markCount,
        seconds: recorder.seconds,
        savedCount: recorder.savedCount,
        lastSavedPath: recorder.lastSavedPath,
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    profiles.removeListener(notifyListeners);
    super.dispose();
  }


  /// What the coach says between meals.
  ///
  /// The page used to fall back to one generic sentence here, while the model
  /// already held something no other card shows: this person's pace broken
  /// down BY MEAL TYPE. Everywhere else reports one average across the day,
  /// which hides that most people eat breakfast and dinner quite differently.
  List<CoachTip> _idleTips() {
    if (_spoonKey.isEmpty) return const [];
    final p = PersonalizedEatingModel().profileFor(_spoonKey);
    if (p == null || p.mealCount == 0) return const [];

    if (!p.canPersonalize) {
      final left = PersonalizedProfile.minMealsToPersonalize - p.mealCount;
      return [
        CoachTip(
          id: 'personal_learning',
          kind: TipKind.info,
          title: 'Learning how you eat',
          body: left > 0
              ? '${p.mealCount} meal${p.mealCount == 1 ? '' : 's'} in. After '
                  'about $left more your coach can tell an unusual meal from '
                  'an ordinary one for you specifically.'
              : 'Almost there — a couple more meals and your coach will judge '
                  'each one against your own normal.',
          priority: 65,
        ),
      ];
    }

    // Meal types with enough readings to be worth naming.
    final named = <String, double>{
      for (final e in p.byMealType.entries)
        if (e.value.n >= 3) e.key: p.baselinePaceFor(e.key),
    };
    if (named.length >= 2) {
      final sorted = named.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final fast = sorted.first, slow = sorted.last;
      if ((fast.value - slow.value).abs() >= 2.0) {
        return [
          CoachTip(
            id: 'personal_mealtype',
            kind: TipKind.info,
            title: 'Your meals are not all the same',
            body: 'You eat ${fast.key.toLowerCase()} at about '
                '${fast.value.toStringAsFixed(0)} bites a minute, and '
                '${slow.key.toLowerCase()} at about '
                '${slow.value.toStringAsFixed(0)}. Each meal is judged against '
                'its own pace, not one daily average.',
            priority: 65,
          ),
        ];
      }
    }

    return [
      CoachTip(
        id: 'personal_baseline',
        kind: TipKind.info,
        title: 'Tuned to you',
        body: 'Your usual is about ${p.avgPaceBpm.toStringAsFixed(0)} bites a '
            'minute over roughly ${p.avgMealMinutes.toStringAsFixed(0)} '
            'minutes. Meals that drift from that get flagged.',
        priority: 65,
      ),
    ];
  }

  /// Puts this person's own baseline in front of the generic advice.
  ///
  /// The per-person model existed but nothing ever read it — feedbackForMeal
  /// had no callers, so every tip on this page was the same population rule
  /// for everybody. This is the one piece of coaching that is actually about
  /// the person using the spoon, so it leads when it is available.
  /// [finishedAt] is set for a meal that has ended. During a meal the live
  /// comparison is right — the baseline does not contain this meal yet. Once
  /// it has ended and been recorded, it does, so the verdict the model took
  /// before updating is used instead.
  List<CoachTip> _withPersonalTip(List<CoachTip> base, MealMetrics? m,
      {DateTime? finishedAt}) {
    final pace = m?.bitesPerMin;
    // bitesPerMin is already null under 30 s; a handful of bites is still too
    // few for the rate to be meaningful.
    if (pace == null || m == null || m.bites < 5 || _spoonKey.isEmpty) {
      return base;
    }
    final mealType =
        PersonalizedEatingModel.mealTypeForHour(DateTime.now().hour);
    final model = PersonalizedEatingModel();
    final profile = model.profileFor(_spoonKey);
    // Only trust the stored verdict once the profile has been written since
    // this meal ended; before that it still describes the meal before.
    final recorded = finishedAt != null &&
        profile != null &&
        !profile.updatedAt.isBefore(finishedAt);
    final j = recorded
        ? profile.lastJudgement
        : finishedAt == null
            ? model.judgeMeal(_spoonKey, paceBpm: pace, mealType: mealType)
            : null;
    if (j == null) return base;

    final obs = j.observedPace.toStringAsFixed(0);
    final usual = j.baselinePace.toStringAsFixed(0);
    final tip = switch (j.verdict) {
      PaceVerdict.faster => CoachTip(
          id: 'personal_pace_fast',
          kind: TipKind.nudge,
          title: 'Quicker than your usual',
          body: '$obs bites/min, against the $usual you normally keep at '
              '${mealType.toLowerCase()}. Setting the spoon down between '
              'bites brings it back.',
          priority: 70,
        ),
      PaceVerdict.slower => CoachTip(
          id: 'personal_pace_slow',
          kind: TipKind.positive,
          title: 'Gentler than your usual',
          body: '$obs bites/min, against your usual $usual.',
          priority: 70,
        ),
      PaceVerdict.usual => CoachTip(
          id: 'personal_pace_usual',
          kind: TipKind.positive,
          title: 'On your usual rhythm',
          body: '$obs bites/min — right where your '
              '${mealType.toLowerCase()} meals normally sit.',
          priority: 70,
        ),
    };
    return [tip, ...base].take(3).toList(growable: false);
  }
}
