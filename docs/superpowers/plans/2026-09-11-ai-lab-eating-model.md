# AI Lab Eating Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A trained on-phone model that detects meal start, counts bites within ~2 s, measures hand steadiness, learns each person's eating pattern and coaches them — shown only on a redesigned AI Lab page.

**Architecture:** A Python training script produces one JSON asset (weights, thresholds, steadiness reference) plus parity fixtures. A pure-Dart engine (window → features → logistic → causal peak picker, handedness voter, steadiness FFT, meal state machine) reproduces the script bit-for-bit and is driven by an `AiLabService` singleton subscribed to `SpoonRuntime.sensorBatchStream`. The page renders an immutable `AiLabViewData`.

**Tech Stack:** Python 3.11 + numpy/scipy/scikit-learn (training only); Flutter/Dart, `fftea` (FFT), `fl_chart`, `shared_preferences`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-09-11-ai-lab-eating-model-design.md` (algorithm definitions live there; this plan does not repeat them).

**Repo rule for this project:** do not commit unless the user asks. Every "Commit" step below is replaced by "leave uncommitted; list changed files in the final report".

---

## File map

| Path | Kind | Responsibility |
|---|---|---|
| `tools/ai_lab/train_bite_model.py` | create | Training, leave-one-person-out report, asset + fixture export |
| `tools/ai_lab/requirements.txt`, `tools/ai_lab/README.md` | create | Reproducible environment, retrain how-to |
| `smartspoon/assets/models/ai_lab_model.json` | generated | Weights and references loaded by the app |
| `smartspoon/test/fixtures/ai_lab/*.csv.gz`, `parity_golden.json` | generated | Two trimmed recordings + expected outputs |
| `smartspoon/pubspec.yaml` | modify | Add `assets/models/` |
| `lib/features/ai_lab/domain/engine/ai_lab_model.dart` | create | JSON → weights, `predict()` |
| `lib/features/ai_lab/domain/engine/imu_window.dart` | create | Raw ring buffer, gravity EMA, gap reset |
| `lib/features/ai_lab/domain/engine/bite_features.dart` | create | 13 features + hand-vote yaw at decision *t* |
| `lib/features/ai_lab/domain/engine/bite_detector.dart` | create | Probability history + causal peak picker |
| `lib/features/ai_lab/domain/engine/handedness.dart` | create | Hand modes, preference, voter |
| `lib/features/ai_lab/domain/engine/steadiness_analyzer.dart` | create | 256-pt Hann FFT every 100 samples |
| `lib/features/ai_lab/domain/engine/meal_tracker.dart` | create | idle/eating/paused/finished, pending bite, discard < 3 |
| `lib/features/ai_lab/domain/engine/eating_engine.dart` | create | Composition; `feed`, `tick`, `finish`, `snapshot` |
| `lib/features/ai_lab/domain/insights/eating_insights.dart` | create | `MealMetrics`, `coachTips()` |
| `lib/features/ai_lab/domain/services/ai_lab_profile_store.dart` | create | Per-spoon profile, last 20 meals, prefs key `ai_lab_profile_v1` |
| `lib/features/ai_lab/domain/services/training_recorder.dart` | create | Labelled CSV capture (existing schema) |
| `lib/features/ai_lab/domain/services/ai_lab_service.dart` | create | Stream → engine, spoon switching, tick timer, persistence, `AiLabViewData` |
| `lib/features/ai_lab/presentation/screens/ai_lab_page.dart` | rewrite | Page shell: service → `AiLabView` |
| `lib/features/ai_lab/presentation/widgets/*.dart` | create | One card per file |
| `lib/features/ai_lab/domain/services/ai_tremor_service.dart` | delete | Superseded (backup kept in scratchpad) |
| `lib/main.dart` | modify | `AiLabService().start()` next to `ImuBiteDetectorService` |
| `smartspoon/test/ai_lab/*_test.dart` | create | Parity, replay, unit, widget tests |

`personalized_eating_model.dart` is untouched (Home and `unified_data_service` own it; `unified_data_service` already calls its `load()`).

---

### Task 1: Training apparatus

**Files:** create `tools/ai_lab/train_bite_model.py`, `tools/ai_lab/requirements.txt`, `tools/ai_lab/README.md`

- [ ] Implement the script exactly per the spec's "bite model", "handedness" and "hand steadiness" sections: gap segmentation (> 1000 ms), gravity EMA, 13 features, hand transforms (right / left = negate rbx, rfz / neutral = abs), standardised logistic regression (C 0.5, balanced), causal peak picker with the hand policy, 256-pt Hann steadiness windows every 100 samples.
- [ ] Leave-one-person-out report for right-only, neutral-only and the shipped auto policy; steadiness threshold = smallest of P95 / P97.5 / P99 of normal-window concentration that keeps every person ≥ 90 % steady; synthetic 5 Hz injection sensitivity at that threshold.
- [ ] Export `ai_lab_model.json`, two trimmed gz fixtures (typical eater `T11-18-29`, slow eater `T11-36-10`), `parity_golden.json` computed from the trimmed fixture values.
- [ ] Run: `scratchpad/mlenv/bin/python tools/ai_lab/train_bite_model.py --data ~/Desktop/bites`
  Expected: auto-policy F1 ≥ 0.95, every person steady ≥ 90 %, files written.

### Task 2: Asset registration

**Files:** modify `smartspoon/pubspec.yaml` (`flutter: assets:` add `- assets/models/`)

- [ ] Add the entry, run `flutter pub get`. Expected: exit 0.

### Task 3: Model + window + features + detector (parity)

**Files:** create `ai_lab_model.dart`, `imu_window.dart`, `bite_features.dart`, `bite_detector.dart`; test `test/ai_lab/bite_model_parity_test.dart`

- [ ] Write the parity test first: load asset JSON and fixture A, stream every row through `ImuWindow` + `BiteFeatures`, compare each golden decision's 13 features and both probabilities (|Δ| < 1e-6), then run `BiteDetector` with the auto hand policy and expect identical bite row indices and decided hand.
- [ ] Run `flutter test test/ai_lab/bite_model_parity_test.dart` → FAIL (files missing).
- [ ] Implement the four files (row/sample indices local to the current segment; the window reports a reset on gaps > 1000 ms; features computed on raw samples then hand-transformed).
- [ ] Re-run → PASS.

### Task 4: Handedness

**Files:** create `handedness.dart`; test `test/ai_lab/handedness_test.dart`

- [ ] Tests: 3 positive votes → right; mixed votes then 3 negative → left; preference right/left overrides auto; `activeMode` neutral while undecided.
- [ ] Implement; run → PASS.

### Task 5: Steadiness analyzer

**Files:** create `steadiness_analyzer.dart`; test `test/ai_lab/steadiness_analyzer_test.dart`

- [ ] Tests: golden window concentrations from fixture A match (|Δ| < 1e-9 relative); synthetic 5 Hz 20 °/s sine + noise → rhythmic with 5 ± 0.4 Hz; white noise → not rhythmic; windows emitted only when local n ≥ 255 and n % 100 == 0.
- [ ] Implement with `fftea` `FFT(256).realFft`; run → PASS.

### Task 6: Meal tracker

**Files:** create `meal_tracker.dart`; test `test/ai_lab/meal_tracker_test.dart`

- [ ] Tests: lone bite dropped after 30 s; two bites within 30 s start a meal with both counted; 60 s silence → paused, next bite → eating; 3 min → finished record; < 3 bites → discarded (idle); manual finish; steadiness windows counted only while eating/paused.
- [ ] Implement; run → PASS.

### Task 7: Engine + replay

**Files:** create `eating_engine.dart`; test `test/ai_lab/eating_engine_replay_test.dart`

- [ ] Test: both fixtures through the engine (auto hand) → 20 ± 2 bites, a meal started, `tick(last + 3 min)` finishes it with steady % ≥ 90 and hand decided right. (Regression test: the shipped model saw these people; held-out numbers come from Task 1's report.)
- [ ] Implement; run → PASS.

### Task 8: Insights + coach

**Files:** create `eating_insights.dart`; test `test/ai_lab/eating_insights_test.dart`

- [ ] Tests per spec rule table: fast last-5 gap → nudge first; ≥ 10 s → positive; speed-up rule; vs-usual only with ≥ 3 meals; short-meal rule only in summary; steadiness rules; max 3 tips.
- [ ] Implement; run → PASS.

### Task 9: Profile store

**Files:** create `ai_lab_profile_store.dart`; test `test/ai_lab/ai_lab_profile_store_test.dart`

- [ ] Tests (mock SharedPreferences): record meals → EWMA and recent list capped at 20; JSON round-trip; missing fields tolerated; hand preference and detected hand persist.
- [ ] Implement; run → PASS.

### Task 10: Recorder + service + app start

**Files:** create `training_recorder.dart`, `ai_lab_service.dart`; modify `lib/main.dart`; delete `ai_tremor_service.dart`

- [ ] Recorder keeps today's CSV schema (`user_bite_mark` from taps, nearest sample within 2 s).
- [ ] Service: loads asset + profiles, filters the active spoon (switch after the current one is silent 2 s → finish meal, reset engine, apply that spoon's hand setting), 1 s tick, saves finished meals, throttles `notifyListeners` to state changes and ticks, exposes a separate `ValueListenable` for the raw chart.
- [ ] Run `flutter analyze lib/features/ai_lab lib/main.dart` → no errors/warnings.

### Task 11: Page

**Files:** rewrite `ai_lab_page.dart`; create `presentation/widgets/` cards; test `test/ai_lab/ai_lab_page_test.dart`

- [ ] Widget test first: `AiLabView` with waiting / eating / finished `AiLabViewData` at 360 × 800, light and dark → no overflow, key texts present ("Eating now", bite count, "Hand steadiness", "Coach").
- [ ] Implement the 8 sections in the spec's order; run → PASS.

### Task 12: Verification

- [ ] `flutter test test/ai_lab` → all pass; `flutter test` for the existing BLE suites → still 77 pass.
- [ ] `flutter analyze` → no new errors or warnings.
- [ ] Build the release APK and install on the connected phone (adb serial 10BF591J6P001EZ) if it is attached; open AI Lab and check it renders.
