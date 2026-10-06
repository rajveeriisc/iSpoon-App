-- Distinguish a clean low movement reading from an unavailable/contaminated
-- sensor window. Existing rows remain NULL because their quality is unknown.

ALTER TABLE bites
    ADD COLUMN IF NOT EXISTS tremor_confidence NUMERIC(4,3),
    ADD COLUMN IF NOT EXISTS tremor_window_ms INTEGER;

ALTER TABLE bites
    DROP CONSTRAINT IF EXISTS bites_tremor_confidence_check,
    DROP CONSTRAINT IF EXISTS bites_tremor_window_ms_check;

ALTER TABLE bites
    ADD CONSTRAINT bites_tremor_confidence_check
        CHECK (tremor_confidence IS NULL OR
               (tremor_confidence >= 0 AND tremor_confidence <= 1)),
    ADD CONSTRAINT bites_tremor_window_ms_check
        CHECK (tremor_window_ms IS NULL OR
               (tremor_window_ms >= 3000 AND tremor_window_ms <= 30000));

COMMENT ON COLUMN bites.tremor_magnitude IS
    'Legacy column name: relative 0..3 rhythmic movement variation index, not physical acceleration amplitude.';
COMMENT ON COLUMN bites.tremor_confidence IS
    'Signal quality and cross-sensor agreement for the analysed window, 0..1.';
COMMENT ON COLUMN bites.tremor_window_ms IS
    'Duration of the clean IMU window used for this bite measurement.';
