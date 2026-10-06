// imu_bite_detector_service.dart — adaptive, position-independent software bite counter.
//
// A ChangeNotifier singleton that counts bites purely from the spoon's IMU
// stream, as an alternative/backup to the firmware's own hardware bite counter.
//
// WHY THIS IS ADAPTIVE (and the old fixed-threshold version was not):
// A bite is not an absolute orientation — it's a MOTION PATTERN. The previous
// detector compared accel-X against fixed values (0.64g / 0.42g), which only
// worked for one specific spoon angle and eating posture; lying down, holding
// the spoon differently, or a shorter/longer reach all broke it. This version
// instead:
//   • captures a DYNAMIC "rest" baseline wherever the user holds the spoon while
//     scooping (works in any posture / at any angle), then
//   • measures each lift RELATIVE to that baseline (orientation change), and
//   • requires a COMPLETE cycle: rest → lift → apex → return → rest, validated
//     by how far the spoon actually travelled (peak tilt + integrated rotation)
//     and how long the cycle took.
//
// It is rate-agnostic (uses sample timestamps + a time-constant low-pass), so it
// works whether the firmware streams at 4 Hz (typed) or ~100 Hz (batched).
import 'dart:async';
import 'dart:math' show sqrt, pow;
import 'package:flutter/foundation.dart';
import 'package:smartspoon/ble/models/runtime_models.dart';
import 'package:smartspoon/ble/spoon_runtime.dart';

/// Phase of the current lift cycle (kept public for the debug/lab UI).
enum ImuBitePhase { resting, lifting, returning }

class ImuBiteDetectorService extends ChangeNotifier {
  static final ImuBiteDetectorService _instance =
      ImuBiteDetectorService._internal();
  factory ImuBiteDetectorService() => _instance;
  ImuBiteDetectorService._internal();

  // ── Tunable thresholds ──────────────────────────────────────────────────────
  // All movement thresholds are RELATIVE (to a dynamic baseline), so they hold
  // regardless of eating position or spoon orientation.

  /// Gyro magnitude (deg/s) above which the spoon is "actively moving" — starts
  /// a lift excursion.
  static const double _gyroMoveDps = 30.0;

  /// Gyro magnitude below which the spoon is "still" — used to (re)capture the
  /// rest baseline and to detect the dwell at the mouth.
  static const double _gyroStillDps = 15.0;

  /// Minimum orientation change from the rest baseline (in g, ~1g ≈ 90° of tilt)
  /// for an excursion to qualify as a genuine lift-to-mouth. ~0.30g ≈ ~17–18°.
  /// Filters out scooping wiggles and small nudges.
  static const double _minPeakDevG = 0.30;

  /// Minimum integrated rotation (deg) over the whole cycle — the "distance
  /// travelled" gate. A real lift + return rotates the spoon meaningfully.
  static const double _minTravelDeg = 35.0;

  /// The excursion is considered "returning" once the deviation falls below this
  /// fraction of the peak deviation (i.e. the spoon is heading back to rest).
  static const double _returnFrac = 0.45;

  /// Deviation (g) below which the spoon is considered back near the rest
  /// baseline — completes the cycle.
  static const double _settleDevG = 0.18;

  /// A cycle faster than this is a flick / noise; slower than max is not one
  /// bite (aborted).
  static const int _minCycleMs = 350;
  static const int _maxCycleMs = 9000;

  /// Minimum time between two counted bites.
  static const int _cooldownMs = 1400;

  /// Still-time required to (re)capture the rest baseline.
  static const int _restCaptureMs = 250;

  /// Low-pass time constant (s) for the gravity/orientation estimate — removes
  /// tremor + transient linear-acceleration spikes so `dev` reflects true tilt.
  static const double _gravityTauS = 0.12;

  // ── Internal state ──────────────────────────────────────────────────────────
  ImuBitePhase _phase = ImuBitePhase.resting;

