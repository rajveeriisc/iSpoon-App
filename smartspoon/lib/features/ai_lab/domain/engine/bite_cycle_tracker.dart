// bite_cycle_tracker.dart — validates a proposed bite against the physical
// eating cycle: collect, lift, hold at the mouth, come back.
//
// The logistic model in BiteDetector is a good *mouth-moment proposer*
// (F1 0.963 leave-one-person-out) but every one of its 13 features is
// relative — tilt changes and gyro rates, no absolute attitude. A 10 degree
// wiggle and a 90 degree lift are the same shape of signal at different
// amplitude, so small fidgets, stirring, carrying and gesturing all cross the
// 0.35 threshold. The model has also never been shown a "not eating" class:
// it saw 160 bites from 8 people and nothing else.
//
// A magnitude threshold cannot fix that, because carrying and gesturing are
// *large* motions. The discriminator has to be the SHAPE of a mouth trip, so
// this tracker measures absolute attitude excursion from the spoon's resting
// pose and runs a phase machine over it.
//
// Pure Dart, depends on ImuWindow only, so it can be tested on synthetic
// traces with no Flutter and no device.
import 'dart:math' as math;

import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/imu_window.dart';

/// Where in the eating cycle the spoon is. Rendered as a live chip.
enum BitePhase { idle, load, lift, mouth, returning }

/// Why a proposal was not counted.
enum BiteRejectReason {
  /// Wiggle or stirring: the dwell-mean excursion never reached deltaMinDeg.
  noExcursion,

  /// Gesturing: the spoon was never held still long enough to measure
  /// attitude at all.
  noDwell,

  /// Carrying or putting down: it left plate attitude and never came back.
  noReturn,

  /// The model proposed a bite with no mouth dwell anywhere near it.
  noMouthNearProposal,

  /// A BLE gap voided the cycle. This is not evidence about the model and
  /// must never be counted against its precision.
  streamReset,
}

/// A resolved verdict on one proposal.
class BiteCycleOutcome {
  const BiteCycleOutcome({
    required this.t,
    required this.accepted,
    this.reason,
    this.peakDeltaDeg = 0,
    this.dwellMeanDeltaDeg = 0,
    this.hadLoad = false,
    this.loadMs = 0,
    this.liftMs = 0,
    this.mouthMs = 0,
  });

  /// Window index of the proposal this answers.
  final int t;
  final bool accepted;

  /// Set only when [accepted] is false.
  final BiteRejectReason? reason;

  /// Largest excursion seen anywhere in the cycle, degrees.
  final double peakDeltaDeg;

  /// Mean excursion across the dwell — the authoritative figure, measured
  /// where the gravity estimate can be believed.
  final double dwellMeanDeltaDeg;

  /// Whether a collection phase preceded the lift. Raises confidence and is
  /// logged, but is never on its own a reason to reject: someone eating from a
  /// bowl held near the mouth never produces one.
  final bool hadLoad;

  final int loadMs;
  final int liftMs;
  final int mouthMs;

  /// Plain-language line for the "not counted" list.
  String get explanation {
    if (accepted) return 'Counted';
    switch (reason!) {
      case BiteRejectReason.noExcursion:
        return 'The spoon stayed near the plate — looked like stirring or a '
            'small hand movement.';
      case BiteRejectReason.noDwell:
        return 'The spoon never paused — looked like gesturing with it in hand.';
      case BiteRejectReason.noReturn:
        return 'The spoon left the plate and did not come back — looked like '
            'carrying or putting it down.';
      case BiteRejectReason.noMouthNearProposal:
        return 'No pause at the mouth happened around this movement.';
      case BiteRejectReason.streamReset:
        return 'The connection dropped mid-movement, so this one could not be '
            'checked.';
    }
  }
}

/// One pass through the cycle. Kept briefly after it ends so a proposal, which
/// arrives about 1.7 s late, can still bind to the mouth it belongs to.
class _Cycle {
  _Cycle(this.startIdx);

  final int startIdx;
  int? loadEntry;
  int? liftEntry;
  int? mouthEntry;
  int? returnEntry;
  int? loadEntryMs;
  int? liftEntryMs;
  int? mouthEntryMs;
  int? returnEntryMs;
  int? endMs;

  bool hadLoad = false;
  double peakDelta = 0;

