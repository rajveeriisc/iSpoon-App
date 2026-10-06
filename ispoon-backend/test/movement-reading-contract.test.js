import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { syncBitesSchema } from '../src/validators/bite.schema.js';
import { createMealSchema } from '../src/validators/meal.schema.js';

const migration = fs.readFileSync(
  new URL('../src/migrations/021_movement_reading_contract.sql', import.meta.url),
  'utf8',
);

const bite = (over = {}) => ({
  sequence_number: 0,
  timestamp: '2026-09-17T08:00:00.000Z',
  tremor_magnitude: 0.4,
  tremor_frequency: 5.1,
  tremor_confidence: 0.82,
  tremor_window_ms: 5000,
  ...over,
});
const syncBody = (b) => ({ body: { bites: [b] }, params: { uuid: '9a48558e-9c8e-4e6a-aff6-8048d39e3266' } });

test('migration 021 widens the window bound and adds the movement columns', () => {
  assert.match(migration, /tremor_window_ms >= 3000 AND tremor_window_ms <= 60000/);
  assert.match(migration, /ALTER TABLE bites[\s\S]*ADD COLUMN IF NOT EXISTS steady_pct/);
  for (const col of ['steady_pct', 'rhythm_hz', 'measured_seconds', 'movement_source']) {
    assert.match(migration, new RegExp(`ADD COLUMN IF NOT EXISTS ${col}`),
      `eating_sessions.${col} must be added`);
  }
  // Every ADD COLUMN is IF NOT EXISTS and no column or table is dropped, so a
  // re-run cannot destroy data.
  assert.equal(/DROP\s+(TABLE|COLUMN)/i.test(migration), false);
});

test('a 60 s rolling reading is accepted; a meal-long one is not', () => {
  assert.equal(syncBitesSchema.safeParse(syncBody(bite({ tremor_window_ms: 60000 }))).success, true);
  assert.equal(syncBitesSchema.safeParse(syncBody(bite({ tremor_window_ms: 60001 }))).success, false);
  assert.equal(syncBitesSchema.safeParse(syncBody(bite({ tremor_window_ms: 300000 }))).success, false);
  assert.equal(syncBitesSchema.safeParse(syncBody(bite({ tremor_window_ms: 2999 }))).success, false);
});

test('bites carry their own steadiness, bounded to a percentage', () => {
  assert.equal(syncBitesSchema.safeParse(syncBody(bite({ steady_pct: 91.5 }))).success, true);
  assert.equal(syncBitesSchema.safeParse(syncBody(bite({ steady_pct: 0 }))).success, true);
  assert.equal(syncBitesSchema.safeParse(syncBody(bite({ steady_pct: 100 }))).success, true);
  assert.equal(syncBitesSchema.safeParse(syncBody(bite({ steady_pct: 100.1 }))).success, false);
  assert.equal(syncBitesSchema.safeParse(syncBody(bite({ steady_pct: -1 }))).success, false);
});

test('a meal carries the whole-meal figures the AI Lab page shows', () => {
  const meal = (over = {}) => ({
    body: {
      started_at: '2026-09-17T08:00:00.000Z',
      meal_type: 'Breakfast',
      total_bites: 12,
      steady_pct: 91.9,
      rhythm_hz: 5.08,
      measured_seconds: 2700,
      movement_source: 'ai_lab',
      ...over,
    },
  });
  assert.equal(createMealSchema.safeParse(meal()).success, true);
  // A meal is measured for as long as it lasts — the per-bite bound must not
  // be copied here, or long meals are rejected all over again.
  assert.equal(createMealSchema.safeParse(meal({ measured_seconds: 86400 })).success, true);
  assert.equal(createMealSchema.safeParse(meal({ measured_seconds: 86401 })).success, false);
  assert.equal(createMealSchema.safeParse(meal({ steady_pct: 101 })).success, false);
  assert.equal(createMealSchema.safeParse(meal({ rhythm_hz: 0 })).success, false);
  assert.equal(createMealSchema.safeParse(meal({ rhythm_hz: 21 })).success, false);
  // Absent is fine: rows recorded before the model carry none of this.
  assert.equal(createMealSchema.safeParse({
    body: { started_at: '2026-09-17T08:00:00.000Z', meal_type: 'Lunch' },
  }).success, true);
});