  // Gravity/orientation estimate (low-passed accel) and the captured rest
  // baseline the current excursion is measured against.
  double _gEx = 0, _gEy = 0, _gEz = 0;
  double _restX = 0, _restY = 0, _restZ = 1.0;
  bool _initialized = false;

  DateTime? _prevTs;
  double _stillMs = 0;

  // Per-excursion tracking.
  DateTime? _excursionStart;
  double _peakDev = 0;
  double _peakGyro = 0;
  double _travelDeg = 0;

  DateTime? _lastBiteTime;

  // ── Public API ──────────────────────────────────────────────────────────────
  int _biteCount = 0;
  int get biteCount => _biteCount;
  bool _isMonitoring = false;
  bool get isMonitoring => _isMonitoring;
  ImuBitePhase get phase => _phase;

  // Diagnostics for the debug/lab card (last completed bite).
  double lastPeakDeviation = 0.0; // peak orientation change (g)
  double lastPeakGyro = 0.0; // peak rotation rate (deg/s)
  int lastAwayMs = 0; // cycle duration (ms)
  double lastTravelDeg = 0.0; // integrated rotation over the cycle (deg)

  StreamSubscription<List<McuSensorData>>? _sub;

  void startMonitoring() {
    if (_isMonitoring) return;
    _isMonitoring = true;
    _fullReset();
    _sub = SpoonRuntime().sensorBatchStream.listen(_processBatch);
    debugPrint('[IMU] Started — adaptive kinematic bite detector');
    notifyListeners();
  }

  void stopMonitoring() {
    if (!_isMonitoring) return;
    _sub?.cancel();
    _sub = null;
    _isMonitoring = false;
    debugPrint('[IMU] Stopped');
    notifyListeners();
  }

  void resetCount() {
    _biteCount = 0;
    lastPeakDeviation = 0.0;
    lastPeakGyro = 0.0;
    lastAwayMs = 0;
    lastTravelDeg = 0.0;
    _lastBiteTime = null;
    _resetCycle();
    notifyListeners();
  }

  void _fullReset() {
    _initialized = false;
    _prevTs = null;
    _stillMs = 0;
    resetCount();
  }

  void _resetCycle() {
    _phase = ImuBitePhase.resting;
    _excursionStart = null;
    _peakDev = 0;
    _peakGyro = 0;
    _travelDeg = 0;
  }

  // ── Processing ────────────────────────────────────────────────────────────
  void _processBatch(List<McuSensorData> batch) {
    for (final s in batch) {
      _processSample(s);
    }
  }

