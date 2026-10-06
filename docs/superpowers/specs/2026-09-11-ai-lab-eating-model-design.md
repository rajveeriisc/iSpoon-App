# AI Lab — real-time eating model and user-facing page

Date: 2026-09-11 · Status: built. Scope widened 2026-09-15 — the model now
feeds the whole app, see the update under Goal.

## Goal

Turn the AI Lab tab from a data-collection test screen into a page a user
actually reads while and after eating. A trained on-phone model watches the
spoon's IMU stream, notices when the person starts eating, counts each bite
within ~2 s of it happening, measures hand steadiness, learns that person's own
eating pattern, and gives suggestions.

**Update, 2026-09-15 — the model became the app's only source.** Originally its
numbers stayed on the AI Lab page. They are now what the whole app shows:
`UnifiedDataService` takes its bites and its tremor index from `AiLabService`,
so Home, Insights, Meals Analysis, Bite History, the database and the cloud
sync all carry model numbers. The firmware bite counter and the app's
`MotionAnalysisService` and `TremorDetectionService` no longer feed any screen;
their code is commented out in place, not deleted.

The cost, chosen deliberately: **nothing is counted while the IMU stream is
off** — app closed, or the spoon used away from the phone. The firmware counter
is no longer a fallback. It is still shown on the BLE settings screen as a
device diagnostic, labelled as such.

## What the training data says

`~/Desktop/bites`: 8 recordings from **8 different people**, 20 bites each,
every bite tapped by the recorder when the spoon reached the mouth (160
per-bite labels). IMU at ~100 Hz; 3–11 s between bites (one slow eater ~9 s).

- The spoon never rests between bites (33–65 °/s throughout the cycle), so
  detectors that wait for a still moment miss or merge bites.
- The lift is a pitch about the spoon's **y** axis (sign-consistent in 89 % of
  bites). The yaw direction (**z**, 91 %) depends on the hand. All 8 people are
  right-handed.
- The current tremor score read up to 6.4 ("moderate") on these normal eaters.

Scored leave-one-person-out (train on 7 people, test on the 8th), a bite
matched if within ±1 s of the tap:

| Detector | F1 | Bites counted per meal (truth 20) |
|---|---|---|
| Current AI Lab frame detector | 0.40 | 2–12 |
| Firmware / `ImuBiteDetectorService` | 0.69 | 19–32 |
| Tuned "excursion apex" rule | 0.67–0.77 | 20–37 |
| **Chosen: logistic model, 13 features, causal peak picker** | **0.975** | **20–23** |
| Chosen, hand-neutral variant (until handedness known) | 0.91 | 20–31 |
| Chosen, with 10 % packets lost + gyro noise | 0.96 | 19–24 |

Shorter look-ahead was tested and rejected: 0 / 0.5 / 1.0 s look-ahead gave
F1 0.90 / 0.92 / 0.94 and lost most bites of the slow eater. A neural network
was not attempted: 160 bites is too little data; revisit at ~1000.

## Architecture

Pure-Dart engine (no Flutter imports, fully unit-testable) behind one
ChangeNotifier service; the page only reads the service.

```
SpoonRuntime.sensorBatchStream
        │  (samples of the active spoon only)
        ▼
AiLabService (ChangeNotifier, singleton, started in main.dart)
   ├─ EatingEngine ── ImuWindow → BiteFeatures → BiteDetector ──► bites
   │                  Handedness (votes from detected bites)
   │                  SteadinessAnalyzer (1 s hop FFT)
   │                  MealTracker (idle → eating → paused → ended)
   ├─ EatingInsights (pure functions: pattern metrics + coach tips)
   ├─ AiLabProfileStore (own SharedPreferences key, per spoon)
   └─ TrainingRecorder (optional labelled CSV capture)
        ▼
AiLabPage (redesigned)
```

The service starts with the app so a meal begun on another tab is not missed.
`UnifiedDataService` reads its bite total and steadiness, which is how every
other screen shows the same numbers.