  /// Excursion accumulated over the quiet run, i.e. the dwell.
  double quietSum = 0;
  int quietCount = 0;

  /// Highest excursion during the mouth phase, for the return hysteresis.
  double mouthPeakDelta = 0;

  /// Set when a state timed out, with the reason to report.
  BiteRejectReason? timeoutReason;

  double get dwellMean => quietCount == 0 ? 0 : quietSum / quietCount;

  int _span(int? from, int? to) =>
      (from == null || to == null) ? 0 : math.max(0, to - from);

  int get loadMs => _span(loadEntryMs, liftEntryMs ?? endMs);
  int get liftMs => _span(liftEntryMs, mouthEntryMs ?? endMs);
  int get mouthMs => _span(mouthEntryMs, returnEntryMs ?? endMs);
}

class _Pending {
  _Pending(this.t, [this.cycle]);
  final int t;

  /// Null while no mouth dwell has been confirmed yet. A dwell is only
  /// recognised dwellMs after it begins, so at proposal time the mouth this
  /// bite belongs to may still be in the future.
  _Cycle? cycle;
}

class BiteCycleTracker {
  BiteCycleTracker(this.config);

  final BiteCycleConfig config;

  /// Keep a few finished cycles so a late proposal can still find its mouth.
  static const int _cycleHistory = 4;

  /// Bounded ring of resolved verdicts, for review and a possible retrain.
  static const int _logCapacity = 200;

  BitePhase _phase = BitePhase.idle;
  BitePhase get phase => _phase;

  /// Learned resting pose of the spoon. Grip and bowl angle vary per person,
  /// so a constant would be wrong; this re-learns whenever the spoon is set
  /// down somewhere new.
  double _plateX = 0, _plateY = 0, _plateZ = 0;
  bool _plateSeeded = false;
  int? _plateSeededMs;

  /// Running typical dwell excursion for THIS person, degrees. Null until the
  /// first qualifying dwell. Learned, for the same reason the plate pose is:
  /// grip, bowl height and how far someone tips the spoon vary per person, so
  /// a constant angle would fit one eater and reject another.
  double? _dwellRef;
  double? get excursionReferenceDeg => _dwellRef;

  /// The excursion a dwell must reach right now to count as a bite.
  double get effectiveDeltaMinDeg {
    final ref = _dwellRef;
    if (ref == null) return config.deltaMinDeg;
    return math.max(config.deltaMinDeg, ref * config.excursionFraction);
  }

  /// Current absolute excursion from the resting pose, degrees.
  double _delta = 0;
  double get deltaDeg => _delta;

  /// False until the reference has had time to converge. Until then the
  /// tracker reports phases but never rejects anything.
  bool get plateReady {
    final seeded = _plateSeededMs;
    if (seeded == null || _nowMs == null) return false;
    return _nowMs! - seeded >= config.plateReadyMs;
  }

  int? _nowMs;
  int _lastIdx = 0;
  int? _phaseEntryMs;

  /// Run of consecutive samples quieter than dwellGyroDps.
  int? _quietStartMs;

  /// Run of consecutive samples louder than burstGyroDps, at plate attitude.
  int? _burstStartMs;

  /// When vigorous rotation was last seen. A lift out of the collection phase
  /// has to involve a real swing, but requiring the swing and the excursion to
  /// land on the SAME sample was brittle: in a slower lift the two conditions
  /// pass each other and the machine never leaves `load`. Measured on the two
  /// real meals, that stranded the slow eater in `load` for 43% of the meal
  /// against 26% for the typical eater, and cost 11 of 21 true bites. So the
  /// rotation test asks whether a swing happened RECENTLY, not right now.
  int? _lastSustainedMs;

  final List<_Cycle> _cycles = [];
  final List<_Pending> _pending = [];
  final List<BiteCycleOutcome> _resolved = [];
  final List<BiteCycleOutcome> _log = [];

  /// Verdicts resolved so far this meal, oldest first.
  List<BiteCycleOutcome> get log => List.unmodifiable(_log);

  _Cycle? get _current => _cycles.isEmpty ? null : _cycles.last;

  bool get _inCycle => _phase != BitePhase.idle;