  void _processSample(McuSensorData s) {
    final ts = s.timestamp;

    // Bootstrap gravity estimate + rest baseline on the first sample.
    if (!_initialized) {
      _gEx = s.accelX;
      _gEy = s.accelY;
      _gEz = s.accelZ;
      _restX = _gEx;
      _restY = _gEy;
      _restZ = _gEz;
      _prevTs = ts;
      _initialized = true;
      return;
    }

    // Rate-agnostic dt (clamped so a BLE stall can't distort integration).
    var dt = ts.difference(_prevTs!).inMicroseconds / 1e6;
    _prevTs = ts;
    if (dt <= 0) return;
    if (dt > 0.1) dt = 0.1;

    // Time-constant low-pass → gravity/orientation estimate (removes tremor and
    // transient linear-accel spikes so `dev` is a true tilt-change measure).
    final a = dt / (_gravityTauS + dt);
    _gEx += a * (s.accelX - _gEx);
    _gEy += a * (s.accelY - _gEy);
    _gEz += a * (s.accelZ - _gEz);

    final gyro = s.gyroMagnitude; // deg/s
    final dev = _distance(_gEx, _gEy, _gEz, _restX, _restY, _restZ);
    final still = gyro < _gyroStillDps;

    switch (_phase) {
      case ImuBitePhase.resting:
        if (still) {
          // Continuously refresh the rest baseline toward the current
          // orientation once the spoon has been still long enough. This is what
          // makes the detector adapt to ANY eating posture / hold angle.
          _stillMs += dt * 1000;
          if (_stillMs >= _restCaptureMs) {
            const beta = 0.08; // gentle pull so the baseline tracks true rest
            _restX += beta * (_gEx - _restX);
            _restY += beta * (_gEy - _restY);
            _restZ += beta * (_gEz - _restZ);
          }
        } else {
          _stillMs = 0;
          // Start of a lift: active rotation AND the orientation is departing
          // from the rest baseline.
          if (gyro > _gyroMoveDps && dev > _minPeakDevG * 0.4) {
            _phase = ImuBitePhase.lifting;
            _excursionStart = ts;
            _peakDev = dev;
            _peakGyro = gyro;
            _travelDeg = gyro * dt;
          }
        }
        break;

      case ImuBitePhase.lifting:
      case ImuBitePhase.returning:
        _travelDeg += gyro * dt; // integrate rotation = "distance travelled"
        if (gyro > _peakGyro) _peakGyro = gyro;
        if (dev > _peakDev) _peakDev = dev;

        final elapsedMs = ts.difference(_excursionStart!).inMilliseconds;

        // Abort an excursion that never comes back (spoon set down mid-air, or a
        // one-way orientation change that isn't a bite).
        if (elapsedMs > _maxCycleMs) {
          _abortExcursion(ts);
          break;
        }

        // Past the apex and heading back toward rest.
        if (_phase == ImuBitePhase.lifting &&
            _peakDev >= _minPeakDevG &&
            dev < _returnFrac * _peakDev) {
          _phase = ImuBitePhase.returning;
        }

        // Cycle completes when we're back near the rest baseline.
        if (dev < _settleDevG && (_phase == ImuBitePhase.returning || still)) {
          _completeExcursion(ts, elapsedMs);
        }
        break;
    }
  }

  void _completeExcursion(DateTime ts, int cycleMs) {
    final valid = _peakDev >= _minPeakDevG &&
        _travelDeg >= _minTravelDeg &&
        cycleMs >= _minCycleMs &&
        cycleMs <= _maxCycleMs &&
        (_lastBiteTime == null ||
            ts.difference(_lastBiteTime!).inMilliseconds >= _cooldownMs);

    if (valid) {
      _biteCount++;
      lastPeakDeviation = _peakDev;
      lastPeakGyro = _peakGyro;
      lastAwayMs = cycleMs;
      lastTravelDeg = _travelDeg;
      _lastBiteTime = ts;
      debugPrint(
        '[IMU] ✅ Bite #$_biteCount  peakDev=${_peakDev.toStringAsFixed(2)}g '
        'travel=${_travelDeg.toStringAsFixed(0)}° dur=${cycleMs}ms',
      );
      notifyListeners();
    } else {
      debugPrint(
        '[IMU] ↩︎ Cycle rejected  peakDev=${_peakDev.toStringAsFixed(2)}g '
        'travel=${_travelDeg.toStringAsFixed(0)}° dur=${cycleMs}ms',
      );
    }

    // Re-anchor the rest baseline to where the spoon actually settled.
    _restX = _gEx;
    _restY = _gEy;
    _restZ = _gEz;
    _stillMs = 0;
    _resetCycle();
  }

  void _abortExcursion(DateTime ts) {
    debugPrint('[IMU] ⏱ Excursion aborted (timeout)');
    _restX = _gEx;
    _restY = _gEy;
    _restZ = _gEz;
    _stillMs = 0;
    _resetCycle();
  }

  double _distance(
    double ax,
    double ay,
    double az,
    double bx,
    double by,
    double bz,
  ) =>
      sqrt(pow(ax - bx, 2) + pow(ay - by, 2) + pow(az - bz, 2)).toDouble();

  @override
  void dispose() {
    stopMonitoring();
    super.dispose();
  }
}
