-- Add device_id to eating_sessions table
ALTER TABLE eating_sessions ADD COLUMN IF NOT EXISTS device_id VARCHAR(255);
