import * as NotificationModel from "../models/notificationModel.js";
import logger from '../utils/logger.js';

class NotificationService {
    /**
     * Send Realtime Notification
     * @param {Object} options Options containing userId, title, body, type, data
     */
    async schedule(options) {
        return this.sendRealtimeNotification(options);
    }

    async sendRealtimeNotification({ userId, title, body, type = 'system_alert', priority = 'DEFAULT', data = {} }) {
        if (!title || !body) {
            logger.error('Missing title or body for notification', { context: 'NotificationService' });
            return null;
        }

        try {
            // Save to DB
            const notification = await NotificationModel.createNotification({
                user_id: userId,
                title,
                body,
                type,
                priority,
                data
            });

            // Import FCM service
            const { default: FCMService } = await import('./fcmService.js');

            const tokens = await NotificationModel.getUserFCMTokens(userId);
            for (const token of tokens) {
                const result = await FCMService.sendNotification(notification, token);
                if (!result.success && result.shouldRemoveToken) {
                    await NotificationModel.removeFCMToken(token);
                }
            }

            logger.info(`Sent notification to user ${userId}`, { context: 'NotificationService' });
            return notification;
        } catch (error) {
            logger.error('Error sending notification', { context: 'NotificationService', error: error.message, stack: error.stack });
            return null;
        }
    }
}

// Export singleton instance
export default new NotificationService();
