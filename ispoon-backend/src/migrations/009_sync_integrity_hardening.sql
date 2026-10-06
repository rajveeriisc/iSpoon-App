-- ============================================================================
-- 009_sync_integrity_hardening.sql
-- Applies sync/data-integrity fixes to databases that already ran 003.
-- ============================================================================

-- Ensure bite upserts have the unique non-null key used by the API.
WITH max_sequences AS (
    SELECT meal_uuid, COALESCE(MAX(sequence_number), -1) AS max_sequence
    FROM bites
    GROUP BY meal_uuid
),
null_sequences AS (
    SELECT
        b.id,
        ms.max_sequence + ROW_NUMBER() OVER (
            PARTITION BY b.meal_uuid
            ORDER BY b.timestamp ASC, b.id ASC
        ) AS repaired_sequence
    FROM bites b
    JOIN max_sequences ms ON ms.meal_uuid = b.meal_uuid
    WHERE b.sequence_number IS NULL
)
UPDATE bites b
SET sequence_number = ns.repaired_sequence
FROM null_sequences ns
WHERE b.id = ns.id;

WITH duplicate_bites AS (
    SELECT
        id,
        ROW_NUMBER() OVER (
            PARTITION BY meal_uuid, sequence_number
            ORDER BY is_synced DESC, created_at DESC, id DESC
        ) AS duplicate_rank
    FROM bites
)
DELETE FROM bites b
USING duplicate_bites d
WHERE b.id = d.id
  AND d.duplicate_rank > 1;

ALTER TABLE bites
    ALTER COLUMN sequence_number SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'bites_sequence_number_nonnegative'
    ) THEN
        ALTER TABLE bites
            ADD CONSTRAINT bites_sequence_number_nonnegative
            CHECK (sequence_number >= 0);
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_bites_meal_sequence_unique
    ON bites(meal_uuid, sequence_number);

-- Rebuild daily summaries without multiplying meal rows by bite rows.
CREATE OR REPLACE FUNCTION update_daily_summary()
RETURNS TRIGGER AS $$
DECLARE
    v_date DATE;
    v_user BIGINT;
BEGIN
    v_date := DATE(NEW.started_at);
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
            DATE(es.started_at)                                                       AS date,
            COALESCE(SUM(es.total_bites), 0)                                          AS total_bites,
            COALESCE(SUM(es.duration_minutes), 0)                                     AS total_eating_min,
            COALESCE(SUM(es.duration_minutes), 0)                                     AS total_eating_duration_min,
            COALESCE(SUM(CASE WHEN es.meal_type = 'Breakfast' THEN es.total_bites ELSE 0 END), 0) AS breakfast_bites,
            COALESCE(SUM(CASE WHEN es.meal_type = 'Lunch'     THEN es.total_bites ELSE 0 END), 0) AS lunch_bites,
            COALESCE(SUM(CASE WHEN es.meal_type = 'Dinner'    THEN es.total_bites ELSE 0 END), 0) AS dinner_bites,
            COALESCE(SUM(CASE WHEN es.meal_type = 'Snack'     THEN es.total_bites ELSE 0 END), 0) AS snack_bites,
            COALESCE(AVG(es.tremor_index)::SMALLINT, 0)                              AS avg_tremor_index
        FROM eating_sessions es
        WHERE es.user_id = v_user AND DATE(es.started_at) = v_date
        GROUP BY es.user_id, DATE(es.started_at)
    ),
    bite_agg AS (
        SELECT
            es.user_id,
            DATE(es.started_at)                                                       AS date,
            COALESCE(AVG(b.tremor_magnitude), 0)                                      AS avg_tremor_magnitude,
            COALESCE(AVG(b.tremor_frequency), 0)                                      AS avg_tremor_frequency,
            COUNT(CASE WHEN b.tremor_magnitude < 0.6                              THEN 1 END) AS tremor_low_count,
            COUNT(CASE WHEN b.tremor_magnitude >= 0.6 AND b.tremor_magnitude < 1.4 THEN 1 END) AS tremor_moderate_count,
            COUNT(CASE WHEN b.tremor_magnitude >= 1.4                             THEN 1 END) AS tremor_high_count,
            COALESCE(AVG(b.food_temp_c), 0)                                           AS avg_food_temp_c
        FROM eating_sessions es
        LEFT JOIN bites b ON b.meal_uuid = es.uuid AND b.is_valid = TRUE
        WHERE es.user_id = v_user AND DATE(es.started_at) = v_date
        GROUP BY es.user_id, DATE(es.started_at)
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

CREATE OR REPLACE FUNCTION trigger_bites_update_daily_summary()
RETURNS TRIGGER AS $$
DECLARE
    v_meal_uuid UUID;
    v_session eating_sessions%ROWTYPE;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_meal_uuid := OLD.meal_uuid;
    ELSE
        v_meal_uuid := NEW.meal_uuid;
    END IF;

    SELECT * INTO v_session FROM eating_sessions WHERE uuid = v_meal_uuid;
    IF FOUND THEN
        UPDATE eating_sessions SET updated_at = NOW() WHERE uuid = v_meal_uuid;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_bites_rebuild_daily ON bites;
CREATE TRIGGER trigger_bites_rebuild_daily
    AFTER INSERT OR UPDATE OR DELETE ON bites
    FOR EACH ROW EXECUTE FUNCTION trigger_bites_update_daily_summary();
