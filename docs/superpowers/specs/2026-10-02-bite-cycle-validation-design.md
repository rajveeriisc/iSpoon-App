# Bite cycle validation — design

**Date:** 2026-10-02
**Status:** implemented 2026-10-06, shipping dark. Approved 2026-10-02; revised
after spec review (10 findings, 9 acted on) and again after implementation —
see "What the real meals changed" at the end.
**Problem owner:** false-positive bites reported on real use

## Problem

The on-phone bite model counts bites that were not bites. Confirmed by the user
across four distinct motions:

1. small wrist wiggle / fidgeting
2. stirring or scooping at the plate
3. picking up, putting down, carrying
4. gesturing or talking with the spoon in hand

### Root cause

Three findings from the current engine, each verified in source:

1. **Every one of the 13 features is relative.** `bite_features.dart` builds
   tilt *changes* (`_angle(t, t-50)`, `_angle(t, t-250)`, `_angle(t, t+150)`)
   and gyro *rates/integrals*. None encodes absolute attitude. A 10 degree
   wiggle and a 90 degree lift are the same *shape* of signal at different
   amplitude, so a small motion can cross threshold.
2. **The decision threshold is 0.35** (`assets/models/ai_lab_model.json`),
   tuned for recall (96.9%) over precision (95.7%). Borderline motions pass.
3. **The "not eating" class was never trained.** The model saw 160 bites from
   8 people on 2026-09-11. `tools/ai_lab/train_bite_model.py` asks for
   carrying / stirring / washing clips; they do not exist. The model has never
   been shown the motions that are now false-triggering it.

A magnitude threshold cannot fix this, because carrying and gesturing are
*large* motions. The discriminator has to be the shape of a mouth trip.

## Approach

Keep the logistic model as the **mouth-moment proposer** — it is good at that
(F1 0.963 leave-one-person-out). Add a phase tracker that **validates** each
proposal against the physical eating cycle, and only count validated ones.

Rejected alternatives:

- **Retrain as a multi-class phase classifier.** The correct endpoint, but
  there are zero phase labels today. Weeks of recording and labelling before it
  beats the current model. This design produces the labelled negatives that
  make it possible later.
- **Raise the threshold and add a magnitude floor.** One line, but only removes
  the small false bites. Leaves cases 3 and 4, which the user reports.

## The attitude signal

```
delta(t) = angle( grav(t), grav_plate )
```

`grav*` in `imu_window.dart` is an exponential low-pass of the accelerometer
(tau = 0.15 s), i.e. a real gravity estimate. So `delta` is **absolute**
attitude excursion from the spoon's resting pose, in degrees, and cannot drift
(it is not integrated).

Taken against the full gravity vector rather than one body axis, so it makes no
assumption about how the PCB is mounted in the handle. Same `acos` form as the
existing `_angle`.

`grav_plate` is **learned per meal**: exponential average (tau ~ 10 s) of
`grav(t)` over samples where `gyroMag` is below a stillness threshold and no
cycle is in progress. Grip and bowl angle vary per person, so a constant would
be wrong. It re-learns when the spoon is set down somewhere new, which is also
what makes "carrying" resolve correctly rather than poisoning the reference.

**Not available:** absolute height. There is no reliable position integration
from this IMU, so "the spoon went up" is inferred from attitude and rotation
only. No part of this design may claim to measure height.

## Phase machine

States: `idle -> load -> lift -> mouth -> return -> idle`, plus a direct
`idle -> lift`.

`load` is **not** a prerequisite. Someone eating from a bowl held near the mouth
never produces a plate-attitude collection phase, so requiring `load` would
reject their every bite. The machine carries `hadLoad` as a boolean beside the
state: it raises confidence and appears in the log, and is never on its own a
reason to reject.

| transition | condition |
|---|---|
| `idle -> load` | `delta <= plateToleranceDeg` AND `gyroMag >= burstGyroDps` for >= `burstMinMs` |
| `idle -> lift` | `delta >= deltaRiseDeg` from any resting pose (`hadLoad = false`) |
| `load -> lift` | `delta >= deltaRiseDeg` AND `gyroMag >= sustainedGyroDps` |
| `lift -> mouth` | `gyroMag <= dwellGyroDps` continuously for >= `dwellMs` |
| `mouth -> return` | `delta` falls `returnDropDeg` below the dwell peak (hysteresis, not a first difference) |
| `return -> idle` | `delta <= plateToleranceDeg` |

### Where the excursion is actually measured

**`deltaMinDeg` is tested during the mouth dwell, not during the lift.**

A tau = 0.15 s low-pass of the accelerometer is a good gravity estimate only
while linear acceleration is small. Through the swing it is contaminated by arm
acceleration and can be wrong by tens of degrees. So:

- `deltaRiseDeg` is a **coarse trigger only**, deliberately loose: it decides
  "something is moving away from the plate", nothing more.
