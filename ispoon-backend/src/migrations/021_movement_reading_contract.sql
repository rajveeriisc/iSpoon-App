-- Separate the two movement readings the app produces, and give the meal-level
-- one somewhere to live.
--
-- Migration 017 sized bites.tremor_window_ms for a bounded sliding analysis
-- window (3-30 s), which is what the old on-device detector produced. The AI
-- Lab model replaced it with a reading aggregated over steadiness windows, and
-- the app wrote that aggregate into the same column. Past the 30th second of a
-- meal every value broke the CHECK, which aborted the whole bite+meal
-- transaction rather than degrading: the client rolled its anchor back and
-- retried the same doomed write on every tick, so no bite after 0:30 was ever
-- stored and no bite ever carried tremor_confidence (the paired-NULL check
-- ties the two together). That is why bites.tremor_confidence is NULL for
-- every row in this database.
--
-- The fix is to stop conflating them:
--   * bites.*            — how steady the hand was AROUND THAT BITE, from a
--                          rolling window the client caps at 60 s.
--   * eating_sessions.*  — the whole-meal figures the AI Lab page shows. The
--                          app has stored these locally since its schema v16;
--                          they had no column here, so they were dropped on
--                          sync and lost on restore.
--
-- Additive and non-destructive: new nullable columns, and one CHECK widened to
-- a bound that admits the readings the client actually produces. No existing
-- row changes, and every row that satisfied the old bound satisfies the new.

-- ── Per-bite reading ────────────────────────────────────────────────────────

ALTER TABLE bites
    ADD COLUMN IF NOT EXISTS steady_pct NUMERIC(5,2);

ALTER TABLE bites
    DROP CONSTRAINT IF EXISTS bites_tremor_window_ms_check,
    DROP CONSTRAINT IF EXISTS bites_steady_pct_check;

ALTER TABLE bites
    -- 60 s is the client's rolling steadiness buffer (_recentWindowLimit), so
    -- it is the longest span a per-bite reading can honestly claim. Keep this
    -- in step with AiLabService._recentWindowLimit and the local SQLite CHECK.
    ADD CONSTRAINT bites_tremor_window_ms_check
        CHECK (tremor_window_ms IS NULL OR
               (tremor_window_ms >= 3000 AND tremor_window_ms <= 60000)),
    ADD CONSTRAINT bites_steady_pct_check
        CHECK (steady_pct IS NULL OR (steady_pct >= 0 AND steady_pct <= 100));

-- ── Whole-meal figures ──────────────────────────────────────────────────────

ALTER TABLE eating_sessions
    ADD COLUMN IF NOT EXISTS steady_pct NUMERIC(5,2),
    ADD COLUMN IF NOT EXISTS rhythm_hz REAL,
    ADD COLUMN IF NOT EXISTS measured_seconds INTEGER,
    ADD COLUMN IF NOT EXISTS movement_source VARCHAR(32);

ALTER TABLE eating_sessions
    DROP CONSTRAINT IF EXISTS eating_sessions_steady_pct_check,
    DROP CONSTRAINT IF EXISTS eating_sessions_rhythm_hz_check,
    DROP CONSTRAINT IF EXISTS eating_sessions_measured_seconds_check;

ALTER TABLE eating_sessions
    ADD CONSTRAINT eating_sessions_steady_pct_check
        CHECK (steady_pct IS NULL OR (steady_pct >= 0 AND steady_pct <= 100)),
    -- Same band as bites.tremor_frequency: the analyser only reports a line
    -- inside the model's 4-12 Hz band, and 20 leaves room for a retrain.
    ADD CONSTRAINT eating_sessions_rhythm_hz_check
        CHECK (rhythm_hz IS NULL OR (rhythm_hz > 0 AND rhythm_hz <= 20)),
    -- A meal is measured for as long as it lasts; 24 h only rejects nonsense.
    ADD CONSTRAINT eating_sessions_measured_seconds_check
        CHECK (measured_seconds IS NULL OR
               (measured_seconds >= 0 AND measured_seconds <= 86400));

COMMENT ON COLUMN bites.tremor_window_ms IS
    'Span of the rolling IMU reading behind this bite, 3000-60000 ms. Not the meal total — see eating_sessions.measured_seconds.';
COMMENT ON COLUMN bites.steady_pct IS
    'Share of the windows around this bite with no rhythmic shaking, 0..100.';
COMMENT ON COLUMN eating_sessions.steady_pct IS
    'Whole-meal share without rhythmic shaking, 0..100 — the figure the AI Lab page shows.';
COMMENT ON COLUMN eating_sessions.rhythm_hz IS
    'Mean frequency of the meal''s rhythmic windows, or NULL when none were rhythmic.';
COMMENT ON COLUMN eating_sessions.measured_seconds IS
    'Seconds of the meal actually analysed. "94% steady" from 8 s and from 20 min are not the same claim.';
COMMENT ON COLUMN eating_sessions.movement_source IS
    'Which analyser produced the movement figures, e.g. ai_lab. NULL for rows recorded before the model.';
