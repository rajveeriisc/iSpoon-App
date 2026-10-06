import { pool } from "../config/db.js";

/**
 * Notification Model - Database operations for notifications (V2 Schema)
 */

// Create notification
export const createNotification = async (notificationData) => {
    const {
        user_id,
        title,
        body,
        type,
        priority = 'DEFAULT',
        data = {},
        action_type = null,
        delivery_status = 'delivered',
    } = notificationData;
    const res = await pool.query(
        `INSERT INTO notifications
            (user_id, title, body, type, priority, data, action_type, delivery_status)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         RETURNING *`,
        [user_id, title, body, type, priority, JSON.stringify(data), action_type, delivery_status]
    );
    return res.rows[0];
};

// Mark notification as read
export const markNotificationRead = async (notificationId, userId) => {
    const res = await pool.query(
        `UPDATE notifications
         SET read = TRUE, opened_at = COALESCE(opened_at, NOW())
         WHERE id = $1 AND user_id = $2
         RETURNING *`,
        [notificationId, userId]
    );
    return res.rows[0];
};

export const markNotificationActionTaken = async (notificationId, userId) => {
    const res = await pool.query(
        `UPDATE notifications
         SET read = TRUE,
             opened_at = COALESCE(opened_at, NOW()),
             action_taken_at = COALESCE(action_taken_at, NOW())
         WHERE id = $1 AND user_id = $2
         RETURNING *`,
        [notificationId, userId]
    );
    return res.rows[0];
};

// Get notification history for user
export const getUserNotificationHistory = async (userId, limit = 50, offset = 0) => {
    const res = await pool.query(
        `SELECT id, user_id, title, body, type, priority, read,
                data AS action_data, action_type, opened_at, action_taken_at,
                delivery_status, created_at
         FROM notifications
         WHERE user_id = $1 
         ORDER BY created_at DESC 
         LIMIT $2 OFFSET $3`,
        [userId, limit, offset]
    );
    return res.rows;
};

// Add FCM Token — never reassign a token owned by another user.
export const addFCMToken = async (userId, token) => {
    const existing = await pool.query(
        `SELECT user_id FROM fcm_tokens WHERE token = $1`,
        [token]
    );
    if (existing.rows.length > 0 && Number(existing.rows[0].user_id) !== Number(userId)) {
        const err = new Error("FCM token already registered to another user");
        err.code = "FCM_TOKEN_OWNED";
        throw err;
    }

    const res = await pool.query(
        `INSERT INTO fcm_tokens (user_id, token)
         VALUES ($1, $2)
         ON CONFLICT (token) DO UPDATE SET
             last_used_at = CURRENT_TIMESTAMP
         WHERE fcm_tokens.user_id = EXCLUDED.user_id
         RETURNING *`,
        [userId, token]
    );
    if (!res.rows[0]) {
        const err = new Error("FCM token already registered to another user");
        err.code = "FCM_TOKEN_OWNED";
        throw err;
    }
    return res.rows[0];
};

// Get FCM Tokens for User
export const getUserFCMTokens = async (userId) => {
    const res = await pool.query(
        `SELECT token FROM fcm_tokens WHERE user_id = $1`,
        [userId]
    );
    return res.rows.map(row => row.token);
};

// Remove FCM Token
export const removeFCMToken = async (token, userId) => {
    if (userId == null) {
        await pool.query(`DELETE FROM fcm_tokens WHERE token = $1`, [token]);
        return;
    }
    await pool.query(`DELETE FROM fcm_tokens WHERE token = $1 AND user_id = $2`, [token, userId]);
};
