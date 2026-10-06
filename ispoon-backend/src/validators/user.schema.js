import { z } from 'zod';

export const updateProfileSchema = z.object({
    body: z.object({
        name: z.string().min(1, "Name is required").max(100).optional().nullable(),
        phone: z.string().max(20).optional().nullable(),
        gender: z.string().max(20).optional().nullable(), // Matches users.gender in the database.
        location: z.string().max(200).optional().nullable(),
        age: z.number().int().min(0).max(150).optional().nullable(),
        notifications_enabled: z.boolean().optional().nullable(),
    }).strict(),
});
