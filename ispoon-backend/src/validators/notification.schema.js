import { z } from 'zod';

export const notificationPreferencesSchema = z.object({
    body: z.object({
        enabled: z.boolean(),
        quiet_hours_start: z.string().regex(/^(?:[01]\d|2[0-3]):[0-5]\d$/),
        quiet_hours_end: z.string().regex(/^(?:[01]\d|2[0-3]):[0-5]\d$/),
        health_alerts_enabled: z.boolean(),
        achievement_enabled: z.boolean(),
        engagement_enabled: z.boolean(),
        system_alerts_enabled: z.boolean(),
        max_daily_notifications: z.number().int().min(0).max(100),
        weekly_digest_enabled: z.boolean(),
        weekly_digest_day: z.number().int().min(0).max(6),
        weekly_digest_time: z.string().regex(/^(?:[01]\d|2[0-3]):[0-5]\d$/),
    }).strict(),
});

export const registerFCMTokenSchema = z.object({
    body: z.object({
        fcm_token: z.string().min(10).max(4_096),
    }).strict(),
});

export const notificationHistorySchema = z.object({
    query: z.object({
        limit: z.coerce.number().int().min(1).max(200).optional().default(50),
        offset: z.coerce.number().int().min(0).max(10_000).optional().default(0),
    }).strict(),
});

export const notificationIdSchema = z.object({
    params: z.object({
        id: z.string().regex(/^\d+$/, 'Notification ID must be a number'),
    }).strict(),
});
