// training_recorder.dart — records a labelled meal so the model can be
// retrained (AI Lab → Model & data → Record a labelled meal).
//
// The person eating (or a helper) taps "Bite" each time the spoon reaches the
// mouth. Those taps become `user_bite_mark` = 1 on the nearest sample — the
// per-bite label tools/ai_lab/train_bite_model.py learns from. The column
// schema is unchanged from the earlier AI Lab recorder, so old and new files
// train together.
import 'dart:io';
import 'dart:math' as math;

import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:smartspoon/ble/models/runtime_models.dart';

class _Row {
  _Row(this.d, this.phase, this.share);
  final McuSensorData d;
  final String phase;
  final double share;
  bool detected = false;
  bool marked = false;
}

class TrainingRecorder {
  /// ~33 min at 100 Hz; a forgotten recording must not eat the phone's RAM.
  static const int maxSamples = 200000;

  final List<_Row> _rows = [];
  final List<DateTime> _marks = [];
  bool _recording = false;
  int _epoch = 0;
  String? _lastSavedPath;
  int _savedCount = 0;

  bool get isRecording => _recording;
  int get sampleCount => _rows.length;
  int get markCount => _marks.length;
  String? get lastSavedPath => _lastSavedPath;
  int get savedCount => _savedCount;

  void start() {
    _rows.clear();
    _marks.clear();
    _epoch++;
    _lastSavedPath = null;
    _recording = true;
  }

  void cancel() {
    _recording = false;
    _rows.clear();
    _marks.clear();
  }

  void addSample(McuSensorData d, {required String phase, required double share}) {
    if (!_recording || _rows.length >= maxSamples) return;
    _rows.add(_Row(d, phase, share));
  }

  /// The user says a bite happened now.
  void markBite([DateTime? at]) {
    if (_recording) _marks.add(at ?? DateTime.now());
  }

  void undoMark() {
    if (_recording && _marks.isNotEmpty) _marks.removeLast();
  }

  /// The model detected a bite at [at] (written as system_bite_detected).
  void markDetected(DateTime at) {
    if (!_recording) return;
    final r = _nearest(at, const Duration(seconds: 2));
    if (r != null) r.detected = true;
  }

  _Row? _nearest(DateTime at, Duration within) {
    _Row? best;
    var bestMs = within.inMilliseconds + 1;
    for (var i = _rows.length - 1; i >= 0; i--) {
      final dt = _rows[i].d.timestamp.difference(at).inMilliseconds;
      if (dt.abs() < bestMs) {
        bestMs = dt.abs();
        best = _rows[i];
      }
      if (dt < -within.inMilliseconds) break;
    }
    return best;
  }

  /// Stops and writes the CSV. Returns its path, or null when nothing was
  /// recorded or the write failed.
  Future<String?> stopAndSave() async {
    _recording = false;
    if (_rows.isEmpty) return null;
    for (final m in _marks) {
      _nearest(m, const Duration(seconds: 2))?.marked = true;
    }
    final first = _rows.first.d.timestamp, last = _rows.last.d.timestamp;
    final spanS = last.difference(first).inMilliseconds / 1000.0;
    final rate = spanS > 0 ? (_rows.length - 1) / spanS : 0.0;
    var bad = 0;
    for (var i = 1; i < _rows.length; i++) {
      final dt = _rows[i].d.timestamp
          .difference(_rows[i - 1].d.timestamp)
          .inMilliseconds;
      if (dt <= 0 || dt > 25) bad++;
    }
    final gapRatio = _rows.length > 1 ? bad / (_rows.length - 1) : 0.0;

    final out = <List<dynamic>>[
      const [
        'sample_index', 'timestamp_ms', 'accelX', 'accelY', 'accelZ',
        'gyroX', 'gyroY', 'gyroZ', 'accelMag', 'gyroMag', 'linearAccel',
        'frame_state', 'system_bite_detected', 'system_tremor_score',
        'user_bite_mark', 'sample_rate_hz', 'gap_ratio', 'saturated',
        'ground_truth_bites', 'device_id', 'session_epoch',
      ],
      for (var i = 0; i < _rows.length; i++)
        () {
          final r = _rows[i], d = r.d;
          final am = d.accelMagnitude, gm = d.gyroMagnitude;
          return [
            i,
            d.timestamp.millisecondsSinceEpoch,
            d.accelX.toStringAsFixed(6),
            d.accelY.toStringAsFixed(6),
            d.accelZ.toStringAsFixed(6),
            d.gyroX.toStringAsFixed(6),
            d.gyroY.toStringAsFixed(6),
            d.gyroZ.toStringAsFixed(6),
            am.toStringAsFixed(6),
            gm.toStringAsFixed(6),
            (am - 1.0).abs().toStringAsFixed(6),
            r.phase,
            r.detected ? 1 : 0,
            r.share.toStringAsFixed(4),
            r.marked ? 1 : 0,
            rate.toStringAsFixed(2),
            gapRatio.toStringAsFixed(4),
            (am > 8.0 || gm > 1200.0) ? 1 : 0,
            _marks.length,
            d.deviceId,
            _epoch,
          ];
        }(),
    ];
    try {
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final path = '${dir.path}/spoon_session_$ts.csv';
      await File(path).writeAsString(const ListToCsvConverter().convert(out));
      _lastSavedPath = path;
      _savedCount++;
      debugPrint('[AiLab] recording saved → $path '
          '(${_rows.length} samples, ${_marks.length} marked bites)');
      return path;
    } catch (e) {
      debugPrint('[AiLab] recording save error: $e');
      return null;
    } finally {
      _rows.clear();
      _marks.clear();
    }
  }

  /// Counts recordings already on the phone.
  Future<void> loadSavedCount() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _savedCount = dir
          .listSync()
          .where((f) =>
              f.path.endsWith('.csv') && f.path.contains('spoon_session'))
          .length;
    } catch (_) {}
  }

  /// Seconds recorded so far.
  double get seconds => _rows.length < 2
      ? 0
      : math.max(
          0,
          _rows.last.d.timestamp
                  .difference(_rows.first.d.timestamp)
                  .inMilliseconds /
              1000.0);
}
