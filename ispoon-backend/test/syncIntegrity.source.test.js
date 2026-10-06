import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { syncBitesSchema } from "../src/validators/bite.schema.js";

const read = (relativePath) => readFileSync(new URL(`../${relativePath}`, import.meta.url), "utf8");

test("bite sync is set-based, deterministic, and ownership-locked", () => {
    const source = read("src/models/biteModel.js");

    assert.match(source, /FOR KEY SHARE/);
    assert.match(source, /jsonb_array_elements\(\$2::jsonb\) WITH ORDINALITY/);
    assert.match(source, /DISTINCT ON \(sequence_number\)/);
    assert.match(source, /timestamp\s*= EXCLUDED\.timestamp/);
    assert.doesNotMatch(source, /for \(const bite of bites\)/);
});

test("meal mutations enforce ownership in the SQL statement", () => {
    const source = read("src/models/mealModel.js");

    assert.match(source, /WHERE id = \$\$\{values\.length\} AND user_id = \$\$\{values\.length \+ 1\}/);
    assert.match(source, /WHERE id = \$1 AND user_id = \$2\s+RETURNING id/);
    assert.match(source, /WHERE eating_sessions\.user_id = EXCLUDED\.user_id/);
    assert.match(source, /SELECT 1 FROM devices WHERE id = \$3::uuid AND user_id = \$2/);
});

test("analytics session counts use local_date not DATE(started_at)", () => {
    const source = read("src/models/analyticsModel.js");
    assert.match(source, /local_date BETWEEN \$2 AND \$3/);
    assert.doesNotMatch(source, /DATE\(started_at\) BETWEEN/);
});

test("meal uuid conflict is a uniform 404", () => {
    const source = read("src/services/mealService.js");
    assert.match(source, /Meal not found/);
    assert.doesNotMatch(source, /Meal identifier belongs to another user/);
});

test("meal restore can batch owned bites without per-meal HTTP requests", () => {
    const model = read("src/models/mealModel.js");
    const schema = read("src/validators/meal.schema.js");

    assert.match(schema, /include_bites/);
    assert.match(model, /WHERE b\.meal_uuid = eating_sessions\.uuid/);
    assert.match(model, /jsonb_agg/);
    assert.match(model, /'is_valid', b\.is_valid/);
    assert.match(model, /'tremor_confidence', b\.tremor_confidence/);
    assert.match(model, /'tremor_window_ms', b\.tremor_window_ms/);
    // Nested include_bites must stay bounded to avoid multi-MB meal lists.
    assert.match(model, /LIMIT 500/);
});

test("rollups cover inserts, updates, deletes, and date moves without per-bite triggers", () => {
    const sql = read("src/migrations/012_rollup_trigger_correctness.sql");

    assert.match(sql, /AFTER INSERT OR UPDATE OR DELETE ON eating_sessions/);
    assert.match(sql, /OLD\.user_id, OLD\.local_date/);
    assert.match(sql, /NEW\.user_id, NEW\.local_date/);
    assert.match(sql, /IF NOT FOUND THEN\s+DELETE FROM daily_summaries/);
    assert.match(sql, /ALTER COLUMN local_date SET NOT NULL/);
    assert.equal((sql.match(/FOR EACH STATEMENT/g) || []).length, 3);
    assert.doesNotMatch(sql, /UPDATE eating_sessions SET updated_at/);
});

test("migration runner serializes deploys and pins checksums", () => {
    const source = read("src/scripts/migrate.js");

    assert.match(source, /pg_advisory_lock/);
    assert.match(source, /createHash\("sha256"\)/);
    assert.match(source, /Applied migration was modified/);
    assert.match(source, /Applied migration file is missing/);
});

test("tremor migration repairs only unambiguous legacy-scaled values", () => {
    const sql = read("src/migrations/015_tremor_scale_alignment.sql");

    assert.match(sql, /WHEN tremor_index > 3 THEN tremor_index::NUMERIC \/ 100/);
    assert.match(sql, /CHECK \(tremor_index >= 0 AND tremor_index <= 3\)/);
    assert.match(sql, /AVG\(es\.tremor_index\)/);
    assert.doesNotMatch(sql, /AVG\(es\.tremor_index\)::SMALLINT/);
});

test("tremor quality migration distinguishes measured-low from unavailable", () => {
    const sql = read("src/migrations/017_tremor_measurement_quality.sql");

    assert.match(sql, /tremor_confidence NUMERIC\(4,3\)/);
    assert.match(sql, /tremor_window_ms INTEGER/);
    assert.match(sql, /tremor_confidence >= 0 AND tremor_confidence <= 1/);
    assert.match(sql, /tremor_window_ms >= 3000 AND tremor_window_ms <= 30000/);
});

test("movement contract migration repairs relationships and tracks rhythmic samples", () => {
    const sql = read("src/migrations/018_movement_contract_hardening.sql");

    assert.match(sql, /SET tremor_frequency = NULL\s+WHERE tremor_magnitude IS NULL/);
    assert.match(sql, /tremor_magnitude >= 0 AND tremor_magnitude <= 3/);
    assert.match(sql, /tremor_frequency > 0 AND tremor_frequency <= 20/);
    assert.match(sql, /tremor_quality_pair_check/);
    assert.match(sql, /COUNT\(b\.tremor_frequency\) AS tremor_rhythmic_count/);
    assert.match(sql, /PERFORM rebuild_daily_summary/);
});

test("bite validation rejects orphaned or partial movement metadata", () => {
    const base = {
        timestamp: "2026-08-31T00:00:00.000Z",
        sequence_number: 1,
    };
    const parse = (bite) => syncBitesSchema.safeParse({
        body: { bites: [bite] },
        params: { uuid: "550e8400-e29b-41d4-a716-446655440000" },
    });

    assert.equal(parse({ ...base, tremor_frequency: 5 }).success, false);
    assert.equal(parse({
        ...base,
        tremor_magnitude: 0.4,
        tremor_confidence: 0.8,
    }).success, false);
    assert.equal(parse({
        ...base,
        tremor_magnitude: 0,
        tremor_confidence: 0.8,
        tremor_window_ms: 4000,
    }).success, true);
});

test("legacy frequencies are excluded from quality-qualified rhythm summaries", () => {
    const sql = read("src/migrations/019_quality_qualified_rhythm.sql");

    assert.match(sql, /AVG\(b\.tremor_frequency\) FILTER/);
    assert.match(sql, /COUNT\(b\.tremor_frequency\) FILTER/);
    assert.match(sql, /b\.tremor_confidence >= 0\.5/);
    assert.match(sql, /b\.tremor_window_ms >= 3000/);
    assert.match(sql, /PERFORM rebuild_daily_summary/);
});

test("legacy device claims are explicit and cannot imply possession", () => {
    const migration = read("src/migrations/013_device_pairing_foundation.sql");
    const model = read("src/models/deviceModel.js");

    assert.match(migration, /pairing_method VARCHAR\(32\) NOT NULL DEFAULT 'legacy_identifier'/);
    assert.match(migration, /possession_verified_at TIMESTAMPTZ/);
    assert.match(model, /WHERE devices\.user_id = \$1/);
    assert.match(model, /ON CONFLICT \(product_id\)/);
    assert.doesNotMatch(
      model.slice(model.indexOf("getUserDevices")),
      /mac_address_hash/,
    );
});