  /// Clears everything that depends on stream continuity. Every pending
  /// proposal resolves as [BiteRejectReason.streamReset], and the plate
  /// reference is re-bootstrapped from the next quiet sample.
  void reset() {
    for (final p in _pending) {
      _resolve(BiteCycleOutcome(
        t: p.t,
        accepted: false,
        reason: BiteRejectReason.streamReset,
        peakDeltaDeg: p.cycle?.peakDelta ?? 0,
        dwellMeanDeltaDeg: p.cycle?.dwellMean ?? 0,
        hadLoad: p.cycle?.hadLoad ?? false,
      ));
    }
    _pending.clear();
    _cycles.clear();
    _phase = BitePhase.idle;
    _plateSeeded = false;
    _plateSeededMs = null;
    _delta = 0;
    _nowMs = null;
    _quietStartMs = null;
    _burstStartMs = null;
    _lastSustainedMs = null;
    _lastIdx = 0;
    _dwellRef = null;
  }

  /// Verdicts that resolved since the last call. The caller counts the
  /// accepted ones when enforcing.
  List<BiteCycleOutcome> drainResolved() {
    if (_resolved.isEmpty) return const [];
    final out = List<BiteCycleOutcome>.unmodifiable(_resolved);
    _resolved.clear();
    return out;
  }

  void _resolve(BiteCycleOutcome o) {
    _resolved.add(o);
    _log.add(o);
    if (_log.length > _logCapacity) _log.removeAt(0);
  }

  double _angleToPlate(ImuWindow w, int i) {
    final ux = w.gravX(i), uy = w.gravY(i), uz = w.gravZ(i);
    final dot = ux * _plateX + uy * _plateY + uz * _plateZ;
    final nu = math.sqrt(ux * ux + uy * uy + uz * uz);
    final nv =
        math.sqrt(_plateX * _plateX + _plateY * _plateY + _plateZ * _plateZ);
    final c = (dot / (nu * nv + 1e-9)).clamp(-1.0, 1.0);
    return math.acos(c) * 180.0 / math.pi;
  }

  void _enter(BitePhase next, int i, int tsMs) {
    _phase = next;
    _phaseEntryMs = tsMs;
    final c = _current;
    switch (next) {
      case BitePhase.load:
        c?.loadEntry = i;
        c?.loadEntryMs = tsMs;
        c?.hadLoad = true;
      case BitePhase.lift:
        c?.liftEntry = i;
        c?.liftEntryMs = tsMs;
      case BitePhase.mouth:
        c?.mouthEntry = i;
        c?.mouthEntryMs = tsMs;
      case BitePhase.returning:
        c?.returnEntry = i;
        c?.returnEntryMs = tsMs;
      case BitePhase.idle:
        c?.endMs = tsMs;
    }
  }

  _Cycle _beginCycle(int i) {
    final c = _Cycle(i);
    _cycles.add(c);
    if (_cycles.length > _cycleHistory) _cycles.removeAt(0);
    return c;
  }

  /// Feeds the sample at window index [i]. Call once per sample, after
  /// [ImuWindow.add], with [i] == `w.newest`.
  void add(ImuWindow w, int i) {
    final tsMs = w.timestampMs(i);
    _nowMs = tsMs;
    _lastIdx = i;
    final gyro = w.gyroMag(i);

    // ── Plate reference ───────────────────────────────────────────────────
    // Learned only while the spoon is quiet and no cycle is running, so a
    // carry cannot poison it. Bootstrapped from the first quiet sample rather
    // than averaged from nothing.
    if (!_plateSeeded) {
      if (gyro <= config.stillGyroDps) {
        _plateX = w.gravX(i);
        _plateY = w.gravY(i);
        _plateZ = w.gravZ(i);
        _plateSeeded = true;
        _plateSeededMs = tsMs;
      } else {
        // No reference yet, so no excursion can be computed.
        _delta = 0;
        return;
      }
    } else if (!_inCycle && gyro <= config.stillGyroDps) {
      const dt = 0.01;
      final alpha = dt / (config.plateTauSec + dt);
      _plateX += alpha * (w.gravX(i) - _plateX);
      _plateY += alpha * (w.gravY(i) - _plateY);
      _plateZ += alpha * (w.gravZ(i) - _plateZ);
    }

    _delta = _angleToPlate(w, i);
    final c = _current;
    if (c != null && _inCycle) {
      if (_delta > c.peakDelta) c.peakDelta = _delta;
    }

    // ── Quiet / burst runs ────────────────────────────────────────────────
    if (gyro <= config.dwellGyroDps) {
      _quietStartMs ??= tsMs;
      // Accumulate the dwell excursion only once the machine has actually
      // reached `mouth`.
      //
      // This used to start as soon as gyro fell below dwellGyroDps, i.e.
      // part way through the lift. A brisk eater decelerates fast so it
      // barely mattered, but a gentle one coasts down over several hundred
      // milliseconds, and averaging that rising tail in dragged the mean well
      // below the real hold: the slow eater's dwell-means came out at 19-28
      // degrees against a true hold nearer 45. `mouth` is only entered after
      // dwellMs of quiet, so from there on the spoon is genuinely settled and
      // the gravity estimate can be believed.
      if (c != null && _phase == BitePhase.mouth) {
        c.quietSum += _delta;
        c.quietCount++;
      }
    } else {
      _quietStartMs = null;
    }

    if (gyro >= config.burstGyroDps) {
      _burstStartMs ??= tsMs;
    } else {
      _burstStartMs = null;
    }

    if (gyro >= config.sustainedGyroDps) _lastSustainedMs = tsMs;

    _step(i, tsMs, gyro);
    _bindWaiting(i);
    _expireDeadlines(i);
  }

