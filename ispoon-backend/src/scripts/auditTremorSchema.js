import { pool } from "../config/db.js";

// Read-only production-safe audit for the hand-movement measurement contract.
// It intentionally prints schema metadata and aggregate counts only—never
// connection details, user identifiers, or individual health readings.
async function run() {
  try {
    const [migrations, columns, constraints, bites, summaries] =
      await Promise.all([
        pool.query(
          "SELECT filename FROM schema_migrations ORDER BY filename",
        ),
        pool.query(`
          SELECT column_name, data_type, numeric_precision, numeric_scale
          FROM information_schema.columns
          WHERE table_schema = current_schema()
            AND table_name = 'bites'
            AND column_name LIKE 'tremor_%'
          ORDER BY column_name
        `),
        pool.query(`
          SELECT conname, pg_get_constraintdef(oid) AS definition
          FROM pg_constraint
          WHERE conrelid = 'bites'::regclass
            AND conname LIKE '%tremor%'
          ORDER BY conname
        `),
        pool.query(`
          SELECT
            COUNT(*)::int AS total,
            COUNT(tremor_magnitude)::int AS measured,
            COUNT(tremor_frequency)::int AS rhythmic,
            COUNT(tremor_confidence)::int AS with_confidence,
            COUNT(*) FILTER (
              WHERE tremor_frequency IS NOT NULL
                AND tremor_magnitude IS NULL
            )::int AS frequency_without_index,
            COUNT(*) FILTER (
              WHERE tremor_frequency = 0
            )::int AS zero_frequency,
            COUNT(*) FILTER (
              WHERE tremor_magnitude < 0 OR tremor_magnitude > 3
            )::int AS invalid_index,
            COUNT(*) FILTER (
              WHERE tremor_frequency < 0 OR tremor_frequency > 20
            )::int AS invalid_frequency,
            COUNT(*) FILTER (
              WHERE tremor_confidence < 0 OR tremor_confidence > 1
            )::int AS invalid_confidence,
            COUNT(*) FILTER (
              WHERE tremor_window_ms < 3000 OR tremor_window_ms > 30000
            )::int AS invalid_window
          FROM bites
        `),
        pool.query(`
          SELECT
            COUNT(*)::int AS total,
            COALESCE(SUM(tremor_rhythmic_count), 0)::int AS rhythmic_readings,
            COUNT(*) FILTER (
              WHERE tremor_low_count
                  + tremor_moderate_count
                  + tremor_high_count = 0
            )::int AS without_movement_samples
          FROM daily_summaries
        `),
      ]);

    console.log(
      JSON.stringify(
        {
          migrations: migrations.rows.map((row) => row.filename),
          columns: columns.rows,
          constraints: constraints.rows,
          bites: bites.rows[0],
          daily_summaries: summaries.rows[0],
        },
        null,
        2,
      ),
    );
  } finally {
    await pool.end();
  }
}

run().catch((error) => {
  console.error(`Tremor schema audit failed: ${error.message}`);
  process.exitCode = 1;
});
