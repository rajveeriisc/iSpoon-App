# AI Lab model training

Trains the bite model and steadiness reference used by the app's AI Lab page
(`smartspoon/lib/features/ai_lab/domain/engine/`). Design:
`docs/superpowers/specs/2026-09-11-ai-lab-eating-model-design.md`.

## Retrain

```bash
python3 -m venv .venv && .venv/bin/pip install -r tools/ai_lab/requirements.txt
.venv/bin/python tools/ai_lab/train_bite_model.py --data ~/Desktop/bites
cd smartspoon && flutter test test/ai_lab
```

The script prints a leave-one-person-out report (each person is scored by a
model that never saw them), then writes:

- `smartspoon/assets/models/ai_lab_model.json` — shipped with the app
- `smartspoon/test/fixtures/ai_lab/` — two trimmed recordings and
  `parity_golden.json`, which the Dart tests must reproduce exactly

## Adding recordings

Record in the app: AI Lab → Model & data → Record a labelled meal. Tap
**Bite** each time the spoon reaches the mouth, then Save. Copy the
`spoon_session_*.csv` files into the data folder — one file per person
works best, because the report holds out one file at a time.

Only these columns are read: `timestamp_ms`, `accelX..Z` (g), `gyroX..Z`
(deg/s), `user_bite_mark`.

Most wanted next: left-handed eaters, people with tremor, and recordings of
the spoon being carried, stirred or washed (no bites) so the false meal-start
rate can be measured.