  void _step(int i, int tsMs, double gyro) {
    final entryMs = _phaseEntryMs ?? tsMs;
    final inState = tsMs - entryMs;

    switch (_phase) {
      case BitePhase.idle:
        // idle -> load: a gyro burst while still at plate attitude.
        if (_delta <= config.plateToleranceDeg &&
            _burstStartMs != null &&
            tsMs - _burstStartMs! >= config.burstMinMs) {
          _beginCycle(i);
          _enter(BitePhase.load, i, tsMs);
          return;
        }
        // idle -> lift: leaving the resting pose without a collection phase.
        // `load` is deliberately NOT a prerequisite — a bowl held near the
        // mouth never produces one, and requiring it would reject every bite.
        //
        // The spoon must actually be MOVING, not merely resting at an angle
        // the reference has not caught up with. The design said excursion
        // alone, which made a spoon set down in a new orientation look like a
        // permanent lift: it entered lift, timed out, re-entered on the next
        // sample, and plate learning — gated on no cycle being in progress —
        // never got the still samples it needs to adopt the new pose. The
        // reference would then stay wrong for the rest of the meal.
        //
        // Gated on stillGyroDps rather than sustainedGyroDps so a gentle
        // lift still qualifies; this only has to separate "moving" from
        // "sitting there".
        if (_delta >= config.deltaRiseDeg && gyro > config.stillGyroDps) {
          _beginCycle(i);
          _enter(BitePhase.lift, i, tsMs);
        }

      case BitePhase.load:
        // Leaving the plate, with a real swing somewhere in the recent past.
        // The window is liftTimeoutMs: within the time a lift is allowed to
        // take, there must have been one.
        final swung = _lastSustainedMs != null &&
            tsMs - _lastSustainedMs! <= config.liftTimeoutMs;
        if (_delta >= config.deltaRiseDeg && swung) {
          _enter(BitePhase.lift, i, tsMs);
          return;
        }
        if (inState >= config.loadTimeoutMs) {
          _timeout(i, tsMs, BiteRejectReason.noExcursion);
        }

      case BitePhase.lift:
        // lift -> mouth: held still long enough that attitude can be believed.
        if (_quietStartMs != null &&
            tsMs - _quietStartMs! >= config.dwellMs) {
          _enter(BitePhase.mouth, i, tsMs);
          final c = _current;
          if (c != null && _delta > c.mouthPeakDelta) {
            c.mouthPeakDelta = _delta;
          }
          return;
        }
        if (inState >= config.liftTimeoutMs) {
          _timeout(i, tsMs, BiteRejectReason.noDwell);
        }

      case BitePhase.mouth:
        final c = _current;
        if (c != null && _delta > c.mouthPeakDelta) c.mouthPeakDelta = _delta;
        // mouth -> return: hysteresis below the dwell peak, not a first
        // difference, so low-pass noise cannot trigger it.
        if (c != null && _delta <= c.mouthPeakDelta - config.returnDropDeg) {
          _enter(BitePhase.returning, i, tsMs);
          _settleCycle(c);
          return;
        }
        if (inState >= config.mouthTimeoutMs) {
          _timeout(i, tsMs, BiteRejectReason.noReturn);
        }

      case BitePhase.returning:
        if (_delta <= config.plateToleranceDeg) {
          _enter(BitePhase.idle, i, tsMs);
          return;
        }
        if (inState >= config.returnTimeoutMs) {
          _timeout(i, tsMs, BiteRejectReason.noReturn);
        }
    }
  }

