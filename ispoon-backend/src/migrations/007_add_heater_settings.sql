-- ============================================================================
-- 007_add_heater_settings.sql
-- Re-introduces heater_activation_temp on devices.
--
-- Context: 004_drop_heater_activation_temp.sql removed this column as
-- "unused". It is not unused — the Flutter client's heater control screen
-- (heater_control_page.dart / DeviceModel) reads and writes
-- heater_activation_temp via PATCH /devices/:deviceId/settings, but the
-- backend silently dropped the field, so it never persisted server-side.
-- This migration restores the column (idempotent, safe to re-run) so the
-- setting survives reinstalls/device switches like heater_active and
-- heater_max_temp already do.
-- ============================================================================

ALTER TABLE devices
  ADD COLUMN IF NOT EXISTS heater_activation_temp DECIMAL(5,2) DEFAULT 15.0;
