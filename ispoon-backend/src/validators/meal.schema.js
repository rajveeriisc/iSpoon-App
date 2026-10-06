import { z } from 'zod';

export const getMealsSchema = z.object({
    query: z.object({
        limit: z.coerce.number().int().min(1).max(100).optional().default(20),
        offset: z.coerce.number().int().min(0).max(10_000).optional().default(0),
        meal_type: z.enum(['Breakfast', 'Lunch', 'Dinner', 'Snack']).optional(),
        mealType: z.enum(['Breakfast', 'Lunch', 'Dinner', 'Snack']).optional(),
        sort_by: z.enum(['started_at', 'updated_at']).optional().default('started_at'),
        include_bites: z.union([
            z.boolean(),
            z.enum(['true', 'false']).transform(value => value === 'true'),
        ]).optional().default(false),
        before_started_at: z.string().datetime().optional(),
        before_id: z.string().regex(/^\d+$/).optional(),
    }).strict(),
}).refine(({ query }) => Boolean(query.before_started_at) === Boolean(query.before_id), {
    message: 'before_started_at and before_id must be provided together',
    path: ['query', 'before_started_at'],
});

export const createMealSchema = z.object({
    body: z.object({
        uuid: z.string().uuid("Invalid UUID format for meal").optional(),
        device_id: z.string().uuid("Invalid UUID format for device").optional().nullable(),
        // Stable per-spoon (per-person) key — hardware product id, or the BLE
        // device id as a fallback. Free-form string (not the devices UUID).
        spoon_key: z.string().max(64).optional().nullable(),
        started_at: z.string().datetime("Invalid ISO datetime for started_at"),
        ended_at: z.string().datetime("Invalid ISO datetime for ended_at").optional().nullable(),
        local_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "local_date must be YYYY-MM-DD").optional().nullable(),
        meal_type: z.enum(['Breakfast', 'Lunch', 'Dinner', 'Snack']).optional().nullable(),
        total_bites: z.number().int().min(0).max(10000).optional(),
        avg_pace_bpm: z.number().min(0).max(500).optional().nullable(),
        tremor_index: z.number().min(0).max(3).optional().nullable(),
        duration_minutes: z.number().min(0).max(1440).optional().nullable(), // max 24h
        avg_food_temp_c: z.number().min(-10).max(200).optional().nullable(),
        // Whole-meal movement figures (migration 021). The per-bite reading
        // lives on bites; these are what the AI Lab page shows for the meal.
        steady_pct: z.number().min(0).max(100).optional().nullable(),
        rhythm_hz: z.number().gt(0).max(20).optional().nullable(),
        measured_seconds: z.number().int().min(0).max(86400).optional().nullable(),
        movement_source: z.string().max(32).optional().nullable(),
    }),
}).refine(data => {
    if (data.body.ended_at && data.body.started_at) {
        return new Date(data.body.ended_at) >= new Date(data.body.started_at);
    }
    return true;
}, { message: "ended_at must be after or equal to started_at", path: ["body", "ended_at"] });

export const updateMealSchema = z.object({
    body: z.object({
        ended_at: z.string().datetime("Invalid ISO datetime for ended_at").optional().nullable(),
        meal_type: z.enum(['Breakfast', 'Lunch', 'Dinner', 'Snack']).optional(),
        total_bites: z.number().int().min(0).max(10000).optional(),
        avg_pace_bpm: z.number().min(0).max(500).optional().nullable(),
        tremor_index: z.number().min(0).max(3).optional().nullable(),
        duration_minutes: z.number().min(0).max(1440).optional().nullable(),
        avg_food_temp_c: z.number().min(-10).max(200).optional().nullable(),
        local_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "local_date must be YYYY-MM-DD").optional().nullable(),
        // Whole-meal movement figures (migration 021). The per-bite reading
        // lives on bites; these are what the AI Lab page shows for the meal.
        steady_pct: z.number().min(0).max(100).optional().nullable(),
        rhythm_hz: z.number().gt(0).max(20).optional().nullable(),
        measured_seconds: z.number().int().min(0).max(86400).optional().nullable(),
        movement_source: z.string().max(32).optional().nullable(),
    }),
    params: z.object({
        id: z.string().regex(/^\d+$/, "ID must be a number"),
    }),
});

export const mealIdParamSchema = z.object({
    params: z.object({
        id: z.string().regex(/^\d+$/, "ID must be a number"),
    }),
});

export const updateMealTemperatureSchema = z.object({
    body: z.object({
        avg_food_temp_c: z.number().min(-10).max(200),
    }),
    params: z.object({
        id: z.string().regex(/^\d+$/, "ID must be a number"),
    }),
});
