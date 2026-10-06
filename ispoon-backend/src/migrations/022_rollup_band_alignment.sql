-- Daily rollup bands disagreed with the app.
--
-- The Flutter contract derives the 0..3 movement index from the steadiness
-- percentage (lib/features/insights/domain/models.dart):
--
--     index = 3 * (100 - steadyPct) / 100
--     kSteadyFromPct = 90  ->  moderateThreshold = 0.30
--     kShakyBelowPct = 75  ->  highThreshold     = 0.75
--
-- and classifies with `<=` on the index side, because the percentage side is
-- inclusive and the index runs the other way:
--
--     low      magnitude <= 0.30
--     moderate magnitude <= 0.75
--     high     magnitude >  0.75
--
-- This function still used the pre-unification cuts 0.6 / 1.4. A bite the app
-- renders as "shaky" (index 0.9, about 70% steady) was counted as *moderate*
-- in daily_summaries until it reached 1.4, so the band counts contradicted the
-- dominant level the app computed from avg_tremor_magnitude on the very same
-- row. bites.tremor_magnitude is CHECK (0..3) as of 018, i.e. the same scale
-- as the app index, so the two are directly comparable.

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
            COALESCE(AVG(b.tremor_frequency) FILTER (
                WHERE b.tremor_confidence >= 0.5
                  AND b.tremor_window_ms >= 3000
            ), 0) AS avg_tremor_frequency,
            COUNT(*) FILTER (WHERE b.tremor_magnitude <= 0.30) AS tremor_low_count,
            COUNT(*) FILTER (
                WHERE b.tremor_magnitude > 0.30 AND b.tremor_magnitude <= 0.75
            ) AS tremor_moderate_count,
            COUNT(*) FILTER (WHERE b.tremor_magnitude > 0.75) AS tremor_high_count,
            COUNT(b.tremor_frequency) FILTER (
                WHERE b.tremor_confidence >= 0.5
                  AND b.tremor_window_ms >= 3000
            ) AS tremor_rhythmic_count,
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

-- Re-bucket every existing summary under the aligned cuts.
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
