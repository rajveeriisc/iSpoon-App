-- Align persisted notification preferences/history with the Flutter contract.
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS notification_preferences JSONB NOT NULL DEFAULT '{}'::jsonb;

UPDATE users
SET notification_preferences = jsonb_build_object(
        'quiet_hours_start', '22:00',
        'quiet_hours_end', '07:00',
        'health_alerts_enabled', TRUE,
        'achievement_enabled', TRUE,
        'engagement_enabled', TRUE,
        'system_alerts_enabled', TRUE,
        'max_daily_notifications', 5,
        'weekly_digest_enabled', TRUE,
        'weekly_digest_day', 0,
        'weekly_digest_time', '20:00'
    ) || COALESCE(notification_preferences, '{}'::jsonb)
      || jsonb_build_object('enabled', notifications_enabled);

ALTER TABLE notifications
    ADD COLUMN IF NOT EXISTS action_type VARCHAR(64),
    ADD COLUMN IF NOT EXISTS opened_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS action_taken_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS delivery_status VARCHAR(24) NOT NULL DEFAULT 'delivered';

UPDATE notifications
SET opened_at = COALESCE(opened_at, created_at)
WHERE read = TRUE;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'notifications_delivery_status_valid'
          AND conrelid = 'notifications'::regclass
    ) THEN
        ALTER TABLE notifications
            ADD CONSTRAINT notifications_delivery_status_valid
            CHECK (delivery_status IN ('pending', 'sent', 'delivered', 'failed'));
    END IF;
END $$;