- `deltaMinDeg` is the **authoritative excursion test**, evaluated on the mean
  `delta` across the dwell, where `gyroMag <= dwellGyroDps` means the gravity
  estimate can be believed.

This is why the dwell is load-bearing here and not just one condition among
several: it is the only moment in a bite when attitude is trustworthy.

`delta` is drift-free because it is never integrated, but it is **not** a clean
attitude measurement under acceleration. Both statements matter; the first
draft asserted only the first.

### Every state times out

Each non-idle state carries a timeout. On expiry the machine forces `idle`,
emits the reason below, and **clears the cycle-in-progress interlock** so
`grav_plate` learning resumes. Without this, a carry that ends with the spoon
set down somewhere new parks the machine forever and freezes the plate
reference permanently — the opposite of the intended behaviour.

### Rejection reasons

| reason | the motion it catches |
|---|---|
| `noExcursion` | wiggle or stirring — dwell-mean `delta` below `deltaMinDeg` |
| `noDwell` | gesturing — never held still long enough to measure attitude |
| `noReturn` | carrying / putting down — left plate attitude, never came back |
| `noMouthNearProposal` | the model proposed a bite with no dwell near it |
| `streamReset` | a BLE gap voided the cycle; not evidence about the model |

`noExcursion` absorbs what the first draft called `stayedAtPlate`: with
`plateToleranceDeg = 15` and `deltaRiseDeg = 25`, a motion peaking at 20 degrees
satisfies both descriptions and no state represents that band, so the two were
not separable. The log records `peakDeltaDeg` and `hadLoad`, so stirring and
fidgeting can still be told apart after the fact.

## Acceptance rule

When `BiteDetector` returns a proposal at window index `t`, accept only if all
of:

1. the machine entered `mouth` at index `m` with `|m - t| <= mouthWindowSamples`
2. the dwell-mean `delta` for that mouth phase `>= deltaMinDeg`
3. the machine then entered `return`

Condition 3 usually resolves **after** the proposal arrives. `BiteFeatures.due`
places `t` at `newest - 150`, and `BiteDetector` confirms a peak two decisions
later, so at proposal time the newest sample is `t + 170` — while
`return -> idle` routinely lands later, and in the `noReturn` case never lands.

So verdicts are **deferred**. A proposal is held pending until the first of:

- `return` entry -> **accept**
- a state timeout -> **reject** with that state's reason
- `verdictDeadlineSamples` after `t` -> **reject `noReturn`**

### Consequence, stated plainly

With `enforce: true`, an accepted bite can be reported up to
`verdictDeadlineSamples` (4 s) later than today. The live counter becomes
slightly laggier in exchange for being correct.

With `enforce: false` the bite counts immediately exactly as today and the
verdict is logged when it resolves, so shadow mode has **zero** behavioural
change, latency included.

## Index space and stream resets

All tracker indices are window-relative — the same space as `DetectedBite.t`.

`ImuWindow.add` calls `clear()` on a timestamp gap over 5 s, resetting indices
to 0 **and** re-seeding the gravity estimate from the next raw accelerometer
sample; `EatingEngine.feed` already resets `_detector`, `_steadiness` and
`_segmentStart` there. The tracker must reset too:

- state -> `idle`, `hadLoad` -> false
- every pending proposal resolved as `streamReset`, never counted against the
  model's precision
- `grav_plate` re-bootstrapped

Without this, index-based acceptance silently misaligns across a reconnect.

## Plate reference

`grav_plate` = exponential average (`plateTauSec`) of `grav(t)` over samples
where `gyroMag <= stillGyroDps` and no cycle is in progress.

- **Bootstrap:** seeded from the first sample with `gyroMag <= stillGyroDps`
  after a reset, so it is never an average over nothing.
- **Not-ready rule:** until `plateReadyMs` has elapsed, the tracker emits phases
  for the UI but **never rejects a proposal**. With `plateTauSec = 10` the
  reference is unsettled for the first tens of seconds of a meal — exactly when
  the first bites happen — and rejecting against an unconverged reference would
  drop them.

## Thresholds

Live in `assets/models/ai_lab_model.json` under a new `biteCycle` object, with
documented defaults in code when absent — the pattern already used by
`minMotionRmsDps`. Tunable with the model rather than hardcoded in logic.

