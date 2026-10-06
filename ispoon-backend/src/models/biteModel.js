import { pool } from "../config/db.js";

/**
 * Bite Model — bites table
 * Mirrors local SQLite bites table exactly.
 * Columns: id, meal_uuid, timestamp, sequence_number,
 *          tremor_magnitude, tremor_frequency, tremor_confidence,
 *          tremor_window_ms, steady_pct, food_temp_c,
 *          is_valid, is_synced, created_at
 */

// ─── READ ─────────────────────────────────────────────────────────────────────

export const getBitesForMeal = async (mealUuid, { limit = 500, afterSequence = -1 } = {}) => {
    const res = await pool.query(
        `SELECT id, meal_uuid, timestamp, sequence_number,
                tremor_magnitude, tremor_frequency, tremor_confidence,
                tremor_window_ms, steady_pct, food_temp_c,
                is_valid, created_at
         FROM bites
         WHERE meal_uuid = $1 AND sequence_number > $2
         ORDER BY sequence_number ASC
         LIMIT $3`,
        [mealUuid, afterSequence, limit]
    );
    return res.rows;
};

// ─── WRITE ────────────────────────────────────────────────────────────────────

/**
 * Batch-upsert bites for an owned meal inside a single DB transaction.
 * The meal row is locked against deletion for the duration of the write and
 * the entire batch is sent to PostgreSQL as one set-based statement.
 *
 * @param {string} mealUuid
 * @param {string|number} userId
 * @param {Array} bites
 * @returns {{mealOwnerId: string|number|null, rows: Array}}
 */
export const upsertBites = async (mealUuid, userId, bites) => {
    if (!bites || bites.length === 0) {
        return { mealOwnerId: null, rows: [] };
    }

    const client = await pool.connect();
    try {
        await client.query('BEGIN');

        // FOR KEY SHARE prevents the meal disappearing between the ownership
        // check and the FK-backed insert without blocking unrelated updates.
        const mealResult = await client.query(
            `SELECT user_id
             FROM eating_sessions
             WHERE uuid = $1
             FOR KEY SHARE`,
            [mealUuid]
        );
        const mealOwnerId = mealResult.rows[0]?.user_id ?? null;

        if (mealOwnerId == null || Number(mealOwnerId) !== Number(userId)) {
            await client.query('ROLLBACK');
            return { mealOwnerId, rows: [] };
        }

        // jsonb_array_elements preserves input order. DISTINCT ON makes a
        // malformed/retried batch with duplicate sequence numbers deterministic
        // (last value wins) and avoids PostgreSQL's "affect row a second time"
        // ON CONFLICT failure.
        const result = await client.query(
            `WITH decoded AS (
                 SELECT
                     item.ordinality,
                     (item.value->>'timestamp')::timestamptz AS timestamp,
                     (item.value->>'sequence_number')::integer AS sequence_number,
                     (item.value->>'tremor_magnitude')::real AS tremor_magnitude,
                     (item.value->>'tremor_frequency')::real AS tremor_frequency,
                     (item.value->>'tremor_confidence')::real AS tremor_confidence,
                     (item.value->>'tremor_window_ms')::integer AS tremor_window_ms,
                     (item.value->>'steady_pct')::numeric AS steady_pct,
                     (item.value->>'food_temp_c')::real AS food_temp_c,
                     COALESCE((item.value->>'is_valid')::boolean, TRUE) AS is_valid
                 FROM jsonb_array_elements($2::jsonb) WITH ORDINALITY AS item(value, ordinality)
             ), deduplicated AS (
                 SELECT DISTINCT ON (sequence_number)
                     timestamp, sequence_number, tremor_magnitude,
                     tremor_frequency, tremor_confidence, tremor_window_ms,
                     steady_pct, food_temp_c, is_valid
                 FROM decoded
                 ORDER BY sequence_number, ordinality DESC
             )
             INSERT INTO bites
                 (meal_uuid, timestamp, sequence_number,
                  tremor_magnitude, tremor_frequency, tremor_confidence,
                  tremor_window_ms, steady_pct, food_temp_c, is_valid)
             SELECT $1::uuid, timestamp, sequence_number,
                    tremor_magnitude, tremor_frequency, tremor_confidence,
                    tremor_window_ms, steady_pct, food_temp_c, is_valid
             FROM deduplicated
             ON CONFLICT (meal_uuid, sequence_number) DO UPDATE SET
                 timestamp        = EXCLUDED.timestamp,
                 tremor_magnitude = EXCLUDED.tremor_magnitude,
                 tremor_frequency = EXCLUDED.tremor_frequency,
                 tremor_confidence = EXCLUDED.tremor_confidence,
                 tremor_window_ms = EXCLUDED.tremor_window_ms,
                 steady_pct       = EXCLUDED.steady_pct,
                 food_temp_c      = EXCLUDED.food_temp_c,
                 is_valid         = EXCLUDED.is_valid
             RETURNING id, meal_uuid, timestamp, sequence_number,
                       tremor_magnitude, tremor_frequency, tremor_confidence,
                       tremor_window_ms, steady_pct, food_temp_c,
                       is_valid, created_at`,
            [mealUuid, JSON.stringify(bites)]
        );

        await client.query('COMMIT');
        return { mealOwnerId, rows: result.rows };
    } catch (err) {
        await client.query('ROLLBACK');
        throw err;
    } finally {
        client.release();
    }
};

export const deleteBitesForMeal = async (mealUuid) => {
    await pool.query('DELETE FROM bites WHERE meal_uuid = $1', [mealUuid]);
};
