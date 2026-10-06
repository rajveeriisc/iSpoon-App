-- ============================================================================
-- 010_meal_local_date_rollups.sql
-- Use the client meal local_date for daily rollups instead of UTC date casts.
-- ============================================================================

ALTER TABLE eating_sessions
    ADD COLUMN IF NOT EXISTS local_date DATE;

UPDATE eating_sessions
SET local_date = DATE(started_at)
WHERE local_date IS NULL;

CREATE INDEX IF NOT EXISTS idx_eating_sessions_user_local_date
    ON eating_sessions(user_id, local_date DESC);

CREATE OR REPLACE FUNCTION update_daily_summary()
RETURNS TRIGGER AS $$
DECLARE
    v_date DATE;
    v_user BIGINT;
BEGIN
    v_date := COALESCE(NEW.local_date, DATE(NEW.started_at));
    v_user := NEW.user_id;

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
            COALESCE(es.local_date, DATE(es.started_at))                               AS date,
            COALESCE(SUM(es.total_bites), 0)                                          AS total_bites,
            COALESCE(SUM(es.duration_minutes), 0)                                     AS total_eating_min,
            COALESCE(SUM(es.duration_minutes), 0)                                     AS total_eating_duration_min,
            COALESCE(SUM(CASE WHEN es.meal_type = 'Breakfast' THEN es.total_bites ELSE 0 END), 0) AS breakfast_bites,
            COALESCE(SUM(CASE WHEN es.meal_type = 'Lunch'     THEN es.total_bites ELSE 0 END), 0) AS lunch_bites,
            COALESCE(SUM(CASE WHEN es.meal_type = 'Dinner'    THEN es.total_bites ELSE 0 END), 0) AS dinner_bites,
            COALESCE(SUM(CASE WHEN es.meal_type = 'Snack'     THEN es.total_bites ELSE 0 END), 0) AS snack_bites,
            COALESCE(AVG(es.tremor_index)::SMALLINT, 0)                              AS avg_tremor_index
        FROM eating_sessions es
        WHERE es.user_id = v_user
          AND COALESCE(es.local_date, DATE(es.started_at)) = v_date
        GROUP BY es.user_id, COALESCE(es.local_date, DATE(es.started_at))
    ),
    bite_agg AS (
        SELECT
            es.user_id,
            COALESCE(es.local_date, DATE(es.started_at))                               AS date,
            COALESCE(AVG(b.tremor_magnitude), 0)                                      AS avg_tremor_magnitude,
            COALESCE(AVG(b.tremor_frequency), 0)                                      AS avg_tremor_frequency,
            COUNT(CASE WHEN b.tremor_magnitude < 0.6                              THEN 1 END) AS tremor_low_count,
            COUNT(CASE WHEN b.tremor_magnitude >= 0.6 AND b.tremor_magnitude < 1.4 THEN 1 END) AS tremor_moderate_count,
            COUNT(CASE WHEN b.tremor_magnitude >= 1.4                             THEN 1 END) AS tremor_high_count,
            COALESCE(AVG(b.food_temp_c), 0)                                           AS avg_food_temp_c
        FROM eating_sessions es
        LEFT JOIN bites b ON b.meal_uuid = es.uuid AND b.is_valid = TRUE
        WHERE es.user_id = v_user
          AND COALESCE(es.local_date, DATE(es.started_at)) = v_date
        GROUP BY es.user_id, COALESCE(es.local_date, DATE(es.started_at))
    )
    SELECT
        ma.user_id,
        ma.date,
        ma.total_bites,
        ma.total_eating_min,
        ma.total_eating_duration_min,
        ma.breakfast_bites,
        ma.lunch_bites,
        ma.dinner_bites,
        ma.snack_bites,
        ma.avg_tremor_index,
        COALESCE(ba.avg_tremor_magnitude, 0),
        COALESCE(ba.avg_tremor_frequency, 0),
        COALESCE(ba.tremor_low_count, 0),
        COALESCE(ba.tremor_moderate_count, 0),
        COALESCE(ba.tremor_high_count, 0),
        COALESCE(ba.avg_food_temp_c, 0)
    FROM meal_agg ma
    LEFT JOIN bite_agg ba ON ba.user_id = ma.user_id AND ba.date = ma.date
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

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
