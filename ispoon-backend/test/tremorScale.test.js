import assert from 'node:assert/strict';
import test from 'node:test';
import { toTremorIndex } from '../src/models/mealModel.js';
import { createMealSchema, updateMealSchema } from '../src/validators/meal.schema.js';

test('tremor index preserves the mobile 0..3 scale without discontinuity', () => {
    assert.equal(toTremorIndex(0), 0);
    assert.equal(toTremorIndex(0.9), 0.9);
    assert.equal(toTremorIndex(1), 1);
    assert.equal(toTremorIndex(1.1), 1.1);
    assert.equal(toTremorIndex(3), 3);
    assert.equal(toTremorIndex(99), 3);
});

test('unmeasured tremor stays null instead of fabricating a 0 score', () => {
    assert.equal(toTremorIndex(null), null);
    assert.equal(toTremorIndex(undefined), null);
    assert.equal(toTremorIndex(''), null);
    assert.equal(toTremorIndex('   '), null);
});

test('meal stats leave unmeasured tremor as SQL NULL rather than 0', async () => {
    const { readFile } = await import('node:fs/promises');
    const source = await readFile(new URL('../src/models/mealModel.js', import.meta.url), 'utf8');
    assert.match(source, /ROUND\(AVG\(tremor_index\)::NUMERIC/);
    assert.doesNotMatch(
        source,
        /COALESCE\(ROUND\(AVG\(tremor_index\)::NUMERIC,\s*0\),\s*0\)/,
    );
});

test('meal validators reject tremor values outside the app contract', () => {
    const baseMeal = {
        started_at: '2026-07-20T10:00:00.000Z',
        tremor_index: 1.1,
    };
    assert.equal(createMealSchema.safeParse({ body: baseMeal }).success, true);
    assert.equal(
        createMealSchema.safeParse({ body: { ...baseMeal, tremor_index: 3.1 } }).success,
        false,
    );
    assert.equal(updateMealSchema.safeParse({ body: { tremor_index: 3 }, params: { id: '1' } }).success, true);
});
