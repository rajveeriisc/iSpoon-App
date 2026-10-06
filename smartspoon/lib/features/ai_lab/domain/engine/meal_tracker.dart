// meal_tracker.dart — when a meal starts, pauses and ends.
//
// A single detected bite is not a meal: the spoon can be lifted to taste,
// moved, or shown to someone. A meal starts when a second bite follows the
// first within [startWindow]; both are counted. It pauses after [pauseAfter]
// without a bite and ends after [endAfter]. Meals under [minBites] are
// discarded.

import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart'
    show steadyPctOf;

enum MealPhase { idle, eating, paused, finished }

enum MealEndReason { timeout, userFinished, spoonChanged }

class BiteEvent {
  const BiteEvent({
    required this.time,
    required this.probability,
    this.rhythmicShare = 0,
  });

  /// When the spoon reached the mouth.
  final DateTime time;

  /// Model confidence at that moment (0–1).
  final double probability;

  /// Share of the steadiness windows around this bite that were rhythmic.
  final double rhythmicShare;
}

class MealRecord {
  const MealRecord({
    required this.start,
    required this.end,
    required this.bites,
    required this.windows,
    required this.rhythmicWindows,
    this.activeWindows = 0,
    required this.rhythmHz,
    required this.reason,
  });

  final DateTime start;
  final DateTime end;
  final List<BiteEvent> bites;

  /// Steadiness windows analysed during the meal, and how many were rhythmic.
  final int windows;
  final int rhythmicWindows;

  /// Of [windows], how many carried enough movement to be evidence about a
  /// hand. This is the denominator for steadiness — see steadyPctOf. Stored
  /// so a saved figure stays interpretable: 80% over 6 active windows and 80%
  /// over 600 are not the same claim.
  final int activeWindows;

  /// Mean frequency of the rhythmic windows, or null when there were none.
  final double? rhythmHz;
  final MealEndReason reason;

  double? get steadyPct => steadyPctOf(activeWindows, rhythmicWindows);

  /// Seconds of movement the steadiness figure rests on (one window ~ 1 s).
  int get measuredSeconds => activeWindows;
}

class MealTracker {
  MealTracker({
    this.startWindow = const Duration(seconds: 30),
    this.pauseAfter = const Duration(seconds: 60),
    this.endAfter = const Duration(minutes: 3),
    this.minBites = 3,
  });

  final Duration startWindow;
  final Duration pauseAfter;
  final Duration endAfter;
  final int minBites;

  MealPhase _phase = MealPhase.idle;
  BiteEvent? _pending;
  final List<BiteEvent> _bites = [];
  DateTime? _start;
  int _windows = 0;
  int _activeWindows = 0;
  int _rhythmic = 0;
  double _rhythmHzSum = 0;
  MealRecord? _lastMeal;

  MealPhase get phase => _phase;

  /// A first bite is waiting for a second one to start a meal.
  bool get hasPendingBite => _pending != null;
  bool get inMeal => _phase == MealPhase.eating || _phase == MealPhase.paused;
  List<BiteEvent> get bites => List.unmodifiable(_bites);
  DateTime? get start => _start;
  DateTime? get lastBiteAt => _bites.isEmpty ? null : _bites.last.time;
  int get windows => _windows;
  int get activeWindows => _activeWindows;
  int get rhythmicWindows => _rhythmic;
  double? get rhythmHz => _rhythmic == 0 ? null : _rhythmHzSum / _rhythmic;

  /// The most recent saved meal (shown as the summary while [phase] is
  /// finished).
  MealRecord? get lastMeal => _lastMeal;

  void onBite(BiteEvent bite) {
    if (inMeal) {
      _bites.add(bite);
      _phase = MealPhase.eating;
      return;
    }
    final pending = _pending;
    if (pending != null && bite.time.difference(pending.time) <= startWindow) {
      _bites
        ..clear()
        ..add(pending)
        ..add(bite);
      _start = pending.time;
      _windows = 0;
      _activeWindows = 0;
      _rhythmic = 0;
      _rhythmHzSum = 0;
      _pending = null;
      _phase = MealPhase.eating;
      return;
    }
    _pending = bite;
  }

  /// One steadiness window; counted only while a meal is running.
  ///
  /// [active] is whether the window carried real movement. An inactive window
  /// still advances [windows] (it is airtime we analysed) but must not reach
  /// [activeWindows] or the rhythmic tally, so an untouched spoon cannot
  /// accumulate a steadiness score.
  void onWindow({
    required bool rhythmic,
    required bool active,
    required double hz,
  }) {
    if (!inMeal) return;
    _windows++;
    if (!active) return;
    _activeWindows++;
    if (rhythmic) {
      _rhythmic++;
      _rhythmHzSum += hz;
    }
  }

  /// Advances the clock. Returns the saved meal when it ends by timeout.
  MealRecord? tick(DateTime now) {
    final pending = _pending;
    if (pending != null && now.difference(pending.time) > startWindow) {
      _pending = null;
    }
    if (!inMeal) return null;
    final quiet = now.difference(_bites.last.time);
    if (quiet >= endAfter) return finish(now, MealEndReason.timeout);
    if (quiet >= pauseAfter) _phase = MealPhase.paused;
    return null;
  }

  /// Ends the running meal. Returns the saved meal, or null when there was no
  /// meal or it was too short to keep.
  MealRecord? finish(DateTime now, MealEndReason reason) {
    _pending = null;
    if (!inMeal) return null;
    MealRecord? saved;
    if (_bites.length >= minBites) {
      saved = MealRecord(
        start: _start!,
        end: reason == MealEndReason.timeout ? _bites.last.time : now,
        bites: List.unmodifiable(_bites),
        windows: _windows,
        activeWindows: _activeWindows,
        rhythmicWindows: _rhythmic,
        rhythmHz: rhythmHz,
        reason: reason,
      );
      _lastMeal = saved;
    }
    _bites.clear();
    _start = null;
    _windows = 0;
    _rhythmic = 0;
    _rhythmHzSum = 0;
    _phase = _lastMeal != null ? MealPhase.finished : MealPhase.idle;
    return saved;
  }
}
