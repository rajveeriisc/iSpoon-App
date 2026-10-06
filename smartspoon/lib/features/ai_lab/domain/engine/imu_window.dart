// imu_window.dart — the last 4 s of raw IMU samples the bite features read.
//
// Holds raw gyro, gyro magnitude, the phone timestamp and a gravity estimate
// (exponential low-pass of the accelerometer, τ = 0.15 s). Hand mirroring is
// applied to the FEATURES, not here, so changing hand never resets the window.
//
// Must match tools/ai_lab/train_bite_model.py sample-for-sample.
import 'dart:math' as math;
import 'dart:typed_data';

class ImuWindow {
  ImuWindow({this.capacity = 401, this.gapResetMs = 5000});

  /// Low-pass coefficient at the nominal 100 Hz: dt / (τ + dt).
  static const double gravityAlpha = 0.01 / (0.15 + 0.01);

  final int capacity;

  /// A timestamp jump longer than this is a real stop in streaming. Shorter
  /// jumps are BLE bunching (timestamps are receive time) and are ignored.
  final int gapResetMs;

  late final Float64List _grX = Float64List(capacity);
  late final Float64List _grY = Float64List(capacity);
  late final Float64List _grZ = Float64List(capacity);
  late final Float64List _gyX = Float64List(capacity);
  late final Float64List _gyY = Float64List(capacity);
  late final Float64List _gyZ = Float64List(capacity);
  late final Float64List _gm = Float64List(capacity);
  late final Int64List _ts = Int64List(capacity);

  int _count = 0;
  int? _lastTsMs;
  double _gx = 0, _gy = 0, _gz = 0;

  /// Samples since the last reset.
  int get count => _count;

  /// Index (since reset) of the newest sample, or -1 when empty.
  int get newest => _count - 1;

  void clear() {
    _count = 0;
    _lastTsMs = null;
  }

  /// Adds one sample. Returns true when a streaming gap reset the window
  /// first (the caller must reset anything that depends on continuity).
  bool add({
    required int tsMs,
    required double ax,
    required double ay,
    required double az,
    required double gx,
    required double gy,
    required double gz,
  }) {
    var reset = false;
    final last = _lastTsMs;
    if (last != null && tsMs - last > gapResetMs) {
      clear();
      reset = true;
    }
    _lastTsMs = tsMs;
    if (_count == 0) {
      _gx = ax;
      _gy = ay;
      _gz = az;
    }
    _gx = _gx + gravityAlpha * (ax - _gx);
    _gy = _gy + gravityAlpha * (ay - _gy);
    _gz = _gz + gravityAlpha * (az - _gz);
    final slot = _count % capacity;
    _grX[slot] = _gx;
    _grY[slot] = _gy;
    _grZ[slot] = _gz;
    _gyX[slot] = gx;
    _gyY[slot] = gy;
    _gyZ[slot] = gz;
    _gm[slot] = math.sqrt(gx * gx + gy * gy + gz * gz);
    _ts[slot] = tsMs;
    _count++;
    return reset;
  }

  // Accessors by index since reset; valid for the last [capacity] samples.
  double gravX(int i) => _grX[i % capacity];
  double gravY(int i) => _grY[i % capacity];
  double gravZ(int i) => _grZ[i % capacity];
  double gyroX(int i) => _gyX[i % capacity];
  double gyroY(int i) => _gyY[i % capacity];
  double gyroZ(int i) => _gyZ[i % capacity];
  double gyroMag(int i) => _gm[i % capacity];
  int timestampMs(int i) => _ts[i % capacity];
}