```
biteCycle: {
  enforce: false,

  // excursion
  plateToleranceDeg: 15.0,
  deltaRiseDeg: 25.0,        // coarse trigger, read mid-swing
  deltaMinDeg: 40.0,         // authoritative, read during the dwell

  // dwell
  dwellMs: 200,
  dwellGyroDps: 25.0,

  // activity
  burstGyroDps: 60.0,        // "a gyro burst" (collection)
  burstMinMs: 150,
  sustainedGyroDps: 40.0,    // "sustained rotation" during the lift

  // return, with hysteresis so low-pass noise cannot trigger it
  returnDropDeg: 8.0,

  // plate reference
  stillGyroDps: 15.0,
  plateTauSec: 10.0,
  plateReadyMs: 8000,        // before this: phases only, never a rejection

  // state timeouts
  loadTimeoutMs: 8000,
  liftTimeoutMs: 3000,
  mouthTimeoutMs: 4000,
  returnTimeoutMs: 5000,

  // acceptance
  mouthWindowSamples: 60,       // mouth entry within t +/- 0.6 s
  verdictDeadlineSamples: 400   // decide by t + 4 s
}
```

Initial values are starting points from the geometry of a spoon trip, not
measurements. They are expected to change once real verdicts are reviewed —
which is what `enforce: false` is for.

## Rollout: ships dark

`biteCycle.enforce = false` in the shipped model file. Verdicts are computed
and logged, but **every proposal still counts**, so bite totals are byte-for-
byte today's behaviour. Enforcement is switched on only after real verdicts
from real meals have been reviewed and thresholds tuned.

This is deliberate: an untuned gate that silently undercounts meals is worse
than the false positives it replaces.

## Verdict log (for a possible future retrain)

Each resolved proposal is appended to a bounded in-memory ring buffer: `t`,
verdict, reason, `peakDeltaDeg`, dwell-mean `delta`, `hadLoad`, phase durations.

**This is not the existing recorder.** `TrainingRecorder` only accumulates rows
while `isRecording` is true — started by hand from "Record a labelled meal" —
and writes a fixed 21-column CSV whose schema `train_bite_model.py` depends on.
The first draft claimed negatives would come "from ordinary use" through it;
that was wrong.

In scope: the ring buffer, and a debug export of it as its own sidecar CSV
triggered from the Mealsense page. Out of scope: changing the `TrainingRecorder`
schema, and any always-on background capture. Whether these verdicts become
training labels is a later decision, once there is data to look at.

## UI

On the renamed page (see below):

- a live phase chip: *Collecting food · Lifting · At mouth · Returning*
- a "not counted" list with the plain-language reason per rejection

Both render state the tracker genuinely holds. No inferred hand path, no
drawn hand — there is no position signal to justify either.

## Naming (done, recorded here)

`AI Lab` is now **Mealsense** in the UI. Scope was user-visible strings only:
nav label and icon, page title, two live-card states, the empty-state line, two
Insights captions, one BLE-settings subtitle.

Deliberately **not** renamed: `lib/features/ai_lab/`, class names, the model
asset path, debug log lines. "AI Lab" appears 68 times across 20+ files
including non-UI code; renaming those is churn that collides with every other
open change and buys the user nothing.

Health framing moved to eating language in the same pass (`Health overview` ->
`Eating overview`, `Health Insights` -> `Eating Insights`, `Health Star` ->
`Mindful Eater`, two FAQ phrasings). Internal identifiers were left alone on
purpose: `health_alerts`, `healthAlertsEnabled` and `/api/health` are
notification and backend contracts. The "worth mentioning to a doctor" line was
removed, because the detector behind it is explicitly not validated on people
with tremor.

## Components

| unit | responsibility | depends on |
|---|---|---|
| `BiteCycleTracker` (new) | attitude excursion, phase machine, verdicts | `ImuWindow` only |
| `BiteDetector` (unchanged) | proposes mouth moments from the model | model weights |
| `EatingEngine` | wires tracker to detector, applies `enforce` | both |
| `MealTracker` | counts accepted bites | engine |

`BiteCycleTracker` is a separate file with no Flutter dependency so it can be
tested on synthetic traces alone.

## Testing

1. One synthetic trace per rejection reason, asserting that reason.
2. A full synthetic cycle (load, lift, dwell, return) asserting acceptance.
3. `grav_plate` learning: tracker adapts after the spoon is set down in a new
   orientation, and a carry does not poison the reference.
4. `enforce: false` leaves the accepted count identical to the proposal count
   — the shipped-dark guarantee, as a test.
5. Thresholds are read from JSON; defaults apply when the object is absent.
6. Each state timeout fires, returns the machine to `idle` with the right
   reason, and `grav_plate` learning resumes afterwards.
7. A stream reset mid-cycle resolves pending proposals as `streamReset` and
   re-bootstraps the reference.
8. Before `plateReadyMs`, no proposal is rejected.
9. A deferred verdict resolves by `verdictDeadlineSamples` even when the spoon
   never returns to plate attitude.

## Risks

- **Gentle eaters.** A small, smooth bite may not reach `deltaMin`. Mitigated
  by shipping dark and tuning on real data before enforcing.
- **Bowl held near the mouth.** No plate attitude to return to. Mitigated by
  `load` never being a prerequisite (direct `idle -> lift`) and `grav_plate`
  tracking the actual resting pose.
