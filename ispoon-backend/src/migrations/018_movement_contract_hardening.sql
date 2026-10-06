-- Make the stored hand-movement contract self-consistent and expose how many
-- readings actually contained a repeated rhythmic pattern.

-- Older clients sometimes sent a frequency without a movement index. There is
-- no usable measurement to attach that frequency to, so treat it as missing.
UPDATE bites
SET tremor_frequency = NULL
WHERE tremor_magnitude IS NULL;

ALTER TABLE bites
    DROP CONSTRAINT IF EXISTS bites_tremor_magnitude_check,
    DROP CONSTRAINT IF EXISTS bites_tremor_frequency_check,
    DROP CONSTRAINT IF EXISTS bites_tremor_quality_pair_check,
    DROP CONSTRAINT IF EXISTS bites_tremor_measurement_consistency_check;

ALTER TABLE bites
    ADD CONSTRAINT bites_tremor_magnitude_check
        CHECK (tremor_magnitude IS NULL OR
               (tremor_magnitude >= 0 AND tremor_magnitude <= 3)),
    ADD CONSTRAINT bites_tremor_frequency_check
        CHECK (tremor_frequency IS NULL OR
               (tremor_frequency > 0 AND tremor_frequency <= 20)),
    ADD CONSTRAINT bites_tremor_quality_pair_check
        CHECK ((tremor_confidence IS NULL) = (tremor_window_ms IS NULL)),
    ADD CONSTRAINT bites_tremor_measurement_consistency_check
        CHECK (tremor_magnitude IS NOT NULL OR
               (tremor_frequency IS NULL AND
                tremor_confidence IS NULL AND
                tremor_window_ms IS NULL));

ALTER TABLE daily_summaries
    ADD COLUMN IF NOT EXISTS tremor_rhythmic_count INTEGER NOT NULL DEFAULT 0;

ALTER TABLE daily_summaries
    DROP CONSTRAINT IF EXISTS daily_summaries_tremor_rhythmic_count_check;

ALTER TABLE daily_summaries
    ADD CONSTRAINT daily_summaries_tremor_rhythmic_count_check
        CHECK (tremor_rhythmic_count >= 0);

CREATE OR REPLACE FUNCTION rebuild_daily_summary(p_user_id BIGINT, p_date DATE)
RETURNS VOID AS $$
BEGIN
    IF p_user_id IS NULL OR p_date IS NULL THEN
        RETURN;
    END IF;

    PERFORM pg_advisory_xact_lock(
        (p_user_id % 2147483647)::INTEGER,
        (p_date - DATE '2000-01-01')::INTEGER
    );

    INSERT INTO daily_summaries (
        user_id, date,
        total_bites,
        total_eating_min, total_eating_duration_min,
        breakfast_bites, lunch_bites, dinner_bites, snack_bites,
        avg_tremor_index,
        avg_tremor_magnitude, avg_tremor_frequency,
        tremor_low_count, tremor_moderate_count, tremor_high_count,
        tremor_rhythmic_count,
        avg_food_temp_c
    )
    WITH meal_agg AS (
        SELECT
            es.user_id,
            es.local_date AS date,
            COALESCE(SUM(es.total_bites), 0) AS total_bites,
            COALESCE(SUM(es.duration_minutes), 0) AS total_eating_min,
            COALESCE(SUM(es.duration_minutes), 0) AS total_eating_duration_min,
            COALESCE(SUM(es.total_bites) FILTER (WHERE es.meal_type = 'Breakfast'), 0) AS breakfast_bites,
            COALESCE(SUM(es.total_bites) FILTER (WHERE es.meal_type = 'Lunch'), 0) AS lunch_bites,
            COALESCE(SUM(es.total_bites) FILTER (WHERE es.meal_type = 'Dinner'), 0) AS dinner_bites,
            COALESCE(SUM(es.total_bites) FILTER (WHERE es.meal_type = 'Snack'), 0) AS snack_bites,
            COALESCE(AVG(es.tremor_index), 0)::NUMERIC(6,3) AS avg_tremor_index
        FROM eating_sessions es
        WHERE es.user_id = p_user_id AND es.local_date = p_date
        GROUP BY es.user_id, es.local_date
    ),
    bite_agg AS (
        SELECT
            COALESCE(AVG(b.tremor_magnitude), 0) AS avg_tremor_magnitude,
            COALESCE(AVG(b.tremor_frequency), 0) AS avg_tremor_frequency,
            COUNT(*) FILTER (WHERE b.tremor_magnitude < 0.6) AS tremor_low_count,
            COUNT(*) FILTER (
                WHERE b.tremor_magnitude >= 0.6 AND b.tremor_magnitude < 1.4
            ) AS tremor_moderate_count,
            COUNT(*) FILTER (WHERE b.tremor_magnitude >= 1.4) AS tremor_high_count,
            COUNT(b.tremor_frequency) AS tremor_rhythmic_count,
            COALESCE(AVG(b.food_temp_c), 0) AS avg_food_temp_c
        FROM eating_sessions es
        JOIN bites b ON b.meal_uuid = es.uuid AND b.is_valid = TRUE
        WHERE es.user_id = p_user_id AND es.local_date = p_date
    )
    SELECT
        ma.user_id, ma.date,
        ma.total_bites,
        ma.total_eating_min, ma.total_eating_duration_min,
        ma.breakfast_bites, ma.lunch_bites, ma.dinner_bites, ma.snack_bites,
        ma.avg_tremor_index,
        ba.avg_tremor_magnitude, ba.avg_tremor_frequency,
        ba.tremor_low_count, ba.tremor_moderate_count, ba.tremor_high_count,
        ba.tremor_rhythmic_count,
        ba.avg_food_temp_c
    FROM meal_agg ma
    CROSS JOIN bite_agg ba
    ON CONFLICT (user_id, date) DO UPDATE SET
        total_bites               = EXCLUDED.total_bites,
        total_eating_min          = EXCLUDED.total_eating_min,
        total_eating_duration_min = EXCLUDED.total_eating_duration_min,
        breakfast_bites           = EXCLUDED.breakfast_bites,
        lunch_bites               = EXCLUDED.lunch_bites,
        dinner_bites              = EXCLUDED.dinner_bites,
        snack_bites               = EXCLUDED.snack_bites,
        avg_tremor_index          = EXCLUDED.avg_tremor_index,
        avg_tremor_magnitude      = EXCLUDED.avg_tremor_magnitude,
        avg_tremor_frequency      = EXCLUDED.avg_tremor_frequency,
        tremor_low_count          = EXCLUDED.tremor_low_count,
        tremor_moderate_count     = EXCLUDED.tremor_moderate_count,
        tremor_high_count         = EXCLUDED.tremor_high_count,
        tremor_rhythmic_count     = EXCLUDED.tremor_rhythmic_count,
        avg_food_temp_c           = EXCLUDED.avg_food_temp_c,
        updated_at                = NOW();

    IF NOT FOUND THEN
        DELETE FROM daily_summaries
        WHERE user_id = p_user_id AND date = p_date;
    END IF;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    summary_key RECORD;
BEGIN
    FOR summary_key IN
        SELECT DISTINCT user_id, local_date AS date
        FROM eating_sessions
        WHERE local_date IS NOT NULL
    LOOP
        PERFORM rebuild_daily_summary(summary_key.user_id, summary_key.date);
    END LOOP;
END;
$$;

COMMENT ON COLUMN daily_summaries.tremor_rhythmic_count IS
    'Clean bite readings where a repeated 4-12 Hz rhythm was present.';
