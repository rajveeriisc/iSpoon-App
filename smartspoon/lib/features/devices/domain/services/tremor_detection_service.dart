// tremor_detection_service.dart — real-time rhythmic hand-movement analysis.
//
// Consumes the spoon's accelerometer/gyroscope stream (via McuBleService) and
// measures narrow rhythmic energy in 4–12 Hz relative to slower voluntary
// eating motion. It analyses all six axes, rejects packet gaps/impacts, and
// only scores the stable middle of a lift/hold/return cycle. The result is a
// relative wellness trend for comparison across the user's own meals—not a
// diagnosis or a replacement for a standardized clinical assessment.
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:smartspoon/ble/models/runtime_models.dart';
import 'package:smartspoon/features/notifications/domain/services/notification_service.dart';
import 'package:fftea/fftea.dart';
// ignore: unused_import
import 'package:vector_math/vector_math.dart' as vector;
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  DATA MODELS
// ─────────────────────────────────────────────────────────────────────────────

/// Tremor Detection Result (per-bite or aggregated)
class TremorResult {
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
  static const double moderateThreshold =
      3.0 * (100.0 - kSteadyFromPct) / 100.0;
  static const double highThreshold =
      3.0 * (100.0 - kShakyBelowPct) / 100.0;

  /// True only when a clean, sufficiently long sensor window was analysed.
  /// A measured score of 0 is different from an unavailable measurement.
  final bool measured;
  final bool detected;
  final double frequency; // Hz
  final double amplitude; // RMS in the selected sensor channel (g or dps)
  final double score; // Relative movement-variation index, 0–3
  final double confidence; // Signal quality / agreement, 0–1
  final int windowDurationMs;
  final String source; // 'accel', 'gyro', or 'fusion'
  final DateTime timestamp;