### Files (`lib/features/ai_lab/`)

| File | Responsibility |
|---|---|
| `domain/engine/ai_lab_model.dart` | Parses `assets/models/ai_lab_model.json`: two weight sets (right-hand, hand-neutral), scaler, threshold, steadiness reference. |
| `domain/engine/imu_window.dart` | Ring buffer (401 samples) of gravity estimate (EMA τ 0.15 s), gyro and gyro magnitude; reset on a timestamp gap > 5 s. |
| `domain/engine/bite_features.dart` | The 13 features at decision time *t* = newest − 150 samples, every 10 samples. |
| `domain/engine/bite_detector.dart` | Standardise → logistic → 3-tap smoothing → causal peak picker (threshold and 2.5 s suppression come from the model JSON). |
| `domain/engine/handedness.dart` | Votes the yaw sign before the mouth over the first detected bites; 3 agreeing votes decide. Manual override wins. |
| `domain/engine/steadiness_analyzer.dart` | Every 100 samples: 256-sample Hann FFT of the 3 gyro axes, 4–12 Hz band; a window is "rhythmic" when the peak line's share of band power exceeds the normal P95. |
| `domain/engine/meal_tracker.dart` | Meal state machine and the bite list. |
| `domain/engine/eating_engine.dart` | Composes the above; `feed(samples)` and `tick(now)`; emits an immutable `EatingSnapshot`. |
| `domain/insights/eating_insights.dart` | Meal metrics, personal comparison, coach tips (pure). |
| `domain/services/ai_lab_profile_store.dart` | Per-spoon profile + last 20 meal summaries. |
| `domain/services/training_recorder.dart` | Labelled CSV recording (same column schema as today). |
| `domain/services/ai_lab_service.dart` | Stream subscription, active-spoon filtering, on-demand 1 s tick, persistence, and the bite/steadiness totals the rest of the app reads. |
| `presentation/screens/ai_lab_page.dart` | Redesigned page. |
| `presentation/widgets/*.dart` | One file per card. |

`ai_tremor_service.dart` and `personalized_eating_model.dart`'s use by AI Lab
are removed from the page; `personalized_eating_model.dart` stays (Home and
`unified_data_service` use it). The folder is untracked in git, so a copy of
the pre-redesign files is kept outside the repo.

## The bite model (must match `tools/ai_lab/train_bite_model.py` exactly)

Per sample *n* (arrival order, nominal 100 Hz; a timestamp jump > 5000 ms
resets the window — sample timestamps are the phone's receive time, and BLE
bunching produces 1–2 s jumps with no data lost, so a shorter limit discards
good data): gravity `g += a·(acc − g)`, `a = 0.01/(0.15+0.01)`;
`gm = |gyro|`. The window always holds raw samples. A left hand is the mirror
image across the spoon's x–z plane (accel y, gyro x and z negated); angles,
magnitudes and the reversal cosine are unchanged by that mirror, so it reduces
to negating features 10 and 12. The hand-neutral model uses their absolute
values instead. Changing hand mode therefore never resets the window.

*n* counts samples since the last reset (a reset also restarts the gravity
estimate from the next sample and clears the probability history). Once 401
samples are buffered, at every sample where `(n−150) % 10 == 0`, with
*t* = n − 150:

| # | Feature | Definition |
|---|---|---|
| 1 | ang_b0.5 | angle(g[t], g[t−50]) in degrees |
| 2 | ang_b2.5 | angle(g[t], g[t−250]) |
| 3 | ang_f1.5 | angle(g[t], g[t+150]) |
| 4 | apex | min(angle(g[t], g[t−150]), ang_f1.5) |
| 5 | gyro_back_mean | mean gm[t−150 … t−26] |
| 6 | gyro_back_max | max gm[t−150 … t−1] |
| 7 | gyro_fwd_max | max gm[t … t+149] |
| 8 | rot_back | Σ gm[t−200 … t−1] / 100 |
| 9 | rot_fwd | Σ gm[t … t+149] / 100 |
| 10 | rbx | Σ gx[t−150 … t−1] / 100 (hand-neutral model: absolute value) |
| 11 | rby | Σ gy[t−150 … t−1] / 100 |
| 12 | rfz | Σ gz[t … t+149] / 100 (hand-neutral model: absolute value) |
| 13 | reversal | cos(rb, rf) of the full back/forward rotation vectors |

