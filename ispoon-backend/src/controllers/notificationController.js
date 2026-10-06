import * as NotificationModel from "../models/notificationModel.js";
import { pool } from "../config/db.js";
import asyncHandler from "../utils/asyncHandler.js";
import logger from "../utils/logger.js";
import { AppError } from "../utils/errors.js";

const DEFAULT_PREFERENCES = Object.freeze({
    quiet_hours_start: '22:00',
    quiet_hours_end: '07:00',
    health_alerts_enabled: true,
    achievement_enabled: true,
    engagement_enabled: true,
    system_alerts_enabled: true,
    max_daily_notifications: 5,
    weekly_digest_enabled: true,
    weekly_digest_day: 0,
    weekly_digest_time: '20:00',
});

/**
 * Notification Controller - Handles notification settings API
 */

// GET /api/notifications/preferences
export const getPreferences = asyncHandler(async (req, res) => {
    const userId = req.user.id;
    const result = await pool.query(
        `SELECT notifications_enabled, notification_preferences FROM users WHERE id = $1`,
        [userId]
    );

    const row = result.rows[0];
    if (!row) throw new AppError('User not found', 404);

    res.json({
        success: true,
        preferences: {
            ...DEFAULT_PREFERENCES,
            ...(row.notification_preferences || {}),
            enabled: row.notifications_enabled,
        },
    });
});

// PUT /api/notifications/preferences
export const updatePreferences = asyncHandler(async (req, res) => {
    const userId = req.user.id;
    const preferences = req.body;
    // Store preference fields only — master toggle lives in notifications_enabled.
    const { enabled, ...preferenceFields } = preferences;
    const updated = await pool.query(
        `UPDATE users
         SET notifications_enabled = $1,
             notification_preferences = $2::jsonb,
             updated_at = NOW()
         WHERE id = $3
         RETURNING notifications_enabled, notification_preferences`,
        [enabled, JSON.stringify(preferenceFields), userId]
    );

    if (!updated.rows[0]) throw new AppError('User not found', 404);

    logger.info('Notification preferences updated', { requestId: req.id, userId });
    res.json({
        success: true,
        preferences: {
            ...DEFAULT_PREFERENCES,
            ...updated.rows[0].notification_preferences,
            enabled: updated.rows[0].notifications_enabled,
        },
        message: 'Preferences updated successfully',
    });
});

// POST /api/notifications/fcm-token
export const registerFCMToken = asyncHandler(async (req, res) => {
    const userId = req.user.id;
    const { fcm_token } = req.body;

    if (!fcm_token || typeof fcm_token !== 'string' || fcm_token.length < 10) {
        throw new AppError('A valid FCM token is required', 400);
    }

    try {
        await NotificationModel.addFCMToken(userId, fcm_token);
    } catch (error) {
        if (error.code === 'FCM_TOKEN_OWNED') {
            throw new AppError('FCM token already registered to another account', 409);
        }
        throw error;
    }

    logger.info('FCM token registered', { requestId: req.id, userId });
    res.json({ success: true, message: 'FCM token registered successfully' });
});

// GET /api/notifications/history
export const getHistory = asyncHandler(async (req, res) => {
    const userId = req.user.id;
    const limit = Math.min(parseInt(req.query.limit, 10) || 50, 200);
    const offset = Math.min(Math.max(parseInt(req.query.offset, 10) || 0, 0), 10000);

    const history = await NotificationModel.getUserNotificationHistory(userId, limit, offset);

    res.json({
        success: true,
        notifications: history,
        pagination: { limit, offset, returned: history.length },
    });
});

// POST /api/notifications/:id/opened
export const markOpened = asyncHandler(async (req, res) => {
    const { id } = req.params;
    const userId = req.user.id;

    const notification = await NotificationModel.markNotificationRead(id, userId);
    if (!notification) throw new AppError('Notification not found', 404);

    res.json({ success: true, notification });
});

// POST /api/notifications/:id/action
export const markActionTaken = asyncHandler(async (req, res) => {
    const { id } = req.params;
    const userId = req.user.id;

    const notification = await NotificationModel.markNotificationActionTaken(id, userId);
    if (!notification) throw new AppError('Notification not found', 404);

    res.json({ success: true, notification });
});
