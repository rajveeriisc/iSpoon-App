import { z } from 'zod';

const biteSchema = z.object({
    meal_uuid: z.string().optional(),
    timestamp: z.string().datetime("Invalid ISO datetime for timestamp"),
    sequence_number: z.number().int().min(0).max(100000),
    // Legacy name: the mobile app stores its relative 0–3 movement index here.
    tremor_magnitude: z.number().min(0).max(3).optional().nullable(),
    tremor_frequency: z.number().gt(0).max(20).optional().nullable(),
    tremor_confidence: z.number().min(0).max(1).optional().nullable(),
    // Upper bound is the client's rolling steadiness buffer (60 s), not a
    // meal total — migration 021 widened the column to match. Keep the three
    // copies of this bound (here, the column CHECK, the local SQLite CHECK)
    // in step: a value outside them aborts the whole bite+meal transaction.
    tremor_window_ms: z.number().int().min(3000).max(60000).optional().nullable(),
    steady_pct: z.number().min(0).max(100).optional().nullable(),
    food_temp_c: z.number().min(-10).max(200).optional().nullable(),
    // Flutter SQLite sends 0/1 integers; also accept true/false booleans
    is_valid: z.union([z.boolean(), z.literal(0), z.literal(1)])
        .optional()
        .transform(v => v === 1 || v === true)
        .default(true),
    is_synced: z.union([z.boolean(), z.literal(0), z.literal(1)])
        .optional()
        .transform(v => v === 1 || v === true),
}).superRefine((bite, ctx) => {
    const hasConfidence = bite.tremor_confidence != null;
    const hasWindow = bite.tremor_window_ms != null;
    if (hasConfidence !== hasWindow) {
        ctx.addIssue({
            code: z.ZodIssueCode.custom,
            message: 'tremor_confidence and tremor_window_ms must be provided together',
            path: hasConfidence ? ['tremor_window_ms'] : ['tremor_confidence'],
        });
    }
    if (bite.tremor_magnitude == null &&
        (bite.tremor_frequency != null || hasConfidence || hasWindow)) {
        ctx.addIssue({
            code: z.ZodIssueCode.custom,
            message: 'movement metadata requires tremor_magnitude',
            path: ['tremor_magnitude'],
        });
    }
});

export const syncBitesSchema = z.object({
    body: z.object({
        bites: z.array(biteSchema).min(1, "bites array is required and must not be empty").max(500, "Cannot sync more than 500 bites at once"),
    }),
    params: z.object({
        uuid: z.string().uuid("Invalid UUID format for meal"),
    }),
});

export const getBitesSchema = z.object({
    params: z.object({
        uuid: z.string().uuid("Invalid UUID format for meal"),
    }),
    query: z.object({
        limit: z.coerce.number().int().min(1).max(500).optional().default(500),
        after_sequence: z.coerce.number().int().min(-1).optional().default(-1),
    }).strict(),
});
