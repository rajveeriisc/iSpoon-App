import { pool } from "../config/db.js";

/**
 * Meal Model — eating_sessions table (V3 optimized schema)
 * Columns: id, uuid, user_id, device_id, spoon_key, steady_pct, rhythm_hz,
 *          measured_seconds, movement_source, started_at, ended_at, meal_type,
 *          total_bites, avg_pace_bpm, tremor_index, duration_minutes,
 *          avg_food_temp_c, created_at, updated_at
 */

// ─── READ ─────────────────────────────────────────────────────────────────────

export const getUserMeals = async (
    userId,
    {
        limit = 20,
        offset = 0,
        mealType = null,
        sort_by = "started_at",
        include_bites = false,
        before_started_at = null,
        before_id = null,
    } = {},
) => {
    // Clamp to prevent DoS via unlimited DB reads
    limit = Math.min(Math.max(parseInt(limit, 10) || 20, 1), 100);
    offset = Math.max(parseInt(offset, 10) || 0, 0);
    const sortColumn = sort_by === "updated_at" ? "updated_at" : "started_at";
    // Cap nested bites so include_bites cannot return multi-MB payloads.
    // Dedicated GET /meals/:uuid/bites remains the paginated full history path.
    const bitesProjection = include_bites ? `,
        COALESCE((
            -- ORDER BY must reference the derived table's own sequence_number
            -- column. Writing bite_row.sequence_number looks like a field
            -- access, but bite_row is a jsonb VALUE, not a composite or table,
            -- so Postgres parses it as table.column and fails with
            -- "missing FROM-clause entry for table bite_row" — which turned
            -- every GET /api/meals?include_bites=true into a 500.
            SELECT jsonb_agg(bite_row ORDER BY limited_bites.sequence_number ASC)
            FROM (
                SELECT
                    jsonb_build_object(
                        'id', b.id,
                        'meal_uuid', b.meal_uuid,
                        'timestamp', b.timestamp,
                        'sequence_number', b.sequence_number,
                        'tremor_magnitude', b.tremor_magnitude,
                        'tremor_frequency', b.tremor_frequency,
                        'tremor_confidence', b.tremor_confidence,
                        'tremor_window_ms', b.tremor_window_ms,
                        'food_temp_c', b.food_temp_c,
                        'is_valid', b.is_valid,
                        'created_at', b.created_at
                    ) AS bite_row,
                    b.sequence_number
                FROM bites b
                WHERE b.meal_uuid = eating_sessions.uuid
                ORDER BY b.sequence_number ASC
                LIMIT 500
            ) limited_bites
        ), '[]'::jsonb) AS bites` : '';
    let query = `
        SELECT id, uuid, user_id, device_id, spoon_key, steady_pct, rhythm_hz,
                measured_seconds, movement_source, started_at, ended_at, meal_type,
               total_bites, avg_pace_bpm, tremor_index, local_date,
               duration_minutes, avg_food_temp_c, created_at, updated_at
               ${bitesProjection}
        FROM eating_sessions
        WHERE user_id = $1
    `;
    const params = [userId];

    if (mealType) {
        query += ` AND meal_type = $${params.length + 1}`;
        params.push(mealType);
    }

    if (sortColumn === "started_at" && before_started_at && before_id) {
        query += ` AND (started_at, id) < ($${params.length + 1}::timestamptz, $${params.length + 2}::bigint)`;
        params.push(before_started_at, before_id);
    }

    query += ` ORDER BY ${sortColumn} DESC, id DESC LIMIT $${params.length + 1} OFFSET $${params.length + 2}`;
    params.push(limit, offset);

    const res = await pool.query(query, params);
    return res.rows;
};

export const getUserMealById = async (mealId, userId) => {
    const res = await pool.query(
        `SELECT id, uuid, user_id, device_id, spoon_key, steady_pct, rhythm_hz,
                measured_seconds, movement_source, started_at, ended_at, meal_type,
                total_bites, avg_pace_bpm, tremor_index, local_date,
                duration_minutes, avg_food_temp_c, created_at, updated_at
         FROM eating_sessions
         WHERE id = $1 AND user_id = $2`,
        [mealId, userId]
    );
    return res.rows[0];
};

