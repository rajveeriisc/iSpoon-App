// Bite-cycle validation, on synthetic traces only — no Flutter, no device.
//
// Each test drives the tracker with a gravity direction and a gyro magnitude
// per sample, which is everything it reads. The traces are shaped like the
// four motions the user reported as false bites (wiggle, stirring, carrying,
// gesturing) plus a real spoon trip, and assert the verdict for each.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/bite_cycle_tracker.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/imu_window.dart';

/// Gravity pointing `deg` away from the plate pose, in the x-z plane.
List<double> tilt(double deg) {
  final r = deg * math.pi / 180.0;
  return [9.81 * math.sin(r), 0.0, 9.81 * math.cos(r)];
}

final plate = tilt(0);

/// Drives one tracker and keeps the window in step with it.
class Trace {
  Trace([BiteCycleConfig? config])
      : tracker = BiteCycleTracker(config ?? testConfig());

  /// Short warm-up by default so traces stay readable; the real default is
  /// 8000 ms and is exercised directly in the plate-reference tests.
  static BiteCycleConfig testConfig({int plateReadyMs = 300}) =>
      BiteCycleConfig(plateReadyMs: plateReadyMs);

  final ImuWindow w = ImuWindow();
  final BiteCycleTracker tracker;
  int _ts = 0;

  int get newest => w.newest;
  BitePhase get phase => tracker.phase;
  double get delta => tracker.deltaDeg;

  final List<BitePhase> phasesSeen = [];

  void feed(int samples, {required List<double> grav, required double gyro}) {
    for (var i = 0; i < samples; i++) {
      _ts += 10;
      final reset = w.add(
        tsMs: _ts,
        ax: grav[0],
        ay: grav[1],
        az: grav[2],
        gx: gyro,
        gy: 0,
        gz: 0,
      );
      if (reset) tracker.reset();
      tracker.add(w, w.newest);
      if (phasesSeen.isEmpty || phasesSeen.last != tracker.phase) {
        phasesSeen.add(tracker.phase);
      }
    }
  }

  /// A streaming gap longer than ImuWindow.gapResetMs.
  void gap() {
    _ts += 6000;
  }

  /// Rest at the plate until the reference has seeded and converged.
  void settle({int samples = 60}) =>
      feed(samples, grav: plate, gyro: 0.5);

  /// Collect food: a gyro burst while still at plate attitude.
  void collect({int samples = 30}) =>
      feed(samples, grav: plate, gyro: 80);

  /// Swing up to `deg` with sustained rotation.
  void lift({double deg = 90, int samples = 70}) =>
      feed(samples, grav: tilt(deg), gyro: 80);

  /// Hold still at `deg` — the only moment attitude can be believed.
  void hold({double deg = 90, int samples = 60}) =>
      feed(samples, grav: tilt(deg), gyro: 5);

  /// Come back down to the plate.
  void comeBack({int samples = 80}) =>
      feed(samples, grav: plate, gyro: 60);

  /// Proposes at [t] and runs the stream on until a verdict exists.
  ///
  /// A verdict is not always available at proposal time: a dwell is only
  /// confirmed dwellMs after it starts, so the tracker waits up to
  /// mouthLagSamples for one to appear before deciding there was none.
  BiteCycleOutcome resolve(int t, {int extra = 260}) {
    final immediate = tracker.propose(t);
    if (immediate != null) return immediate;
    feed(extra, grav: plate, gyro: 0.5);
    final resolved = tracker.drainResolved();
    return resolved.firstWhere((o) => o.t == t);
  }
}

