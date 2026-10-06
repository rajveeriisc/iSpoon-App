// meal_session_guard.dart — protects an in-progress meal from silent spoon
// switching.
//
// Follows design §12 (Meal Session Recovery), Rule 5 (active meal is sticky)
// and Rule 6 (primary priority does not override an active meal).
//
// The rule this enforces is a PRODUCT rule, not a BLE one: a meal's analytics
// belong to one spoon. If spoon A drops mid-meal, the app must try A and only
// A for a bounded budget, then PAUSE and ask — never quietly continue the same
// meal on spoon B, because that would silently merge two people's data.
library;

import 'package:smartspoon/ble/constants.dart';

/// What the guard says the coordinator may do right now.
enum MealGuardVerdict {
  /// No meal in progress — normal selection rules apply.
  noMeal,

  /// Meal active and this IS the meal's spoon. Reconnect it.
  allowSameSpoon,

  /// Meal active, different spoon, no user confirmation. Refuse (Rule 5).
  blockOtherSpoon,

  /// Budget spent. Meal is paused; the user must choose (design §12.1).
  budgetExpired,
}

/// Design §12.2 — what happens when the user confirms a different spoon.
enum MealSwitchPolicy {
  /// End/pause the current meal and start a new one with the new spoon.
  strict,

  /// Keep one meal made of segments, each tagged with its own spoon serial.
  segmented,
}

/// Guards the active meal. Owns no BLE and performs no I/O — it answers
/// questions and tracks the reconnect budget.
class MealSessionGuard {
  MealSessionGuard({
    this.policy = MealSwitchPolicy.strict,
    Duration? reconnectBudget,
    int? maxAttempts,
  })  : _reconnectBudget = reconnectBudget ?? BleConstants.mealReconnectBudget,
        _maxAttempts = maxAttempts ?? BleConstants.mealReconnectMaxAttempts;

  final MealSwitchPolicy policy;
  final Duration _reconnectBudget;
  final int _maxAttempts;

  String? _mealSpoonSerial;
  DateTime? _interruptedAt;
  int _reconnectAttempts = 0;
  bool _paused = false;

  /// Fires when the budget runs out and the meal must be paused.
  ///
  /// The design lists "onMealInterrupted existed but was never called" as bug
  /// #12 — this callback exists precisely so the coordinator cannot forget.
  void Function(String spoonSerial)? onMealInterrupted;

  bool get isMealActive => _mealSpoonSerial != null;
  String? get mealSpoonSerial => _mealSpoonSerial;
  bool get isPaused => _paused;
  int get reconnectAttempts => _reconnectAttempts;

  void startMeal(String spoonSerial) {
    _mealSpoonSerial = spoonSerial;
    _interruptedAt = null;
    _reconnectAttempts = 0;
    _paused = false;
  }

  void endMeal() {
    _mealSpoonSerial = null;
    _interruptedAt = null;
    _reconnectAttempts = 0;
    _paused = false;
  }

  /// The meal's spoon dropped. Starts the bounded recovery window.
  void onMealSpoonDisconnected() {
    if (!isMealActive || _paused) return;
    _interruptedAt ??= DateTime.now();
  }

  /// The meal's spoon came back and is streaming again.
  void onMealSpoonRecovered() {
    _interruptedAt = null;
    _reconnectAttempts = 0;
    _paused = false;
  }

  /// Whether another reconnect attempt for the meal spoon is still allowed.
  ///
  /// Design §12.1 is explicit: "Do not retry every 2 seconds forever." Both a
  /// time budget AND an attempt cap apply, and the doc lists infinite
  /// same-spoon retry as bug #11.
  bool canAttemptReconnect() {
    if (!isMealActive || _paused) return false;
    final since = _interruptedAt;
    if (since == null) return true;

    final withinTime = DateTime.now().difference(since) <= _reconnectBudget;
    final withinAttempts = _reconnectAttempts < _maxAttempts;
    return withinTime && withinAttempts;
  }

  /// Call immediately before each reconnect attempt.
  void recordReconnectAttempt() => _reconnectAttempts++;

  /// Ask what the coordinator may do with [candidateSerial] right now.
  ///
  /// [userConfirmed] must be true ONLY for an explicit user choice — Rule 5
  /// allows another spoon during a meal only after confirmation.
  MealGuardVerdict evaluate(
    String candidateSerial, {
    bool userConfirmed = false,
  }) {
    if (!isMealActive) return MealGuardVerdict.noMeal;
    if (candidateSerial == _mealSpoonSerial) {
      return canAttemptReconnect()
          ? MealGuardVerdict.allowSameSpoon
          : MealGuardVerdict.budgetExpired;
    }
    // A different spoon. Only an explicit confirmation gets through.
    if (userConfirmed) return MealGuardVerdict.noMeal;
    return MealGuardVerdict.blockOtherSpoon;
  }

  /// Budget spent: pause the meal and notify exactly once.
  void pauseMealAndNotify() {
    if (_paused || !isMealActive) return;
    _paused = true;
    final serial = _mealSpoonSerial;
    if (serial != null) onMealInterrupted?.call(serial);
  }

  /// Convenience for the coordinator's recovery loop: returns true when the
  /// budget has just been exhausted, having paused and notified.
  bool checkBudgetAndPauseIfExpired() {
    if (!isMealActive || _paused) return false;
    if (_interruptedAt == null) return false;
    if (canAttemptReconnect()) return false;
    pauseMealAndNotify();
    return true;
  }
}
