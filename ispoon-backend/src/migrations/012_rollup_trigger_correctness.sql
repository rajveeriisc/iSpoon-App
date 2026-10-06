-- ============================================================================
-- 012_rollup_trigger_correctness.sql
-- Correct stale/multiplied daily summaries and replace per-bite row rebuilds.
-- 009 and 010 were already deployed; this forward-only migration repairs them.
-- ============================================================================

-- A missing client local_date cannot be reconstructed perfectly. UTC is the
-- only deterministic fallback; unlike DATE(timestamptz), it does not vary with
-- the database session timezone.
UPDATE eating_sessions
SET local_date = (started_at AT TIME ZONE 'UTC')::date
WHERE local_date IS NULL;

CREATE OR REPLACE FUNCTION set_meal_local_date_fallback()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.local_date IS NULL THEN
        NEW.local_date := (NEW.started_at AT TIME ZONE 'UTC')::date;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_set_meal_local_date ON eating_sessions;
CREATE TRIGGER trigger_set_meal_local_date
    BEFORE INSERT OR UPDATE OF local_date, started_at ON eating_sessions
    FOR EACH ROW EXECUTE FUNCTION set_meal_local_date_fallback();

ALTER TABLE eating_sessions
    ALTER COLUMN local_date SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_eating_sessions_user_local_date
    ON eating_sessions(user_id, local_date DESC);

-- Serialize rebuilds for the same user/day. Without this lock, concurrent meal
-- or bite transactions can each aggregate a partial snapshot and the last
-- writer can leave a stale cache row.
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
            COALESCE(AVG(es.tremor_index)::SMALLINT, 0) AS avg_tremor_index
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

    -- An INSERT ... SELECT with no source row leaves FOUND false. This removes
    -- the stale summary after the last meal on a day is deleted or moved.
    IF NOT FOUND THEN
        DELETE FROM daily_summaries
        WHERE user_id = p_user_id AND date = p_date;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trigger_meal_rebuild_daily_summary()
RETURNS TRIGGER AS $$
DECLARE
    v_key RECORD;
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM rebuild_daily_summary(NEW.user_id, NEW.local_date);
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        PERFORM rebuild_daily_summary(OLD.user_id, OLD.local_date);
        RETURN OLD;
    END IF;

    -- Sorting ensures two concurrent date moves acquire advisory locks in the
    -- same order and cannot deadlock each other.
    FOR v_key IN
        SELECT DISTINCT key.user_id, key.local_date
        FROM (VALUES
            (OLD.user_id, OLD.local_date),
            (NEW.user_id, NEW.local_date)
        ) AS key(user_id, local_date)
        ORDER BY key.user_id, key.local_date
    LOOP
        PERFORM rebuild_daily_summary(v_key.user_id, v_key.local_date);
    END LOOP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trigger_inserted_bites_rebuild_daily_summary()
RETURNS TRIGGER AS $$
DECLARE
    v_key RECORD;
BEGIN
    FOR v_key IN
        SELECT DISTINCT es.user_id, es.local_date
        FROM inserted_bites changed
        JOIN eating_sessions es ON es.uuid = changed.meal_uuid
        ORDER BY es.user_id, es.local_date
    LOOP
        PERFORM rebuild_daily_summary(v_key.user_id, v_key.local_date);
    END LOOP;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trigger_deleted_bites_rebuild_daily_summary()
RETURNS TRIGGER AS $$
DECLARE
    v_key RECORD;
BEGIN
    FOR v_key IN
        SELECT DISTINCT es.user_id, es.local_date
        FROM deleted_bites changed
        JOIN eating_sessions es ON es.uuid = changed.meal_uuid
        ORDER BY es.user_id, es.local_date
    LOOP
        PERFORM rebuild_daily_summary(v_key.user_id, v_key.local_date);
    END LOOP;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trigger_updated_bites_rebuild_daily_summary()
RETURNS TRIGGER AS $$
DECLARE
    v_key RECORD;
BEGIN
    FOR v_key IN
        WITH changed_meals AS (
            SELECT meal_uuid FROM old_bites
            UNION
            SELECT meal_uuid FROM new_bites
        )
        SELECT DISTINCT es.user_id, es.local_date
        FROM changed_meals changed
        JOIN eating_sessions es ON es.uuid = changed.meal_uuid
        ORDER BY es.user_id, es.local_date
    LOOP
        PERFORM rebuild_daily_summary(v_key.user_id, v_key.local_date);
    END LOOP;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Remove the legacy per-row bite trigger and its recursive no-op meal update.
DROP TRIGGER IF EXISTS trigger_update_daily_summary ON eating_sessions;
DROP TRIGGER IF EXISTS trigger_bites_rebuild_daily ON bites;

DROP TRIGGER IF EXISTS trigger_meals_rebuild_daily ON eating_sessions;
CREATE TRIGGER trigger_meals_rebuild_daily
    AFTER INSERT OR UPDATE OR DELETE ON eating_sessions
    FOR EACH ROW EXECUTE FUNCTION trigger_meal_rebuild_daily_summary();

DROP TRIGGER IF EXISTS trigger_bites_rebuild_daily_insert ON bites;
CREATE TRIGGER trigger_bites_rebuild_daily_insert
    AFTER INSERT ON bites
    REFERENCING NEW TABLE AS inserted_bites
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_inserted_bites_rebuild_daily_summary();

DROP TRIGGER IF EXISTS trigger_bites_rebuild_daily_update ON bites;
CREATE TRIGGER trigger_bites_rebuild_daily_update
    AFTER UPDATE ON bites
    REFERENCING OLD TABLE AS old_bites NEW TABLE AS new_bites
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_updated_bites_rebuild_daily_summary();

DROP TRIGGER IF EXISTS trigger_bites_rebuild_daily_delete ON bites;
CREATE TRIGGER trigger_bites_rebuild_daily_delete
    AFTER DELETE ON bites
    REFERENCING OLD TABLE AS deleted_bites
    FOR EACH STATEMENT EXECUTE FUNCTION trigger_deleted_bites_rebuild_daily_summary();

-- Repair all already-materialized summaries once using the corrected logic.
DELETE FROM daily_summaries summary
WHERE NOT EXISTS (
    SELECT 1
    FROM eating_sessions es
    WHERE es.user_id = summary.user_id AND es.local_date = summary.date
);

DO $$
DECLARE
    v_key RECORD;
BEGIN
    FOR v_key IN
        SELECT DISTINCT user_id, local_date
        FROM eating_sessions
        ORDER BY user_id, local_date
    LOOP
        PERFORM rebuild_daily_summary(v_key.user_id, v_key.local_date);
    END LOOP;
END $$;

-- Obsolete functions are dropped only after all legacy triggers are detached.
DROP FUNCTION IF EXISTS trigger_bites_update_daily_summary();
DROP FUNCTION IF EXISTS update_daily_summary();