export const getMealByUuid = async (uuid) => {
    const res = await pool.query(
        `SELECT id, uuid, user_id, device_id, spoon_key, steady_pct, rhythm_hz,
                measured_seconds, movement_source, started_at, ended_at, meal_type,
                total_bites, avg_pace_bpm, tremor_index, local_date,
                duration_minutes, avg_food_temp_c, created_at, updated_at
         FROM eating_sessions WHERE uuid = $1`,
        [uuid]
    );
    return res.rows[0];
};

// ─── WRITE ────────────────────────────────────────────────────────────────────

export const createMeal = async (mealData) => {
    const {
        uuid = null,
        user_id,
        device_id = null,
        spoon_key = null,
        started_at,
        ended_at = null,
        local_date = null,
        meal_type,
        avg_pace_bpm = null,
        duration_minutes = null,
        avg_food_temp_c = null,
        steady_pct = null,
        rhythm_hz = null,
        measured_seconds = null,
        movement_source = null,
    } = mealData;

    const total_bites = toIntOrZero(mealData.total_bites);
    const tremor_index = toTremorIndex(mealData.tremor_index);

    const res = await pool.query(
        `INSERT INTO eating_sessions
             (uuid, user_id, device_id, spoon_key, started_at, ended_at, meal_type,
              total_bites, avg_pace_bpm, tremor_index, duration_minutes, avg_food_temp_c, local_date,
              steady_pct, rhythm_hz, measured_seconds, movement_source)
         SELECT COALESCE($1::uuid, uuid_generate_v4()), $2, $3::uuid, $13, $4, $5, $6,
                $7, $8, $9, $10, $11, $12::date, $14, $15, $16, $17
         WHERE $3::uuid IS NULL OR EXISTS (
             SELECT 1 FROM devices WHERE id = $3::uuid AND user_id = $2
         )
         RETURNING *`,
        [uuid, user_id, device_id, started_at, ended_at, meal_type,
            total_bites, avg_pace_bpm, tremor_index, duration_minutes, avg_food_temp_c, local_date,
            spoon_key, steady_pct, rhythm_hz, measured_seconds, movement_source]
    );
    return res.rows[0];
};

export const updateMeal = async (mealId, userId, updates) => {
    const allowed = [
        'ended_at', 'meal_type', 'total_bites', 'avg_pace_bpm',
        'tremor_index', 'duration_minutes', 'avg_food_temp_c', 'local_date',
        // Migration 021. A meal's movement figures are only final once it
        // ends, so the PATCH that closes it has to be able to set them.
        'steady_pct', 'rhythm_hz', 'measured_seconds', 'movement_source',
    ];

    const setClauses = [];
    const values = [];

    for (const key of allowed) {
        if (Object.prototype.hasOwnProperty.call(updates, key)) {
            let value = updates[key];
            if (key === 'tremor_index') value = toTremorIndex(value);
            if (key === 'total_bites') value = toIntOrZero(value);
            setClauses.push(`${key} = $${values.length + 1}`);
            values.push(value);
        }
    }

    if (setClauses.length === 0) return getUserMealById(mealId, userId);

    setClauses.push('updated_at = NOW()');
    values.push(mealId);

    const res = await pool.query(
        `UPDATE eating_sessions SET ${setClauses.join(', ')}
         WHERE id = $${values.length} AND user_id = $${values.length + 1}
         RETURNING *`,
        [...values, userId]
    );
    return res.rows[0];
};

/** Preserve the mobile app's documented 0–3 tremor score contract. */
export function toTremorIndex(value) {
    if (value == null) return null;
    if (typeof value === 'string' && value.trim() === '') return null;
    const n = Number(value);
    if (!Number.isFinite(n)) return null;
    return Math.max(0, Math.min(3, Math.round(n * 1000) / 1000));
}

function toIntOrZero(value) {
    if (value == null || value === '') return 0;
    const n = Number(value);
    if (!Number.isFinite(n)) return 0;
    return Math.round(n);
}