  /// Forces idle and clears the cycle-in-progress interlock, so plate learning
  /// resumes. Without this a carry that ends with the spoon set down somewhere
  /// new would park the machine forever and freeze the reference permanently.
  void _timeout(int i, int tsMs, BiteRejectReason reason) {
    final c = _current;
    if (c != null) {
      c.timeoutReason = reason;
      c.endMs = tsMs;
      _rejectPendingFor(c, reason);
    }
    _enter(BitePhase.idle, i, tsMs);
    _quietStartMs = null;
    _burstStartMs = null;
  }

  /// The cycle reached `return`, so its dwell excursion is final. Everything
  /// waiting on it can be answered now.
  void _settleCycle(_Cycle c) {
    for (final p in _pending.where((p) => p.cycle == c).toList()) {
      _pending.remove(p);
      _resolve(_verdictFor(p.t, c));
    }
    _learnExcursion(c);
  }

  void _rejectPendingFor(_Cycle c, BiteRejectReason reason) {
    for (final p in _pending.where((p) => p.cycle == c).toList()) {
      _pending.remove(p);
      _resolve(_outcomeFor(p.t, c, accepted: false, reason: reason));
    }
  }

  /// A proposal must get an answer even if the machine never resolves.
  void _expireDeadlines(int i) {
    for (final p in _pending.toList()) {
      if (i - p.t >= config.verdictDeadlineSamples) {
        _pending.remove(p);
        _resolve(BiteCycleOutcome(
          t: p.t,
          accepted: false,
          reason: BiteRejectReason.noReturn,
          peakDeltaDeg: p.cycle?.peakDelta ?? 0,
          dwellMeanDeltaDeg: p.cycle?.dwellMean ?? 0,
          hadLoad: p.cycle?.hadLoad ?? false,
          loadMs: p.cycle?.loadMs ?? 0,
          liftMs: p.cycle?.liftMs ?? 0,
          mouthMs: p.cycle?.mouthMs ?? 0,
        ));
      }
    }
  }

  /// Registers a model proposal at window index [t].
  ///
  /// Returns a verdict when one can be given now, or null when the answer has
  /// to wait for the machine — which is the normal case, because a proposal
  /// arrives about 1.7 s after the mouth moment while `return` usually lands
  /// later still. Deferred verdicts come back through [drainResolved].
  BiteCycleOutcome? propose(int t) {
    // Before the reference has converged, report phases but never reject.
    // With plateTauSec = 10 the reference is unsettled for the first tens of
    // seconds of a meal — exactly when the first bites happen.
    if (!plateReady) {
      final o = BiteCycleOutcome(t: t, accepted: true, peakDeltaDeg: _delta);
      _logOnly(o);
      return o;
    }

    final c = _cycleForProposal(t);
    if (c == null) {
      // No dwell yet. It may simply not have been confirmed — wait rather
      // than reject, until the lag window closes.
      if (_lastIdx - t < config.mouthLagSamples) {
        _pending.add(_Pending(t));
        return null;
      }
      final o = BiteCycleOutcome(
          t: t, accepted: false, reason: _nearMissReason(t));
      _logOnly(o);
      return o;
    }

    final timedOut = c.timeoutReason;
    if (timedOut != null) {
      final o = _outcomeFor(t, c, accepted: false, reason: timedOut);
      _logOnly(o);
      return o;
    }

    if (c.returnEntry != null) {
      final o = _verdictFor(t, c);
      _logOnly(o);
      return o;
    }

    _pending.add(_Pending(t, c));
    return null;
  }

  void _logOnly(BiteCycleOutcome o) {
    _log.add(o);
    if (_log.length > _logCapacity) _log.removeAt(0);
  }