`p = σ(w · (x − μ)/s + b)`; smoothed `ps[i] = mean(p[i−1], p[i], p[i+1])`;
decision *i* is a bite when `ps[i] ≥ 0.35`, `ps[i] ≥ ps[i−1]`,
`ps[i] ≥ ps[i+1]` and no bite was accepted in the previous 25 decisions
(2.5 s: slow eaters make a second approach ~2 s after a bite; the fastest
real gap in the data is 2.9 s). The
bite is timestamped at sample *t*; it is reported ~1.7 s later.

## Handedness

Until decided, the hand-neutral weights run. Each detected bite votes with the
sign of Σ gz over the 1.5 s before the mouth (positive = right hand). After 3
votes in the same direction the handedness is stored in the profile and the
right-hand weights run (left: on mirrored input). A user can set Right / Left /
Auto in the page's "Model & data" section. Left-handed accuracy is inferred
from mirrored data only; no real left-handed recording exists yet.

## Meal tracking

- **idle → eating**: 2 bites within 30 s. Both bites are counted. A lone bite
  that gets no second bite within 30 s is dropped.
- **eating → paused**: 60 s without a bite (the page says "Paused").
- **paused → eating**: next bite.
- **→ ended**: 3 min without a bite, the spoon stops streaming for 3 min, the
  active spoon changes, or the user taps "Finish meal". A meal with fewer than
  3 bites is discarded, not saved.
- On end: a `MealSummary` is saved to the AI Lab profile and shown as the
  post-meal card until the next meal starts.

## Hand steadiness

Tremor is shown as **hand steadiness**, never as a diagnosis.

- Window "rhythmic" = in the 4–12 Hz gyro band, the peak line (±1 bin) holds
  more than the normal-eater P95 share of band power (reference computed by
  the training script and stored in the model JSON).
- Meal steadiness = % of analysed windows during the meal that were not
  rhythmic. Normal eaters sit near 95 %.
- Labels: ≥ 90 % *Steady*, 75–90 % *Mostly steady*, < 75 % *Frequent rhythmic
  shaking*; the dominant frequency is shown only when shaking is flagged.
- Each bite carries the steadiness of the windows in its 2 s before the mouth,
  which colours its dot on the timeline.
- Validation so far is synthetic: tremor injected into the normal meals is
  flagged in 84 % of windows at 20 °/s RMS, 40 % at 10 °/s; normal eating 5 %.
  The page's "Model & data" section states this plainly.

## Eating pattern and coach

Metrics per meal: bites, duration, bites/min, mean seconds between bites
(overall and last 5), regularity (coefficient of variation of the gaps), speed
change (second half vs first half), pauses ≥ 60 s, steadiness.

Personal profile (per spoon key = product id, else device id; own prefs key
`ai_lab_profile_v1`): EWMA (α 0.2) of those metrics, meal count, handedness,
last 20 meal summaries. Comparisons to "your usual" start at 3 meals.

Coach tips (pure function of meal metrics + profile; at most 3, highest
priority first; live during the meal, summary after):

| Rule | Tip kind |
|---|---|
| last-5 mean gap < 10 s (mindful-eating target, from the augmented-fork literature) | nudge: rest the spoon between bites |
| mean gap ≥ 10 s | positive |
| second-half gaps < 0.8 × first-half (≥ 8 bites) | nudge: sped up near the end |
| ≥ 3 meals and pace ±20 % from usual | info: faster / slower than your usual |
| meal < 10 min with ≥ 15 bites (summary only) | nudge: longer meals help notice fullness |
| steadiness < 75 % | nudge: rest elbow on the table |
| steadiness < 75 % in ≥ 3 of the last 5 meals | info: worth mentioning to a doctor if it continues |
| otherwise | positive: steady, even pace |