- **Threshold drift.** Values in JSON with code defaults; a test asserts the
  code does not re-hardcode them.

---

## What the real meals changed (2026-10-06, implementation)

The design was written from the geometry of a spoon trip. Replaying it against
the two labelled meals in `test/fixtures/ai_lab` immediately contradicted it:
the brisk eater kept 19 of 19 bites, and the gentle eater **lost 11 of 21**.
All five changes below came out of that measurement.

### 1. `idle -> lift` needs motion, not just excursion

As specified the transition was `delta >= deltaRiseDeg` alone, so a spoon
simply **set down at a new angle** read as a permanent lift: it entered `lift`,
timed out, re-entered on the next sample, and plate learning — gated on no
cycle being in progress — never got the still samples it needs to adopt the new
pose. The reference stayed wrong for the rest of the meal, which is the exact
failure the learned reference exists to avoid.

Now also requires `gyro > stillGyroDps`. Gated on the stillness threshold
rather than `sustainedGyroDps` so a gentle lift still qualifies; it only has to
separate "moving" from "sitting there".

### 2. `load -> lift` asks whether a swing happened recently, not right now

Requiring `delta >= deltaRiseDeg` AND `gyro >= sustainedGyroDps` on the **same
sample** was brittle. In a slower lift the two conditions pass each other, and
the machine never leaves `load`: measured occupancy was 43% of the meal in
`load` for the gentle eater against 26% for the brisk one. The rotation test is
now a recency check over `liftTimeoutMs`.

### 3. The mouth window has to be asymmetric — `mouthLagSamples`

The biggest single cause. A dwell can only be **confirmed** `dwellMs` after it
begins, and a gentle eater decelerates slowly, so the machine enters `mouth`
well after the kinematic moment the model fired on. Measured signed lag:

| eater | slack needed |
|---|---|
| brisk | 4 samples |
| gentle | up to 159 samples |

Against the specified symmetric `mouthWindowSamples = 60`, 9 of the gentle
eater's proposals were rejected `noMouthNearProposal` — while the tracker had
in fact found 22 mouth dwells for ~20 real bites. The machine was right and the
acceptance rule was wrong.

Acceptance now measures against the whole dwell **span**, with
`mouthLagSamples = 200` after the proposal and `mouthWindowSamples = 60`
before it. `propose` therefore has to be able to **defer with no cycle bound
at all**, waiting for a dwell that has not been confirmed yet.

### 4. The dwell mean is measured only inside `mouth`

It was accumulated from the moment gyro fell below `dwellGyroDps`, i.e. part
way through the lift. A brisk eater decelerates fast enough that it barely
mattered; a gentle one coasts down over several hundred milliseconds, and
averaging that rising tail in dragged the dwell mean to 19-28 degrees against a
true hold nearer 45.

### 5. `deltaMinDeg` is a floor; the real test is per person

The core mistake was a single absolute angle for everybody. Measured dwell-mean
excursion:

| eater | min | median | max | learned reference |
|---|---|---|---|---|
| brisk | 48.6 | 54.3 | 57.8 | 54.8 |
| gentle | 18.7 | 43.6 | 55.0 | 44.4 |

`deltaMinDeg = 40` passed all 19 brisk bites and rejected 10 of 21 gentle ones.
So the threshold is now
`max(deltaMinDeg, reference * excursionFraction)`, where the reference is an
EMA (`excursionRefTauCycles = 8`) of this person's dwell excursions, learned
exactly as `grav_plate` is and for exactly the same reason.

`deltaMinDeg` drops to **25**, now meaning "not a bite for anybody" — set from
the separation actually measured against the motions being rejected (a wrist
wiggle peaks near 10 degrees, stirring near 8). `excursionFraction = 0.5` was
chosen from a sweep: 0.60 gave 16/21, 0.50 gave 18/21, and below 0.50 nothing
improved because the absolute floor binds instead.

The reference is only updated from dwells that clear the floor, so stirring and
fidgeting cannot drag it down, and it is updated **after** the verdict so a
dwell is never graded against itself.

### Where it stands

| eater | proposals | accepted | rejected |
|---|---|---|---|
| brisk | 19 | 19 | — |
| gentle | 21 | 18 | 3 x `noExcursion` |

The gentle eater's replay golden is 18-22 bites, so 18 is inside it. The three
rejected dwells measure roughly 0, 16 and 24 degrees against that person's
44 degree typical, and may well be genuine false positives — the gate's whole
purpose. There is no way to tell from two meals.

**`enforce` stays false.** Two labelled meals is not a tuning set, and one of
them had to be rescued three times during implementation. The thresholds are
guarded by `test/ai_lab/bite_cycle_config_test.dart`, which fails if either
eater regresses.