  /// The cycle whose mouth dwell belongs to the proposal at [t].
  ///
  /// Measured against the whole dwell SPAN, not its entry index, and with a
  /// deliberately asymmetric tolerance — see
  /// [BiteCycleConfig.mouthLagSamples]. Matching on the entry index alone
  /// assumed every eater reaches the dwell threshold at about the same point
  /// after the model fires, which the slow eater disproved.
  _Cycle? _cycleForProposal(int t) {
    for (final c in _cycles.reversed) {
      final m = c.mouthEntry;
      if (m == null) continue;
      final end = c.returnEntry ?? _lastIdx;
      if (t < m) {
        if (m - t <= config.mouthLagSamples) return c;
      } else if (t > end) {
        if (t - end <= config.mouthWindowSamples) return c;
      } else {
        return c; // the proposal sits inside the dwell
      }
    }
    return null;
  }

  /// Answers proposals that were waiting for a dwell to appear.
  void _bindWaiting(int i) {
    for (final p in _pending.where((p) => p.cycle == null).toList()) {
      final c = _cycleForProposal(p.t);
      if (c != null) {
        p.cycle = c;
        final timedOut = c.timeoutReason;
        if (timedOut != null) {
          _pending.remove(p);
          _resolve(_outcomeFor(p.t, c, accepted: false, reason: timedOut));
        } else if (c.returnEntry != null) {
          _pending.remove(p);
          _resolve(_verdictFor(p.t, c));
        }
        continue;
      }
      if (i - p.t >= config.mouthLagSamples) {
        _pending.remove(p);
        _resolve(BiteCycleOutcome(
          t: p.t,
          accepted: false,
          reason: _nearMissReason(p.t),
        ));
      }
    }
  }

  BiteCycleOutcome _outcomeFor(
    int t,
    _Cycle c, {
    required bool accepted,
    BiteRejectReason? reason,
  }) =>
      BiteCycleOutcome(
        t: t,
        accepted: accepted,
        reason: reason,
        peakDeltaDeg: c.peakDelta,
        dwellMeanDeltaDeg: c.dwellMean,
        hadLoad: c.hadLoad,
        loadMs: c.loadMs,
        liftMs: c.liftMs,
        mouthMs: c.mouthMs,
      );

  /// The excursion test, once the dwell figure is final.
  BiteCycleOutcome _verdictFor(int t, _Cycle c) {
    // No dwell samples at all is a different failure from a dwell that was
    // too shallow, and the not-counted list should say so.
    if (c.quietCount == 0) {
      return _outcomeFor(t, c,
          accepted: false, reason: BiteRejectReason.noDwell);
    }
    final ok = c.dwellMean >= effectiveDeltaMinDeg;
    return _outcomeFor(t, c,
        accepted: ok, reason: ok ? null : BiteRejectReason.noExcursion);
  }

  /// Folds a finished dwell into this person's excursion reference.
  ///
  /// Gated on the absolute floor so stirring and fidgeting cannot drag the
  /// reference down, and applied AFTER the verdict so the test never grades a
  /// dwell against itself.
  void _learnExcursion(_Cycle c) {
    if (c.quietCount == 0) return;
    final mean = c.dwellMean;
    if (mean < config.deltaMinDeg) return;
    final ref = _dwellRef;
    if (ref == null) {
      _dwellRef = mean;
      return;
    }
    final alpha = 1.0 / math.max(1.0, config.excursionRefTauCycles);
    _dwellRef = ref + alpha * (mean - ref);
  }

  /// No mouth near the proposal. Distinguish "tried to lift but never paused"
  /// (gesturing) from "never really left the plate" (wiggle or stirring), so
  /// the not-counted list can say something useful.
  BiteRejectReason _nearMissReason(int t) {
    final span = config.liftTimeoutMs ~/ 10 + config.mouthWindowSamples;
    for (final c in _cycles.reversed) {
      final l = c.liftEntry;
      if (l != null && c.mouthEntry == null && (l - t).abs() <= span) {
        return BiteRejectReason.noDwell;
      }
    }
    for (final c in _cycles.reversed) {
      final m = c.mouthEntry;
      if (m != null && (m - t).abs() <= config.verdictDeadlineSamples) {
        return BiteRejectReason.noMouthNearProposal;
      }
    }
    return BiteRejectReason.noExcursion;
  }
}
