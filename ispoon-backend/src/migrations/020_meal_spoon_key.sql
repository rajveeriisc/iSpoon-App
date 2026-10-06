-- ============================================================================
-- 020_meal_spoon_key.sql
-- Per-spoon (per-person) attribution for eating sessions.
--
-- In a family, one account has many spoons and each spoon is a different person
-- (spoon = person). Analytics must therefore be bucketed by a STABLE per-spoon
-- key, not the account alone — otherwise every spoon shows the same totals.
--
-- The mobile app already carries this key (the nRF hwinfo product id, falling
-- back to the BLE device id for historical rows). Mirror it here so per-spoon
-- attribution survives a cross-device restore.
--
-- ADDITIVE + non-destructive: a nullable column plus a backfill from the
-- existing device linkage / device_id text where available.
-- ============================================================================

ALTER TABLE eating_sessions
    ADD COLUMN IF NOT EXISTS spoon_key VARCHAR(64);

-- Backfill: prefer the linked device's stable product_id (migration 016); this
-- is exactly the key the app uses for spoons it has identified.
UPDATE eating_sessions es
SET spoon_key = d.product_id
FROM devices d
WHERE es.spoon_key IS NULL
  AND es.device_id = d.id
  AND d.product_id IS NOT NULL;

-- Per-spoon, per-day lookups (home cards / per-person rollups).
CREATE INDEX IF NOT EXISTS idx_eating_sessions_spoon
    ON eating_sessions (user_id, spoon_key, local_date);