  TremorResult({
    this.measured = true,
    required this.detected,
    this.frequency = 0.0,
    this.amplitude = 0.0,
    this.score = 0.0,
    this.confidence = 0.0,
    this.windowDurationMs = 0,
    this.source = 'none',
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  factory TremorResult.empty() =>
      TremorResult(measured: false, detected: false);

  bool get isFresh =>
      DateTime.now().difference(timestamp) <= const Duration(seconds: 10);

  @override
  String toString() {
    return 'Measured: $measured | Rhythmic: $detected | Freq: ${frequency.toStringAsFixed(1)}Hz | Amp: ${amplitude.toStringAsFixed(3)} | Index: ${score.toStringAsFixed(2)} | Quality: ${(confidence * 100).round()}%';
  }
}

/// Internal: timestamped six-axis IMU sample.
class _MagSample {
  final double accelX;
  final double accelY;
  final double accelZ;
  final double gyroX;
  final double gyroY;
  final double gyroZ;
  final DateTime timestamp;

  _MagSample({
    required this.accelX,
    required this.accelY,
    required this.accelZ,
    required this.gyroX,
    required this.gyroY,
    required this.gyroZ,
    required this.timestamp,
  });

  double get accelMag =>
      math.sqrt(accelX * accelX + accelY * accelY + accelZ * accelZ);
  double get gyroMag =>
      math.sqrt(gyroX * gyroX + gyroY * gyroY + gyroZ * gyroZ);
  double get linearAccel => (accelMag - 1.0).abs();
}

/// Internal: FFT frequency-domain point
class _FreqPoint {
  final double freq;
  final double power;
  _FreqPoint(this.freq, this.power);
}

/// Internal: peak info from PSD
class _PeakInfo {
  final double frequency;
  final double power;
  final double powerFraction;
  _PeakInfo(this.frequency, this.power, this.powerFraction);
}

/// Internal: data passed to compute isolate
class _FrameAnalysisData {
  final List<_MagSample> samples;
  final int sampleRate;
  final int trimStartSamples;
  final int trimEndSamples;
  _FrameAnalysisData(
    this.samples,
    this.sampleRate,
    this.trimStartSamples,
    this.trimEndSamples,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  BITE FRAME STATE MACHINE
// ─────────────────────────────────────────────────────────────────────────────

enum _FrameState { idle, moving, steady, returning }

/// Detects the motion pattern:  idle → lifting → holding → returning → complete
/// and emits the raw frame data for tremor analysis.
class _BiteFrameDetector {
  // Motion is detected from gravity-compensated acceleration plus angular
  // velocity. Testing raw acceleration against <0.5 g made the old return
  // state effectively unreachable because a stationary spoon reads about 1 g.
  static const double _activeLinearAccelG = 0.45;
  static const double _activeGyroDps = 45.0;
  static const double _quietLinearAccelG = 0.20;
  static const double _quietGyroDps = 25.0;
  static const int _motionDebounceSamples = 8; // 80 ms
  static const int _quietDebounceSamples = 40; // 400 ms
  static const int _minFrameSamples = 200; // 2 s, realistic bite window

  _FrameState _state = _FrameState.idle;
  int _stateCounter = 0;
  final List<_MagSample> _frameBuffer = [];
  final List<_MagSample> _steadyBuffer = [];

  // Max frame size: 30 seconds × 100 Hz = 3000 samples (safety cap)
  static const int _maxFrameSamples = 3000;

  /// Feed a new sample. Returns the completed frame if a bite cycle just finished.
  List<_MagSample>? feed(_MagSample sample) {
    // Always buffer while not idle
    if (_state != _FrameState.idle) {
      _frameBuffer.add(sample);
      if (_frameBuffer.length > _maxFrameSamples) {
        // Safety: too long, reset
        debugPrint('⚠️ Frame too long (>$_maxFrameSamples samples), resetting');
        _reset();
        return null;
      }
    }

    switch (_state) {
      case _FrameState.idle:
        if (_isActive(sample)) {
          _stateCounter++;
          if (_stateCounter >= _motionDebounceSamples) {
            _state = _FrameState.moving;
            _stateCounter = 0;
            _frameBuffer.clear();
            _frameBuffer.add(sample);
            debugPrint('🔼 Lift detected, buffering frame...');
          }
        } else {
          _stateCounter = 0;
        }
        break;

      case _FrameState.moving:
        if (_isQuiet(sample)) {
          _stateCounter++;
          if (_stateCounter >= _quietDebounceSamples) {
            _state = _FrameState.steady;
            _stateCounter = 0;
            _steadyBuffer
              ..clear()
              ..addAll(
                _frameBuffer.skip(
                  math.max(0, _frameBuffer.length - _quietDebounceSamples),
                ),
              );
            debugPrint('✋ Stable hold detected');
          }
        } else {
          _stateCounter = 0;
        }
        if (_frameBuffer.length > 800) {
          debugPrint('⚠️ Lift timeout — no hold confirmed, resetting');
          _reset();
        }
        break;

      case _FrameState.steady:
        _steadyBuffer.add(sample);
        if (_isActive(sample)) {
          _stateCounter++;
          if (_stateCounter >= _motionDebounceSamples) {
            _state = _FrameState.returning;
            _stateCounter = 0;
            debugPrint('🔽 Return detected');
          }
        } else {
          _stateCounter = 0;
        }
        // A long steady hold is itself a valid analysis task; complete it
        // without waiting indefinitely for a return movement.
        if (_steadyBuffer.length >= 1500) {
          final frame = List<_MagSample>.from(_steadyBuffer);
          debugPrint('🎯 Hold frame complete: ${frame.length} samples');
          _reset();
          return frame;
        }
        break;

      case _FrameState.returning:
        if (_isQuiet(sample)) {
          _stateCounter++;
          if (_stateCounter >= _quietDebounceSamples) {
            final frame = _steadyBuffer.length >= _minFrameSamples
                ? List<_MagSample>.from(_steadyBuffer)
                : null;
            if (frame != null) {
              debugPrint(
                '🎯 Stable bite window complete: ${frame.length} samples (${(frame.length / 100).toStringAsFixed(1)}s)',
              );
            }
            _reset();
            return frame;
          }
        } else {
          _stateCounter = 0;
        }
        // Timeout: if frame is very long, just complete
        if (_frameBuffer.length > _maxFrameSamples - 100) {
          final frame = _steadyBuffer.length >= _minFrameSamples
              ? List<_MagSample>.from(_steadyBuffer)
              : null;
          _reset();
          return frame;
        }
        break;
    }

    return null;
  }

  void _reset() {
    _state = _FrameState.idle;
    _stateCounter = 0;
    _frameBuffer.clear();
    _steadyBuffer.clear();
  }

  void reset() => _reset();

  bool _isActive(_MagSample sample) =>
      sample.linearAccel >= _activeLinearAccelG ||
      sample.gyroMag >= _activeGyroDps;

  bool _isQuiet(_MagSample sample) =>
      sample.linearAccel <= _quietLinearAccelG &&
      sample.gyroMag <= _quietGyroDps;

  /// True when no bite motion is in progress. Used to suppress the fallback
  /// analysis while the user is actively lifting/holding/returning the spoon.
  bool get isIdle => _state == _FrameState.idle;
  bool get isSteady => _state == _FrameState.steady;
}

// ─────────────────────────────────────────────────────────────────────────────
//  MAIN SERVICE
// ─────────────────────────────────────────────────────────────────────────────

/// Optimized tremor detection using frame-based analysis.
///
/// Instead of analyzing a continuous rolling buffer, this service:
/// 1. Detects bite motion frames (lift → hold → return)
/// 2. Keeps only the confirmed steady portion of the frame
/// 3. High-pass-filters each sensor axis before spectral analysis
/// 4. Runs Welch PSD on the clean window
/// 5. Produces per-bite tremor results
class TremorDetectionService extends ChangeNotifier {
  final Stream<List<McuSensorData>> _sensorBatchStream;
  StreamSubscription? _dataSubscription;

  // Constants
  static const int _sampleRate = 100; // 100 Hz
  // Published wearable pipelines commonly use 3–5 second windows. Four
  // seconds balances frequency resolution with realistic eating hold time.
  static const int _minUsableSamples = 200;

  // Frame detector
  final _BiteFrameDetector _frameDetector = _BiteFrameDetector();

  // Per-bite results history (kept for current meal)
  final List<TremorResult> perBiteResults = [];

  // Processing Control
  bool _isProcessing = false;
  int _analysisGeneration = 0;
  DateTime? _lastNotificationTime;

  // Aggregated result (rolling average of last 5 bites)
  TremorResult _lastResult = TremorResult.empty();
  TremorResult get lastResult => _lastResult;

  // ── Fallback: continuous buffer (kept as secondary signal when no frames) ──
  final List<_MagSample> _analysisBuffer = [];
  static const int _fallbackBufferSize = _sampleRate * 4;
  DateTime? _lastFallbackTime;

  TremorDetectionService(this._sensorBatchStream) {
    _init();
  }

  void _init() {
    _dataSubscription = _sensorBatchStream.listen(_processBatch);
  }

  @override
  void dispose() {
    _dataSubscription?.cancel();
    super.dispose();
  }

  /// Clear per-bite history (call when meal ends)
  void clearBiteHistory() {
    _analysisGeneration++;
    _frameDetector.reset();
    perBiteResults.clear();
    _analysisBuffer.clear();
    _lastFallbackTime = null;
    _lastNotificationTime = null;
    _lastResult = TremorResult.empty();
    notifyListeners();
  }

  // ─── PROCESSING ─────────────────────────────────────────────────────────────

  void _processBatch(List<McuSensorData> batch) {
    for (final data in batch) {
      final sample = _MagSample(
        accelX: data.accelX,
        accelY: data.accelY,
        accelZ: data.accelZ,
        gyroX: data.gyroX,
        gyroY: data.gyroY,
        gyroZ: data.gyroZ,
        timestamp: data.timestamp,
      );

      // Feed into frame detector
      final completedFrame = _frameDetector.feed(sample);
      if (completedFrame != null && !_isProcessing) {
        _analyzeFrame(completedFrame);
      }

      // Continuous analysis is only useful during the stable middle of the
      // lift/hold/return cycle. Clearing on edge motion prevents startup and
      // lowering transients from leaking into a later bite measurement.
      if (_frameDetector.isSteady) {
        _analysisBuffer.add(sample);
      } else {
        _analysisBuffer.clear();
      }
    }

    if (_analysisBuffer.length > (_fallbackBufferSize * 1.5).toInt()) {
      final removeCount = _analysisBuffer.length - _fallbackBufferSize;
      _analysisBuffer.removeRange(0, removeCount);
    }

    if (_analysisBuffer.length >= _fallbackBufferSize &&
        _frameDetector.isSteady &&
        !_isProcessing &&
        (_lastFallbackTime == null ||
            DateTime.now().difference(_lastFallbackTime!).inSeconds >= 2)) {
      _runFallbackAnalysis();
    }
  }

  // ─── FRAME-BASED ANALYSIS (PRIMARY) ─────────────────────────────────────────

  Future<void> _analyzeFrame(List<_MagSample> frame) async {
    if (_isProcessing) return;
    _isProcessing = true;
    final generation = _analysisGeneration;

    try {
      debugPrint(
        '🔬 Analyzing bite frame: ${frame.length} samples (${(frame.length / _sampleRate).toStringAsFixed(1)}s)',
      );

      // Run analysis in compute isolate
      final result = await compute(
        _analyzeFrameIsolate,
        _FrameAnalysisData(frame, _sampleRate, 0, 0),
      );

      if (generation != _analysisGeneration) return;

      debugPrint('📊 Per-bite tremor: $result');

      if (!result.measured) return;

      perBiteResults.add(result);

      // Keep last 50 bites max
      if (perBiteResults.length > 50) {
        perBiteResults.removeAt(0);
      }

      // Update aggregated result (rolling average of last 5 bites)
      _lastResult = _aggregateResults(perBiteResults);
      notifyListeners();

      // Trigger notification if significant tremor
      if (perBiteResults.length >= 3 &&
          _lastResult.detected &&
          _lastResult.score >= TremorResult.highThreshold &&
          _lastResult.confidence >= 0.7) {
        _triggerTremorNotification(_lastResult);
      }
    } catch (e) {
      debugPrint('❌ Frame analysis error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  // ─── FALLBACK CONTINUOUS ANALYSIS ───────────────────────────────────────────

  Future<void> _runFallbackAnalysis() async {
    if (_isProcessing) return;
    _isProcessing = true;
    _lastFallbackTime = DateTime.now();
    final generation = _analysisGeneration;

    try {
      final samples = List<_MagSample>.from(_analysisBuffer);

      debugPrint('🔄 Steady-window analysis: ${samples.length} samples');

      // No trimming for fallback — but still use bandpass + Welch
      final result = await compute(
        _analyzeFrameIsolate,
        _FrameAnalysisData(samples, _sampleRate, 0, 0),
      );

      if (generation != _analysisGeneration) return;

      debugPrint('📊 Tremor fallback result: $result');

      if (result.measured) {
        _lastResult = result;
      }
      notifyListeners();

      // Slide buffer: remove 2 seconds
      int removeCount = 2 * _sampleRate;
      if (_analysisBuffer.length > removeCount) {
        _analysisBuffer.removeRange(0, removeCount);
      }
    } catch (e) {
      debugPrint('❌ Fallback analysis error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  // ─── AGGREGATION ────────────────────────────────────────────────────────────

  TremorResult _aggregateResults(List<TremorResult> results) {
    final measured = results.where((r) => r.measured).toList();
    if (measured.isEmpty) return TremorResult.empty();

    final recent = measured.length > 5
        ? measured.sublist(measured.length - 5)
        : measured;

    final rhythmic = recent
        .where((r) => r.detected && r.frequency > 0)
        .toList();
    final avgFreq = rhythmic.isEmpty
        ? 0.0
        : rhythmic.map((r) => r.frequency).reduce((a, b) => a + b) /
              rhythmic.length;
    double avgAmp =
        recent.map((r) => r.amplitude).reduce((a, b) => a + b) / recent.length;
    double avgScore =
        recent.map((r) => r.score).reduce((a, b) => a + b) / recent.length;
    final avgConfidence =
        recent.map((r) => r.confidence).reduce((a, b) => a + b) / recent.length;

    final detectedCount = recent.where((r) => r.detected).length;
    final requiredDetected = (recent.length * 0.6).ceil();

    return TremorResult(
      measured: true,
      detected:
          detectedCount >= requiredDetected &&
          avgScore >= TremorResult.moderateThreshold,
      frequency: avgFreq,
      amplitude: avgAmp,
      score: avgScore,
      confidence: avgConfidence,
      windowDurationMs: recent.last.windowDurationMs,
      source: recent.last.source,
    );
  }

  // ─── NOTIFICATION ───────────────────────────────────────────────────────────

  void _triggerTremorNotification(TremorResult result) {
    final now = DateTime.now();
    if (_lastNotificationTime != null &&
        now.difference(_lastNotificationTime!).inMinutes < 5) {
      return;
    }
    _lastNotificationTime = now;

    NotificationService().showLocalAlert(
      title: 'Hand movement increased',
      body:
          'Repeated rhythmic movement was measured while eating. Review the trend when convenient.',
      type: 'health_alerts',
      priority: 'HIGH',
      data: {
        'action_type': 'open_tremor_analysis',
        'action_data': {
          'frequency': result.frequency,
          'amplitude': result.amplitude,
          'score': result.score,
        },
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  STATIC / PURE FUNCTIONS  (run in compute isolate)
  // ═══════════════════════════════════════════════════════════════════════════

  @visibleForTesting
  static TremorResult analyzeSamplesForTest(List<McuSensorData> samples) {
    final frame = samples
        .map(
          (s) => _MagSample(
            accelX: s.accelX,
            accelY: s.accelY,
            accelZ: s.accelZ,
            gyroX: s.gyroX,
            gyroY: s.gyroY,
            gyroZ: s.gyroZ,
            timestamp: s.timestamp,
          ),
        )
        .toList();
    return _analyzeFrameIsolate(_FrameAnalysisData(frame, _sampleRate, 0, 0));
  }

  /// Main analysis entry point for a single frame (runs in isolate).
  static TremorResult _analyzeFrameIsolate(_FrameAnalysisData data) {
    final fs = data.sampleRate;
    var samples = data.samples;

    // ── Step 1: Trim transient edges ──────────────────────────────────────
    if (data.trimStartSamples > 0 || data.trimEndSamples > 0) {
      final totalTrim = data.trimStartSamples + data.trimEndSamples;
      if (samples.length < totalTrim + _minUsableSamples) {
        return TremorResult.empty();
      }
      samples = samples.sublist(
        data.trimStartSamples,
        samples.length - data.trimEndSamples,
      );
    }

    if (samples.length < _minUsableSamples) {
      return TremorResult.empty();
    }

    // Reject windows with packet gaps or impact/clipping. A missing/contaminated
    // measurement must not be persisted as a reassuring zero.
    var badIntervals = 0;
    for (var i = 1; i < samples.length; i++) {
      final dt = samples[i].timestamp.difference(samples[i - 1].timestamp);
      if (dt.inMilliseconds <= 0 || dt.inMilliseconds > 25) badIntervals++;
    }
    if (badIntervals > samples.length * 0.05 ||
        samples.any((s) => s.accelMag > 8.0 || s.gyroMag > 1200.0)) {
      return TremorResult.empty();
    }

    final durationMs = ((samples.length / fs) * 1000).round();

    // ── Step 2: Process all axes independently ────────────────────────────
    // Summing per-axis PSD preserves oscillation that a raw vector magnitude
    // can cancel as the spoon rotates relative to gravity.
    final accelAxes = <List<double>>[
      samples.map((s) => s.accelX).toList(),
      samples.map((s) => s.accelY).toList(),
      samples.map((s) => s.accelZ).toList(),
    ];
    final gyroAxes = <List<double>>[
      samples.map((s) => s.gyroX).toList(),
      samples.map((s) => s.gyroY).toList(),
      samples.map((s) => s.gyroZ).toList(),
    ];

    // ── Step 3: Welch PSD on full 0.5–Nyquist range ───────────────────────
    final accelPsd = _sumAxisPsd(accelAxes, fs);
    final gyroPsd = _sumAxisPsd(gyroAxes, fs);

    if (accelPsd.isEmpty && gyroPsd.isEmpty) {
      return TremorResult.empty();
    }

    // ── Step 4: Band-ratio detection ──────────────────────────────────────
    // Tremor band    : 4–12 Hz  (covers ET 4–8 Hz + physiological 8–12 Hz)
    // Voluntary band : 0.5–4 Hz (eating/reaching motion < 4 Hz)
    // Ratio > 1.2 indicates tremor energy dominates voluntary motion energy.
    final accelRatio = _computeBandRatio(accelPsd, 4.0, 12.0, 0.5, 4.0);
    final gyroRatio = _computeBandRatio(gyroPsd, 4.0, 12.0, 0.5, 4.0);

    // Also find the spectral peak within the tremor band for frequency/amplitude.
    // Each is independently gated by _detectPeak's half-power-bandwidth
    // rhythmicity test — null means that channel saw no genuinely narrow
    // (rhythmic) spectral line, regardless of what its ratio says.
    final accelPeak = _detectPeak(accelPsd, 4.0, 12.0);
    final gyroPeak = _detectPeak(gyroPsd, 4.0, 12.0);

    // Fuse normalized channel ratios instead of letting one noisy channel win.
    // Gyroscope receives slightly more weight because it is not contaminated
    // by the changing gravity vector during spoon rotation.
    // Each ratio is already unit-free (tremor-power / voluntary-power WITHIN
    // that channel), so averaging them fuses comparable quantities rather
    // than mixing g² with (rad/s)². A channel with no PSD data at all is
    // excluded rather than averaged in — an absent channel must not dilute
    // a genuine reading from the other one down toward zero.
    final bool accelHasData = accelPsd.isNotEmpty;
    final bool gyroHasData = gyroPsd.isNotEmpty;
    final double ratio;
    final String source;
    if (accelHasData && gyroHasData) {
      ratio = 0.4 * accelRatio + 0.6 * gyroRatio;
      source = 'fusion';
    } else if (gyroHasData) {
      ratio = gyroRatio;
      source = 'gyro';
    } else if (accelHasData) {
      ratio = accelRatio;
      source = 'accel';
    } else {
      return TremorResult.empty();
    }

    // The fused ratio above decides WHETHER there's tremor. Frequency and
    // amplitude are reported from whichever channel's peak is cleanest
    // (highest powerFraction = most of that channel's energy concentrated in
    // one narrow line) — comparable across channels since it is a fraction,
    // not a raw power value.
    final _PeakInfo? peak;
    final bool peakFromAccel;
    if (accelPeak != null && gyroPeak != null) {
      peakFromAccel = accelPeak.powerFraction >= gyroPeak.powerFraction;
      peak = peakFromAccel ? accelPeak : gyroPeak;
    } else {
      peak = accelPeak ?? gyroPeak;
      peakFromAccel = accelPeak != null;
    }

    // No narrow line is still a valid measured window: persist a measured
    // zero rather than conflating it with missing data.
    if (peak == null) {
      return TremorResult(
        measured: true,
        detected: false,
        score: 0.0,
        confidence: (samples.length / 500.0).clamp(0.0, 1.0) * 0.7,
        windowDurationMs: durationMs,
        source: source,
      );
    }

    final double f = peak.frequency;
    final double P = peak.power;

    final int nFFT = samples.length >= 512 ? 512 : 256;
    // Correctly scale PSD peak to amplitude: A = 2*sqrt(P) / (coherent_gain)
    // For Hamming window, coherent gain is 0.54 * nFFT.
    final double amplitude = 2.0 * math.sqrt(P) / (0.54 * nFFT);

    final durationQuality = (samples.length / 500.0).clamp(0.0, 1.0);
    final rhythmicityQuality = (peak.powerFraction / 0.25).clamp(0.0, 1.0);
    final sensorAgreement =
        accelPeak != null &&
            gyroPeak != null &&
            (accelPeak.frequency - gyroPeak.frequency).abs() <= 1.0
        ? 1.0
        : 0.55;
    final confidence =
        (0.35 * durationQuality +
                0.40 * rhythmicityQuality +
                0.25 * sensorAgreement)
            .clamp(0.0, 1.0);

    // ── Step 6: Detection gate (ratio + amplitude window) ────────────────
    final amplitudeFloor = peakFromAccel ? 0.02 : 1.0;
    final bool detected =
        ratio >= 1.2 && amplitude >= amplitudeFloor && confidence >= 0.5;

    // ── Step 7: Score (ratio × amplitude, 0–3 scale) ─────────────────────
    // Calculate score even if 'detected' is false to provide dynamic UI values.
    final double baseScore = ((ratio - 1.0) / 2.0 * 3.0).clamp(0.0, 3.0);
    final amplitudeRange = peakFromAccel ? 0.28 : 14.0;
    final double ampWeight = ((amplitude - amplitudeFloor) / amplitudeRange)
        .clamp(0.0, 1.0);
    final rawScore = (baseScore * (0.5 + 0.5 * ampWeight)).clamp(0.0, 3.0);
    // An undetected reading must stay inside the "steady" band by
    // construction: the detector has already said there is no qualifying
    // rhythmic movement, so the screens must not label it "some shake".
    //
    // This cap used to be the literal 0.59, which worked only while the
    // low/moderate boundary was 0.6. Once the bands were re-derived from the
    // steadiness percentages (90% -> 0.30), an undetected reading scoring
    // 0.31-0.59 started rendering as moderate. Pin the cap to the band cut so
    // the two cannot drift apart again.
    final double score = detected
        ? rawScore
        : math.min(rawScore * 0.25, TremorResult.moderateThreshold);

    return TremorResult(
      measured: true,
      detected: detected,
      frequency: f,
      amplitude: amplitude,
      score: score,
      confidence: confidence,
      windowDurationMs: durationMs,
      source: source,
    );
  }

  // ─── SIGNAL PROCESSING PRIMITIVES ───────────────────────────────────────────

  static List<double> _highPassFilter(
    List<double> input,
    double cutoff,
    int fs,
  ) {
    double rc = 1.0 / (2.0 * math.pi * cutoff);
    double dt = 1.0 / fs;
    double alpha = rc / (rc + dt);

    final output = List<double>.filled(input.length, 0.0);
    for (int i = 1; i < input.length; i++) {
      output[i] = alpha * (output[i - 1] + input[i] - input[i - 1]);
    }
    return output;
  }

  static List<_FreqPoint> _sumAxisPsd(List<List<double>> axes, int fs) {
    final spectra = axes
        .map((axis) => _computeWelchPsd(_highPassFilter(axis, 0.5, fs), fs))
        .where((psd) => psd.isNotEmpty)
        .toList();
    if (spectra.isEmpty) return [];

    return List.generate(spectra.first.length, (i) {
      final power = spectra.fold<double>(0.0, (sum, psd) => sum + psd[i].power);
      return _FreqPoint(spectra.first[i].freq, power);
    });
  }

  /// Compute PSD using Welch's method (Hamming window, 50% overlap).
  /// nFFT = 512 → 0.195 Hz resolution at 100 Hz — meets clinical standard
  /// (Elble & McNames 2016: 0.2 Hz resolution requires ≥5 s windows).
  static List<_FreqPoint> _computeWelchPsd(List<double> signal, int fs) {
    int nFFT = 512;
    if (signal.length < nFFT) {
      if (signal.length < 128) return [];
      nFFT = 256; // fallback: 0.39 Hz resolution — acceptable minimum
    }

    final fft = FFT(nFFT);
    final List<double> psdSum = List.filled(nFFT ~/ 2, 0.0);
    int count = 0;
    int step = nFFT ~/ 2; // 50% overlap

    for (int i = 0; i <= signal.length - nFFT; i += step) {
      final chunk = signal.sublist(i, i + nFFT);
      final windowed = _applyHammingWindow(chunk);
      final spectrum = fft.realFft(windowed);

      for (int j = 0; j < nFFT ~/ 2; j++) {
        double re = spectrum[j].x;
        double im = spectrum[j].y;
        psdSum[j] += re * re + im * im;
      }
      count++;
    }

    final double binWidth = fs / nFFT;
    final List<_FreqPoint> result = [];
    for (int i = 0; i < psdSum.length; i++) {
      if (count > 0) psdSum[i] /= count;
      result.add(_FreqPoint(i * binWidth, psdSum[i]));
    }
    return result;
  }

  static List<double> _applyHammingWindow(List<double> input) {
    final output = List<double>.from(input);
    final N = input.length;
    for (int i = 0; i < N; i++) {
      output[i] *= 0.54 - 0.46 * math.cos(2 * math.pi * i / (N - 1));
    }
    return output;
  }

  /// Ratio of total PSD power in tremor band vs voluntary-motion band.
  /// Ali et al. 2022/2024 (PMID 35347169, 38196822): ratio > 1.0 indicates
  /// tremor energy exceeds voluntary eating/reaching motion energy.
  static double _computeBandRatio(
    List<_FreqPoint> psd,
    double tremorLow,
    double tremorHigh,
    double volLow,
    double volHigh,
  ) {
    double tremorPower = 0.0;
    double volPower = 0.0;
    for (final p in psd) {
      if (p.freq >= tremorLow && p.freq <= tremorHigh) tremorPower += p.power;
      if (p.freq >= volLow && p.freq <= volHigh) volPower += p.power;
    }
    if (volPower == 0.0) return tremorPower > 0 ? 9.9 : 0.0;
    return tremorPower / volPower;
  }

  static _PeakInfo? _detectPeak(
    List<_FreqPoint> psd,
    double minFreq,
    double maxFreq,
  ) {
    int maxIdx = -1;
    double totalPower = 0.0;
    double bandPower = 0.0;
    int bandBins = 0;

    for (int i = 0; i < psd.length; i++) {
      final p = psd[i];
      totalPower += p.power;
      if (p.freq >= minFreq && p.freq <= maxFreq) {
        bandPower += p.power;
        bandBins++;
        if (maxIdx == -1 || p.power > psd[maxIdx].power) {
          maxIdx = i;
        }
      }
    }

    if (maxIdx == -1 || totalPower == 0.0) return null;
    final maxPoint = psd[maxIdx];

    // Cheap pre-filter: peak must at least clear the band average before
    // paying for the bandwidth walk below.
    final double meanBandPower = bandBins > 0 ? bandPower / bandBins : 0.0;
    if (maxPoint.power < 2.0 * meanBandPower) return null;

    // Rhythmicity test — Elble & McNames 2016 (PMID 27257514): tremor is
    // distinguished from other movement by producing a NARROW spectral line,
    // not merely a tall one. Their criterion is the half-power bandwidth: the
    // width of the peak at half its amplitude must be ≤ 2 Hz. A broad hump
    // (eating-motion artefact, muscle noise) can clear the mean-power test
    // above while still being too WIDE to be genuine tremor — this is the
    // test that actually checks for that shape, previously cited in this
    // file's rationale but never implemented.
    final double halfPower = maxPoint.power / 2.0;
    int loIdx = maxIdx;
    while (loIdx > 0 && psd[loIdx - 1].power >= halfPower) {
      loIdx--;
    }
    int hiIdx = maxIdx;
    while (hiIdx < psd.length - 1 && psd[hiIdx + 1].power >= halfPower) {
      hiIdx++;
    }
    final double halfPowerBandwidthHz = psd[hiIdx].freq - psd[loIdx].freq;
    if (halfPowerBandwidthHz > 2.0) return null;

    return _PeakInfo(
      maxPoint.freq,
      maxPoint.power,
      maxPoint.power / totalPower,
    );
  }
}