/// Runs a full, well-formed bite and returns the tracker mid-flight so a
/// proposal can be placed at the mouth.
void main() {
  group('a real spoon trip is accepted', () {
    test('load, lift, dwell, return', () {
      final tr = Trace();
      tr.settle();
      tr.collect();
      tr.lift();
      tr.hold();
      // The proposal lands while the spoon is at the mouth, as it does in
      // production (BiteDetector confirms a peak ~1.7 s after the moment).
      final t = tr.newest;
      expect(tr.phase, BitePhase.mouth,
          reason: 'trace should have reached the mouth');
      expect(tr.tracker.propose(t), isNull,
          reason: 'verdict must defer until the spoon comes back');

      tr.comeBack();
      final resolved = tr.tracker.drainResolved();
      expect(resolved, hasLength(1));
      expect(resolved.single.accepted, isTrue);
      expect(resolved.single.dwellMeanDeltaDeg,
          greaterThanOrEqualTo(tr.tracker.config.deltaMinDeg));
      expect(resolved.single.hadLoad, isTrue);
    });

    test('a bowl held near the mouth still counts (no collection phase)', () {
      // `load` must never be a prerequisite: this eater never produces one,
      // and requiring it would reject their every bite.
      final tr = Trace();
      tr.settle();
      tr.lift();
      tr.hold();
      expect(tr.phase, BitePhase.mouth);
      final t = tr.newest;
      tr.tracker.propose(t);
      tr.comeBack();
      final resolved = tr.tracker.drainResolved();
      expect(resolved.single.accepted, isTrue);
      expect(resolved.single.hadLoad, isFalse);
    });
  });

  group('the four motions the user reported are rejected', () {
    test('a small wrist wiggle — noExcursion', () {
      final tr = Trace();
      tr.settle();
      // 10 degrees of waggle: the same SHAPE as a bite, a fraction of the size.
      for (var i = 0; i < 6; i++) {
        tr.feed(10, grav: tilt(10), gyro: 70);
        tr.feed(10, grav: plate, gyro: 70);
      }
      tr.feed(40, grav: plate, gyro: 3);
      final v = tr.resolve(tr.newest);
      expect(v.accepted, isFalse);
      expect(v.reason, BiteRejectReason.noExcursion);
    });

    test('stirring at the plate — noExcursion', () {
      final tr = Trace();
      tr.settle();
      // Sustained rotation that never leaves plate attitude.
      tr.feed(200, grav: tilt(8), gyro: 90);
      tr.feed(40, grav: plate, gyro: 3);
      final v = tr.resolve(tr.newest);
      expect(v.accepted, isFalse);
      expect(v.reason, BiteRejectReason.noExcursion);
    });

    test('gesturing with the spoon — noDwell', () {
      final tr = Trace();
      tr.settle();
      // Large motion, never held still: attitude can never be measured.
      void wave(int cycles) {
        for (var i = 0; i < cycles; i++) {
          tr.feed(12, grav: tilt(70), gyro: 90);
          tr.feed(12, grav: tilt(20), gyro: 90);
        }
      }

      wave(10);
      final t = tr.newest;
      expect(tr.tracker.propose(t), isNull);

      // Still waving. The lag window has to close with no dwell ever having
      // appeared — if the trace went quiet here the spoon would genuinely
      // have settled, and the right answer would be noExcursion instead.
      wave(12);
      final v = tr.tracker.drainResolved().firstWhere((o) => o.t == t);
      expect(v.accepted, isFalse);
      expect(v.reason, BiteRejectReason.noDwell);
    });

    test('carrying the spoon away — noReturn', () {
      final tr = Trace();
      tr.settle();
      tr.lift();
      tr.hold();
      expect(tr.phase, BitePhase.mouth);
      final t = tr.newest;
      expect(tr.tracker.propose(t), isNull);

      // Held at the new attitude and never brought back.
      tr.feed(500, grav: tilt(90), gyro: 4);
      final resolved = tr.tracker.drainResolved();
      expect(resolved, isNotEmpty);
      expect(resolved.first.accepted, isFalse);
      expect(resolved.first.reason, BiteRejectReason.noReturn);
    });
  });

  group('plate reference', () {
    test('learns the resting pose rather than assuming one', () {
      // This eater holds the spoon 30 degrees off the nominal pose. Their
      // bites must still read as a full excursion from THEIR plate.
      final tr = Trace();
      tr.feed(120, grav: tilt(30), gyro: 0.5);
      expect(tr.delta, lessThan(tr.tracker.config.plateToleranceDeg),
          reason: 'their own resting pose must read as "at the plate"');
    });

    test('re-learns after the spoon is set down somewhere new', () {
      final tr = Trace();
      tr.settle(samples: 120);
      // Set down in a new orientation and left there.
      tr.feed(4000, grav: tilt(50), gyro: 0.5);
      expect(tr.delta, lessThan(tr.tracker.config.plateToleranceDeg),
          reason: 'the new resting pose should have been adopted');
    });

    test('a carry does not poison the reference', () {
      final tr = Trace();
      tr.settle(samples: 120);
      final before = tr.delta;
      // Moving the spoon around must not be learned as a resting pose, because
      // learning is gated on both stillness and no cycle in progress.
      tr.feed(300, grav: tilt(80), gyro: 90);
      tr.feed(60, grav: plate, gyro: 0.5);
      expect(tr.delta, closeTo(before, 6.0),
          reason: 'back at the real plate, excursion should be ~0 again');
    });

    test('before plateReadyMs nothing is rejected', () {
      // With the real default the reference is unsettled for the first tens of
      // seconds — exactly when the first bites happen.
      final tr = Trace(const BiteCycleConfig());
      tr.settle(samples: 30);
      expect(tr.tracker.plateReady, isFalse);
      final v = tr.tracker.propose(tr.newest);
      expect(v, isNotNull);
      expect(v!.accepted, isTrue,
          reason: 'an unconverged reference must never reject a bite');
    });
  });

  group('every state times out and frees the machine', () {
    test('a stalled lift returns to idle and plate learning resumes', () {
      final tr = Trace();
      tr.settle();
      // Leave the plate, then hover without ever holding still.
      for (var i = 0; i < 40; i++) {
        tr.feed(10, grav: tilt(60), gyro: 90);
      }
      // It may well be mid-attempt again by now — a spoon still waving about
      // legitimately re-enters lift. What matters is that it did NOT hang:
      // the timeout fired and put it back through idle.
      expect(tr.phasesSeen, contains(BitePhase.idle),
          reason: 'the lift timeout must force idle');
      expect(tr.phasesSeen.indexOf(BitePhase.lift),
          lessThan(tr.phasesSeen.lastIndexOf(BitePhase.idle)),
          reason: 'idle must come back round AFTER the first lift');

      // The interlock is clear, so a new resting pose can be learned again.
      tr.feed(4000, grav: tilt(45), gyro: 0.5);
      expect(tr.delta, lessThan(tr.tracker.config.plateToleranceDeg),
          reason: 'learning must resume after a timeout');
    });

    test('a spoon parked at the mouth times out rather than hanging', () {
      final tr = Trace();
      tr.settle();
      tr.lift();
      tr.hold(samples: 600);
      expect(tr.phase, BitePhase.idle);
    });
  });

  test('a stream reset voids pending proposals without blaming the model', () {
    final tr = Trace();
    tr.settle();
    tr.lift();
    tr.hold();
    final t = tr.newest;
    expect(tr.tracker.propose(t), isNull);

    tr.gap();
    tr.feed(10, grav: plate, gyro: 0.5);

    final resolved = tr.tracker.drainResolved();
    expect(resolved, hasLength(1));
    expect(resolved.single.reason, BiteRejectReason.streamReset);
    expect(tr.phase, BitePhase.idle);
  });

  test('a verdict always arrives by the deadline', () {
    final cfg = Trace.testConfig().copyWithDeadline(120);
    final tr = Trace(cfg);
    tr.settle();
    tr.lift();
    tr.hold();
    final t = tr.newest;
    expect(tr.tracker.propose(t), isNull);

    // Never comes back, and the mouth timeout is far away — the deadline is
    // what has to answer.
    tr.feed(cfg.verdictDeadlineSamples + 10, grav: tilt(90), gyro: 4);
    final resolved = tr.tracker.drainResolved();
    expect(resolved, isNotEmpty);
    expect(resolved.first.t, t);
    expect(resolved.first.accepted, isFalse);
  });

  test('a proposal with no mouth anywhere near it is rejected', () {
    final tr = Trace();
    tr.settle();
    tr.lift();
    tr.hold();
    tr.comeBack();
    tr.feed(500, grav: plate, gyro: 0.5);
    // Long after the only mouth in the trace.
    final v = tr.resolve(tr.newest);
    expect(v.accepted, isFalse);
    expect(
      v.reason,
      anyOf(BiteRejectReason.noExcursion,
          BiteRejectReason.noMouthNearProposal),
    );
  });

  test('every rejection has a plain-language explanation', () {
    for (final r in BiteRejectReason.values) {
      final o = BiteCycleOutcome(t: 0, accepted: false, reason: r);
      expect(o.explanation, isNotEmpty);
      expect(o.explanation, isNot(contains('null')));
    }
    expect(const BiteCycleOutcome(t: 0, accepted: true).explanation, 'Counted');
  });
}

extension on BiteCycleConfig {
  BiteCycleConfig copyWithDeadline(int samples) => BiteCycleConfig(
        enforce: enforce,
        plateToleranceDeg: plateToleranceDeg,
        deltaRiseDeg: deltaRiseDeg,
        deltaMinDeg: deltaMinDeg,
        dwellMs: dwellMs,
        dwellGyroDps: dwellGyroDps,
        burstGyroDps: burstGyroDps,
        burstMinMs: burstMinMs,
        sustainedGyroDps: sustainedGyroDps,
        returnDropDeg: returnDropDeg,
        stillGyroDps: stillGyroDps,
        plateTauSec: plateTauSec,
        plateReadyMs: plateReadyMs,
        loadTimeoutMs: loadTimeoutMs,
        liftTimeoutMs: liftTimeoutMs,
        mouthTimeoutMs: 60000,
        returnTimeoutMs: returnTimeoutMs,
        mouthWindowSamples: mouthWindowSamples,
        verdictDeadlineSamples: samples,
      );
}