Wording avoids medical claims.

## The page (top to bottom)

1. **Header** — "AI Lab · Eating coach", live chip (Live / Waiting for spoon).
2. **Live meal card** — state line (Waiting for spoon / Ready — start eating /
   Eating now / Paused / Meal finished), large bite count, meal timer,
   bites/min, ring showing seconds since the last bite against the 10 s target.
3. **Bite timeline** — a dot per bite along the meal's time axis, coloured by
   steadiness.
4. **Coach** — up to 3 tips.
5. **Hand steadiness** — steady %, label, rhythm frequency when flagged,
   position against the normal range.
6. **Your eating pattern** — this meal vs your usual (gap, regularity, speed
   change), learning progress, pace sparkline over the last 10 meals.
7. **Recent meals** — last 5 (date, bites, duration, mean gap, steadiness).
8. **Model & data** (collapsed) — handedness setting; model facts (trained on 8
   people, leave-one-person-out F1); "Record a labelled meal" (start, tap Bite,
   undo, save CSV — the existing recorder); live raw sensor chart.

Uses `AppTheme` colours and `fl_chart`; works in light and dark.

## Training apparatus (`tools/ai_lab/`)

- `train_bite_model.py --data ~/Desktop/bites`: implements the streaming
  feature extractor exactly as specified above; prints nested
  leave-one-person-out metrics for both weight sets; fits final weights on all
  people; computes the steadiness reference; writes
  `smartspoon/assets/models/ai_lab_model.json`, the parity golden file and two
  trimmed fixtures.
- `requirements.txt` (numpy, scipy, scikit-learn).
- `README.md`: how to add recordings (the page's recorder produces compatible
  CSVs) and retrain.

## Testing

- **Parity**: Dart feature extractor + detector on a fixture reproduce the
  Python features and probabilities (|Δ| < 1e-6) and the same bite indices.
- **Replay**: the full engine on two fixtures (a typical eater and the slow
  eater) counts 20 ± 2 bites, starts a meal, reports every normal meal as
  *Steady*.
- **Unit**: meal tracker transitions and discards, handedness voting and
  override, steadiness on a synthetic 5 Hz 20 °/s sine (flagged) vs noise
  (not), coach rules, profile JSON round-trip and old-data tolerance.
- **Widget**: the page renders waiting, eating and finished states without
  overflow at 360 px width, light and dark.
- Existing BLE and analyzer checks stay green.

## App-wide wiring (2026-09-15)

- `AiLabService.detectedBiteCount` is a monotonic total of bites that belong to
  a meal. A lone lift that never becomes a meal is not counted, because the AI
  Lab page discards it too.
- `decideBiteTick` (`session_integrity.dart`) decides what each 1 s tick does
  with that total — wait for data, baseline, re-baseline after an app restart,
  ignore, or count a delta. It is pure and unit-tested; the service calls it.
- The tremor index every screen shows is `aiLabTremorResult`: the share of the
  meal that carried a rhythmic shake, x3, on the 0–3 scale the UI and database
  already use. While a meal runs it uses the meal's own steadiness — the number
  the AI Lab page shows — so two screens cannot disagree.
- The app's meal session ends when the AI Lab meal ends; the inactivity
  watchdog (now 3 min, matching the meal tracker) is only a backstop.

## Out of scope

Changing the firmware; neural models; any diagnosis wording; counting bites
while the IMU stream is off.

## Known limits

- One recording per person; no "not eating" recordings (carrying, stirring,
  washing), so the false meal-start rate is unmeasured.
- No real tremor recordings; steadiness thresholds come from normal eaters.
- No left-handed recordings.
- The recorder in "Model & data" exists to close these gaps; retraining is a
  script run plus replacing one JSON asset.
