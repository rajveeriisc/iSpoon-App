// primary_reclaim_monitor.dart — decides WHEN the app may move back to the
// user's primary spoon after running on a fallback.
//
// Follows design §8.7 (PrimaryReclaimMonitor) and §13 (Primary Spoon Return
// Policy), plus Rule 6 and edge cases #11, #12, #13 in §36.
//
// The design lists "primary-return grace policy was documented but not
// implemented" as bug #13. The policy has three hard gates, and every one of
// them exists to stop the app yanking a working link out from under the user:
//
//   1. Never during an active meal (Rule 6 / edge case #12).
//   2. Never inside a manual-override cooldown — if the user deliberately
//      picked the fallback, that choice stands (edge case #13).
//   3. The primary must be seen STABLY for a grace period first, so a single
//      distant advertisement cannot trigger a switch (edge case #11).
library;

import 'package:smartspoon/ble/constants.dart';

/// Why a reclaim is or is not allowed — surfaced for logging (design §38).
enum ReclaimBlockReason {
  allowed,
  noPrimaryConfigured,
  alreadyOnPrimary,
  mealActive,
  manualOverrideCooldown,
  coordinatorBusy,
  primaryNotSeen,
  primaryNotStableYet,
}

/// Tracks primary-spoon sightings and answers "may I switch back now?".
///
/// Owns no BLE: it is fed sightings and asked for a verdict.
class PrimaryReclaimMonitor {
  PrimaryReclaimMonitor({
    Duration? grace,
    Duration? manualCooldown,
  })  : _grace = grace ?? BleConstants.primaryReclaimGrace,
        _manualCooldown = manualCooldown ?? BleConstants.manualOverrideCooldown;

  final Duration _grace;
  final Duration _manualCooldown;

  /// Longest gap between two sightings that still counts as one continuous run.
  /// Comfortably above the advertising interval, far below the reclaim scan
  /// period, so it separates "briefly missed a packet" from "radio was off".
  static const Duration _observationGap = Duration(seconds: 5);

  /// When the primary was FIRST seen in the current continuous run of
  /// sightings. Reset the moment it goes missing, so the grace measures
  /// genuine stability rather than total time since the app started.
  DateTime? _primaryStableSince;
  DateTime? _primaryLastSeen;
  DateTime? _manualOverrideAt;
  String? _manualOverrideSerial;

  /// Record that the user deliberately chose a spoon. Starts the cooldown
  /// during which reclaim must not fight that choice.
  ///
  /// [spoonSerial] is what makes the §9.3 "manual cooldown target" row
  /// reachable: the cooldown is not only a veto on reclaiming the primary, it
  /// also keeps the chosen spoon ranked above the primary for the whole
  /// cooldown, so a scan triggered by an unrelated disconnect returns to the
  /// user's choice rather than quietly to the primary (edge case #13).
  void recordManualOverride([String? spoonSerial]) {
    _manualOverrideAt = DateTime.now();
    _manualOverrideSerial = spoonSerial;
  }

  void clearManualOverride() {
    _manualOverrideAt = null;
    _manualOverrideSerial = null;
  }

  /// The spoon the user chose, while [isManualOverrideActive]. Null outside
  /// the cooldown so a stale choice cannot leak into a later scan.
  String? get manualOverrideSerial =>
      isManualOverrideActive ? _manualOverrideSerial : null;

  DateTime? get manualOverrideAt =>
      isManualOverrideActive ? _manualOverrideAt : null;

  bool get isManualOverrideActive {
    final at = _manualOverrideAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < _manualCooldown;
  }

  /// Feed a sighting of the primary spoon.
  ///
  /// [isStable] should come from `SpoonCandidate.isStable` — an unstable
  /// sighting keeps the link alive but does NOT start the grace clock.
  void observePrimary({required bool isStable}) {
    final now = DateTime.now();

    // Continuity is measured in OBSERVED time, not wall-clock time. Reclaim
    // scans run for ~9s once a minute, so a primary first seen late in one
    // window used to carry its grace clock across the ~50s the radio was off
    // and come back "continuously stable for 65 seconds" — a claim nothing had
    // actually observed. If the spoon was switched off during that silence,
    // the next window reclaimed onto a dead device. A gap longer than a
    // sighting interval means we simply were not looking, so the run restarts.
    final last = _primaryLastSeen;
    if (last != null && now.difference(last) > _observationGap) {
      _primaryStableSince = null;
    }

    _primaryLastSeen = now;
    if (!isStable) {
      _primaryStableSince = null;
      return;
    }
    _primaryStableSince ??= now;
  }

  /// The primary was not seen in this scan window — restart the grace clock.
  void onPrimaryMissing() {
    _primaryStableSince = null;
  }

  /// How long the primary has been continuously stable, or null.
  ///
  /// Measured to the LAST SIGHTING, not to now: time after the scan window
  /// closed was never observed, and counting it is what let grace be met
  /// during radio silence.
  Duration? get stableFor {
    final since = _primaryStableSince;
    if (since == null) return null;
    final last = _primaryLastSeen;
    if (last == null || last.isBefore(since)) return Duration.zero;
    return last.difference(since);
  }

  bool get hasMetGrace {
    final d = stableFor;
    return d != null && d >= _grace;
  }

  DateTime? get primaryLastSeen => _primaryLastSeen;

  /// The full §13 decision.
  ///
  /// Every gate is checked explicitly and the blocking one is returned, so the
  /// log can say WHY a reclaim did not happen instead of going silent.
  ReclaimBlockReason evaluate({
    required String? primarySerial,
    required String? activeSerial,
    required bool mealActive,
    required bool coordinatorBusy,
  }) {
    if (primarySerial == null || primarySerial.isEmpty) {
      return ReclaimBlockReason.noPrimaryConfigured;
    }
    if (activeSerial == primarySerial) {
      return ReclaimBlockReason.alreadyOnPrimary;
    }
    // Rule 6 / edge case #12 — an active meal is never interrupted.
    if (mealActive) return ReclaimBlockReason.mealActive;
    // Edge case #13 — the user's explicit choice outranks the primary flag.
    if (isManualOverrideActive) {
      return ReclaimBlockReason.manualOverrideCooldown;
    }
    if (coordinatorBusy) return ReclaimBlockReason.coordinatorBusy;
    if (_primaryStableSince == null) return ReclaimBlockReason.primaryNotSeen;
    if (!hasMetGrace) return ReclaimBlockReason.primaryNotStableYet;
    return ReclaimBlockReason.allowed;
  }

  /// Design §8.7 / §37: reclaim scanning is a battery cost with no user-facing
  /// urgency, so it runs only in the foreground. In the background the app
  /// keeps whatever link it has.
  bool shouldRunReclaimScan({
    required bool appInForeground,
    required bool mealActive,
    required String? primarySerial,
    required String? activeSerial,
  }) {
    if (!appInForeground) return false;
    if (mealActive) return false;
    if (primarySerial == null || primarySerial.isEmpty) return false;
    if (activeSerial == primarySerial) return false;
    if (isManualOverrideActive) return false;
    return true;
  }

  void reset() {
    _primaryStableSince = null;
    _primaryLastSeen = null;
  }
}
