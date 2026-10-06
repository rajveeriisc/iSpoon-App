-- ============================================================================
-- 013_device_pairing_foundation.sql
-- Record whether ownership was proven cryptographically.
--
-- Current app/firmware submits only a MAC-derived identifier; it cannot answer
-- a server nonce using a device-held secret. Existing registration therefore
-- remains explicitly "legacy_identifier" and unverified. The unique index plus
-- ownership-guarded upsert still prevents account-to-account reassignment.
-- ============================================================================

ALTER TABLE devices
    ADD COLUMN IF NOT EXISTS pairing_method VARCHAR(32) NOT NULL DEFAULT 'legacy_identifier',
    ADD COLUMN IF NOT EXISTS possession_verified_at TIMESTAMPTZ;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'devices_pairing_method_valid'
          AND conrelid = 'devices'::regclass
    ) THEN
        ALTER TABLE devices
            ADD CONSTRAINT devices_pairing_method_valid
            CHECK (pairing_method IN ('legacy_identifier', 'device_challenge'));
    END IF;
END $$;

COMMENT ON COLUMN devices.possession_verified_at IS
    'Set only after a device-held secret signs a server nonce; NULL for legacy MAC-identifier claims.';
