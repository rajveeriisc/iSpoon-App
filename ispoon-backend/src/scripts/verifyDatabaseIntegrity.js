import "dotenv/config";
import { randomUUID } from "node:crypto";

import { pool } from "../config/db.js";

const asNumber = (value) => Number(value ?? 0);

const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

const run = async () => {
  if (
    /neon\.tech/i.test(process.env.DATABASE_URL || '') &&
    process.env.ALLOW_LIVE_DB !== '1'
  ) {
    throw new Error(
      'Refusing to run integrity fixtures against Neon. Set ALLOW_LIVE_DB=1 only on a throwaway database.',
    );
  }
  const client = await pool.connect();
  try {
    const migrations = await client.query(
      `SELECT filename
       FROM schema_migrations
       WHERE filename IN (
         '011_refresh_token_families.sql',
         '012_rollup_trigger_correctness.sql',
         '013_device_pairing_foundation.sql',
         '014_notification_contract_alignment.sql',
         '015_tremor_scale_alignment.sql'
       )
       ORDER BY filename`,
    );
    assert(migrations.rowCount === 5, "Required migrations 011-015 are not all applied");

    const notificationContract = await client.query(`
      SELECT
        EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'users'
            AND column_name = 'notification_preferences' AND data_type = 'jsonb'
        ) AS has_preferences,
        COUNT(*) FILTER (
          WHERE column_name IN ('action_type', 'opened_at', 'action_taken_at', 'delivery_status')
        ) AS history_columns
      FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'notifications'
    `);
    assert(notificationContract.rows[0].has_preferences, "notification_preferences JSONB column is missing");
    assert(asNumber(notificationContract.rows[0].history_columns) === 4, "Notification history columns are missing");

    const integrity = await client.query(`
      WITH expected AS (
        SELECT
          user_id,
          local_date AS date,
          COALESCE(SUM(total_bites), 0)::BIGINT AS total_bites,
          COALESCE(SUM(duration_minutes), 0)::NUMERIC AS total_duration
        FROM eating_sessions
        GROUP BY user_id, local_date
      ), compared AS (
        SELECT
          COALESCE(e.user_id, s.user_id) AS user_id,
          COALESCE(e.date, s.date) AS date,
          e.user_id IS NULL AS stale_summary,
          s.user_id IS NULL AS missing_summary,
          e.total_bites IS DISTINCT FROM s.total_bites::BIGINT AS bite_mismatch,
          e.total_duration IS DISTINCT FROM s.total_eating_duration_min::NUMERIC AS duration_mismatch
        FROM expected e
        FULL JOIN daily_summaries s USING (user_id, date)
      )
      SELECT
        COUNT(*) AS compared_days,
        COUNT(*) FILTER (WHERE stale_summary) AS stale_summary_days,
        COUNT(*) FILTER (WHERE missing_summary) AS missing_summary_days,
        COUNT(*) FILTER (WHERE NOT stale_summary AND NOT missing_summary AND bite_mismatch) AS bite_mismatch_days,
        COUNT(*) FILTER (WHERE NOT stale_summary AND NOT missing_summary AND duration_mismatch) AS duration_mismatch_days,
        (SELECT COUNT(*) FROM bites b LEFT JOIN eating_sessions es ON es.uuid = b.meal_uuid WHERE es.uuid IS NULL) AS orphan_bites,
        (SELECT COUNT(*) FROM eating_sessions WHERE local_date IS NULL) AS meals_missing_local_date
      FROM compared
    `);

    const counts = integrity.rows[0];
    for (const key of [
      "stale_summary_days",
      "missing_summary_days",
      "bite_mismatch_days",
      "duration_mismatch_days",
      "orphan_bites",
      "meals_missing_local_date",
    ]) {
      assert(asNumber(counts[key]) === 0, `Integrity check failed: ${key}=${counts[key]}`);
    }

    // Exercise the deployed trigger functions against rollback-only fixtures.
    await client.query("BEGIN");
    const suffix = randomUUID();
    const user = await client.query(
      `INSERT INTO users (email, name, firebase_uid, email_verified)
       VALUES ($1, 'Integrity Check', $2, TRUE)
       RETURNING id`,
      [`integrity-${suffix}@example.invalid`, `integrity-${suffix}`],
    );
    const userId = user.rows[0].id;
    const preferences = await client.query(
      `UPDATE users
       SET notification_preferences = notification_preferences || '{"enabled": true}'::jsonb
       WHERE id = $1
       RETURNING notification_preferences`,
      [userId],
    );
    assert(preferences.rows[0].notification_preferences.enabled === true, "Notification preferences are not writable");

    const notification = await client.query(
      `INSERT INTO notifications (user_id, title, body, type, data, action_type)
       VALUES ($1, 'Integrity check', 'Rollback-only fixture', 'system_alerts', '{}'::jsonb, 'open_app')
       RETURNING id, delivery_status`,
      [userId],
    );
    assert(notification.rows[0].delivery_status === 'delivered', "Notification delivery default is incorrect");
    const opened = await client.query(
      `UPDATE notifications
       SET read = TRUE, opened_at = NOW(), action_taken_at = NOW()
       WHERE id = $1
       RETURNING opened_at, action_taken_at`,
      [notification.rows[0].id],
    );
    assert(opened.rows[0].opened_at && opened.rows[0].action_taken_at, "Notification lifecycle timestamps failed");
    const meal = await client.query(
      `INSERT INTO eating_sessions
         (user_id, started_at, meal_type, total_bites, duration_minutes, tremor_index, local_date)
       VALUES ($1, '2099-01-01T12:00:00Z', 'Lunch', 3, 5, 1.5, DATE '2099-01-01')
       RETURNING uuid`,
      [userId],
    );
    const mealUuid = meal.rows[0].uuid;

    await client.query(
      `INSERT INTO bites
         (meal_uuid, timestamp, sequence_number, tremor_magnitude, tremor_frequency, food_temp_c, is_valid)
       VALUES
         ($1, '2099-01-01T12:01:00Z', 0, 0.5, 4, 40, TRUE),
         ($1, '2099-01-01T12:02:00Z', 1, 1.5, 6, 42, TRUE)
       ON CONFLICT (meal_uuid, sequence_number) DO UPDATE SET
         tremor_magnitude = EXCLUDED.tremor_magnitude`,
      [mealUuid],
    );

    const firstSummary = await client.query(
      `SELECT total_bites, tremor_low_count, tremor_high_count, avg_tremor_magnitude
       FROM daily_summaries WHERE user_id = $1 AND date = DATE '2099-01-01'`,
      [userId],
    );
    assert(firstSummary.rowCount === 1, "Insert did not create a daily summary");
    assert(asNumber(firstSummary.rows[0].total_bites) === 3, "Meal bite total is incorrect");
    assert(asNumber(firstSummary.rows[0].tremor_low_count) === 1, "Low tremor count is incorrect");
    assert(asNumber(firstSummary.rows[0].tremor_high_count) === 1, "High tremor count is incorrect");
    assert(asNumber(firstSummary.rows[0].avg_tremor_magnitude) === 1, "Tremor average is incorrect");

    await client.query(
      "UPDATE eating_sessions SET local_date = DATE '2099-01-02' WHERE uuid = $1",
      [mealUuid],
    );
    const moved = await client.query(
      `SELECT date FROM daily_summaries
       WHERE user_id = $1 AND date IN (DATE '2099-01-01', DATE '2099-01-02')
       ORDER BY date`,
      [userId],
    );
    assert(moved.rowCount === 1 && String(moved.rows[0].date).includes("2099"), "Date move left a stale summary");

    await client.query("DELETE FROM eating_sessions WHERE uuid = $1", [mealUuid]);
    const afterDelete = await client.query(
      "SELECT 1 FROM daily_summaries WHERE user_id = $1",
      [userId],
    );
    assert(afterDelete.rowCount === 0, "Deleting the final meal left a stale summary");

    await client.query("ROLLBACK");
    console.log(JSON.stringify({
      migrations: migrations.rows.map((row) => row.filename),
      integrity: counts,
      rollbackFixture: "passed",
    }, null, 2));
  } catch (error) {
    try { await client.query("ROLLBACK"); } catch { /* no open transaction */ }
    throw error;
  } finally {
    client.release();
    await pool.end();
  }
};

run().catch((error) => {
  console.error(`Database integrity verification failed: ${error.message}`);
  process.exitCode = 1;
});
