// bite_features.dart — the 13 numbers the bite model looks at.
//
// Decision time t is 1.5 s behind the newest sample (the model needs to see
// the spoon leave the mouth), one decision every 10 samples. Definitions are
// in the spec's "bite model" table and must match
// tools/ai_lab/train_bite_model.py exactly.
import 'dart:math' as math;

import 'package:smartspoon/features/ai_lab/domain/engine/handedness.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/imu_window.dart';

class BiteDecision {
  const BiteDecision({
    required this.t,
    required this.features,
    required this.yaw,
  });

  /// Sample index (since the window's last reset) the decision is about.
  final int t;

  /// Raw features (right-hand orientation).
  final List<double> features;

  /// Yaw rotation (deg) over the 1.5 s before t — the hand vote.
  final double yaw;
}

class BiteFeatures {
  BiteFeatures._();

  static const int back = 250;
  static const int fwd = 150;
  static const int step = 10;
  static const int fs = 100;
  static const int rbx = 9;
  static const int rfz = 11;

  static double _angle(ImuWindow w, int a, int b) {
    final ux = w.gravX(a), uy = w.gravY(a), uz = w.gravZ(a);
    final vx = w.gravX(b), vy = w.gravY(b), vz = w.gravZ(b);
    final dot = ux * vx + uy * vy + uz * vz;
    final nu = math.sqrt(ux * ux + uy * uy + uz * uz);
    final nv = math.sqrt(vx * vx + vy * vy + vz * vz);
    final c = (dot / (nu * nv + 1e-9)).clamp(-1.0, 1.0);
    return math.acos(c) * 180.0 / math.pi;
  }

  /// The decision due now that the newest sample has arrived, or null.
  static BiteDecision? due(ImuWindow w) {
    final n = w.newest;
    if (n < back + fwd || (n - fwd) % step != 0) return null;
    final t = n - fwd;

    var backMeanSum = 0.0, backMax = -double.infinity, fwdMax = -double.infinity;
    var rotBack = 0.0, rotFwd = 0.0;
    var rbX = 0.0, rbY = 0.0, rbZ = 0.0, rfX = 0.0, rfY = 0.0, rfZ = 0.0;
    for (var i = t - 150; i < t - 25; i++) {
      backMeanSum += w.gyroMag(i);
    }
    for (var i = t - 200; i < t; i++) {
      rotBack += w.gyroMag(i);
    }
    for (var i = t - 150; i < t; i++) {
      final m = w.gyroMag(i);
      if (m > backMax) backMax = m;
      rbX += w.gyroX(i);
      rbY += w.gyroY(i);
      rbZ += w.gyroZ(i);
    }
    for (var i = t; i < t + 150; i++) {
      final m = w.gyroMag(i);
      if (m > fwdMax) fwdMax = m;
      rotFwd += m;
      rfX += w.gyroX(i);
      rfY += w.gyroY(i);
      rfZ += w.gyroZ(i);
    }
    rbX /= fs;
    rbY /= fs;
    rbZ /= fs;
    rfX /= fs;
    rfY /= fs;
    rfZ /= fs;
    final nb = math.sqrt(rbX * rbX + rbY * rbY + rbZ * rbZ);
    final nf = math.sqrt(rfX * rfX + rfY * rfY + rfZ * rfZ);
    final angF = _angle(w, t, t + 150);
    return BiteDecision(
      t: t,
      yaw: rbZ,
      features: [
        _angle(w, t, t - 50),
        _angle(w, t, t - 250),
        angF,
        math.min(_angle(w, t, t - 150), angF),
        backMeanSum / 125.0,
        backMax,
        fwdMax,
        rotBack / fs,
        rotFwd / fs,
        rbX,
        rbY,
        rfZ,
        (rbX * rfX + rbY * rfY + rbZ * rfZ) / (nb * nf + 1e-9),
      ],
    );
  }

  /// Features as the weights for [mode] expect them. A left hand is the
  /// mirror image across the spoon's x–z plane, which flips only roll-before
  /// (rbx) and yaw-after (rfz); the hand-neutral weights use their sizes.
  static List<double> forMode(List<double> raw, HandMode mode) {
    if (mode == HandMode.right) return raw;
    final x = List<double>.of(raw);
    if (mode == HandMode.left) {
      x[rbx] = -x[rbx];
      x[rfz] = -x[rfz];
    } else {
      x[rbx] = x[rbx].abs();
      x[rfz] = x[rfz].abs();
    }
    return x;
  }
}