// Upsert by uuid — used during mobile sync
export const upsertMealByUuid = async (mealData) => {
    const {
        uuid,
        user_id,
        device_id = null,
        spoon_key = null,
        started_at,
        ended_at = null,
        local_date = null,
        meal_type,
        avg_pace_bpm = null,
        duration_minutes = null,
        avg_food_temp_c = null,
        steady_pct = null,
        rhythm_hz = null,
        measured_seconds = null,
        movement_source = null,
    } = mealData;

    const total_bites = toIntOrZero(mealData.total_bites);
    const tremor_index = toTremorIndex(mealData.tremor_index);

    const res = await pool.query(
        `INSERT INTO eating_sessions
             (uuid, user_id, device_id, spoon_key, started_at, ended_at, meal_type,
              total_bites, avg_pace_bpm, tremor_index, duration_minutes, avg_food_temp_c, local_date,
              steady_pct, rhythm_hz, measured_seconds, movement_source)
         SELECT $1::uuid, $2, $3::uuid, $13, $4, $5, $6,
                $7, $8, $9, $10, $11, $12::date, $14, $15, $16, $17
         WHERE $3::uuid IS NULL OR EXISTS (
             SELECT 1 FROM devices WHERE id = $3::uuid AND user_id = $2
         )
         ON CONFLICT (uuid) DO UPDATE SET
             started_at      = EXCLUDED.started_at,
             ended_at         = EXCLUDED.ended_at,
             local_date       = EXCLUDED.local_date,
             meal_type        = EXCLUDED.meal_type,
             total_bites      = EXCLUDED.total_bites,
             avg_pace_bpm     = EXCLUDED.avg_pace_bpm,
             tremor_index     = EXCLUDED.tremor_index,
             duration_minutes = EXCLUDED.duration_minutes,
             avg_food_temp_c  = EXCLUDED.avg_food_temp_c,
             device_id        = EXCLUDED.device_id,
             spoon_key        = EXCLUDED.spoon_key,
             steady_pct       = EXCLUDED.steady_pct,
             rhythm_hz        = EXCLUDED.rhythm_hz,
             measured_seconds = EXCLUDED.measured_seconds,
             movement_source  = EXCLUDED.movement_source,
             updated_at       = NOW()
         WHERE eating_sessions.user_id = EXCLUDED.user_id
         RETURNING *`,
        [uuid, user_id, device_id, started_at, ended_at, meal_type,
            total_bites, avg_pace_bpm, tremor_index, duration_minutes, avg_food_temp_c, local_date,
            spoon_key, steady_pct, rhythm_hz, measured_seconds, movement_source]
    );
    return res.rows[0];
};

export const deleteMeal = async (mealId, userId) => {
    const res = await pool.query(
        `DELETE FROM eating_sessions
         WHERE id = $1 AND user_id = $2
         RETURNING id`,
        [mealId, userId]
    );
    return Boolean(res.rows[0]);
};

// ─── ANALYTICS ───────────────────────────────────────────────────────────────

export const getMealStats = async (userId, startDate, endDate) => {
    const res = await pool.query(
        `SELECT
             COUNT(*)                                                                AS total_meals,
             COALESCE(SUM(total_bites), 0)                                          AS total_bites,
             COALESCE(ROUND(AVG(duration_minutes)::NUMERIC, 1), 0)                 AS avg_duration_min,
             COALESCE(ROUND(AVG(avg_pace_bpm)::NUMERIC, 1), 0)                    AS avg_pace_bpm,
             ROUND(AVG(tremor_index)::NUMERIC, 3)                                  AS avg_tremor_index,
             COUNT(*) FILTER (WHERE meal_type = 'Breakfast')                       AS breakfast_count,
             COUNT(*) FILTER (WHERE meal_type = 'Lunch')                           AS lunch_count,
             COUNT(*) FILTER (WHERE meal_type = 'Dinner')                          AS dinner_count,
             COUNT(*) FILTER (WHERE meal_type IN ('Snack','Snacks'))                AS snack_count
         FROM eating_sessions
         WHERE user_id = $1 AND started_at >= $2 AND started_at <= $3`,
        [userId, startDate, endDate]
    );
    return res.rows[0];
};
