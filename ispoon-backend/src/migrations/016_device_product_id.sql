-- ============================================================================
-- 016_device_product_id.sql
-- Stable spoon identity is the nRF hwinfo 8-byte Device ID (16 hex chars),
-- not the BLE address. Addresses rotate after a settings-erase flash; the
-- product id does not. One row per physical spoon, many spoons per user.
-- ============================================================================

ALTER TABLE devices
    ADD COLUMN IF NOT EXISTS product_id VARCHAR(16),
    ADD COLUMN IF NOT EXISTS display_name VARCHAR(80);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'devices_product_id_key'
          AND conrelid = 'devices'::regclass
    ) THEN
        ALTER TABLE devices
            ADD CONSTRAINT devices_product_id_key UNIQUE (product_id);
    END IF;
END $$;

COMMENT ON COLUMN devices.product_id IS
    '16-hex nRF hwinfo Device ID. Unique across accounts; one owner per spoon.';
