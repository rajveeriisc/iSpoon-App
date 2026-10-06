-- Align the backend with the Flutter contract: meal tremor_index is 0..3.
-- Older backend code multiplied values <= 1 by 100 but left values > 1
-- unchanged. Values above 3 are therefore unambiguously legacy-scaled and
-- can be repaired; 0..3 values are preserved because their origin is
-- ambiguous and they are already valid app values.

ALTER TABLE eating_sessions
    DROP CONSTRAINT IF EXISTS eating_sessions_tremor_index_check;

ALTER TABLE eating_sessions
    ALTER COLUMN tremor_index TYPE NUMERIC(6,3)
    USING (
        CASE
            WHEN tremor_index > 3 THEN tremor_index::NUMERIC / 100
            ELSE tremor_index::NUMERIC
        END
    );

ALTER TABLE eating_sessions
    ADD CONSTRAINT eating_sessions_tremor_index_check
    CHECK (tremor_index >= 0 AND tremor_index <= 3);

ALTER TABLE daily_summaries
    ALTER COLUMN avg_tremor_index TYPE NUMERIC(6,3)
    USING (
        CASE
            WHEN avg_tremor_index > 3 THEN avg_tremor_index::NUMERIC / 100
            ELSE avg_tremor_index::NUMERIC
        END
    );

-- 012 used a SMALLINT cast because the old destination column was SMALLINT.
-- Recreate only this function so future rollups retain the 0..3 decimals.
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
        avg_food_temp_c           = EXCLUDED.avg_food_temp_c,
        updated_at                = NOW();

    IF NOT FOUND THEN
        DELETE FROM daily_summaries
        WHERE user_id = p_user_id AND date = p_date;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Rebuild cached values using the repaired scale.
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
