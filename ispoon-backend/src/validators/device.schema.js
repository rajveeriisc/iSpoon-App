import { z } from 'zod';

// Schemas must be shaped as { body, params, query } because validateRequest
// parses schema.parse({ body, params, query }). A flat schema makes every
// field resolve to undefined and the request always fails validation.
export const registerDeviceSchema = z.object({
    body: z.object({
        productId: z.string().regex(/^[0-9a-fA-F]{16}$/, 'productId must be 16 hex chars').optional(),
        macAddressHash: z.string().min(8, 'macAddressHash too short').max(64, 'macAddressHash too long').optional(),
        firmwareVersion: z.string().max(20).optional(),
        heaterActive: z.union([z.boolean(), z.string().transform(val => val === 'true')]).optional().default(false),
        heaterMaxTemp: z.coerce.number().min(30).max(95).optional().default(40.0),
        heaterActivationTemp: z.coerce.number().min(5).max(30).optional().default(15.0),
        displayName: z.string().max(80).optional(),
    }).strict().refine((data) => Boolean(data.productId || data.macAddressHash), {
        message: 'productId or macAddressHash is required',
    }),
});

export const updateDeviceSettingsSchema = z.object({
    params: z.object({
        deviceId: z.string().min(1, 'deviceId is required'),
    }),
    body: z.object({
        heaterActive: z.union([z.boolean(), z.string().transform(val => val === 'true')]).optional(),
        heaterMaxTemp: z.coerce.number().min(30).max(95).optional(),
        heaterActivationTemp: z.coerce.number().min(5).max(30).optional(),
    }).strict().refine(data => Object.keys(data).length > 0, {
        message: 'At least one setting is required',
    }),
});
