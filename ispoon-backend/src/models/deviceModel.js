import { pool } from "../config/db.js";
import { AppError } from "../utils/errors.js";

/**
 * Create or Update a Device (Upsert based on MAC address)
 * Also handles Heater preferences and firmware version tracking.
 */
const DEVICE_RETURNING = `
        id,
        user_id,
        product_id,
        display_name,
        firmware_version,
        heater_active,
        heater_max_temp,
        heater_activation_temp,
        last_sync_at,
        pairing_method,
        possession_verified_at,
        (possession_verified_at IS NOT NULL) AS possession_verified
`;

export const registerDevice = async ({
  userId,
  productId = null,
  macAddressHash = null,
  firmwareVersion = null,
  heaterActive = false,
  heaterMaxTemp = 40.0,
  heaterActivationTemp = 15.0,
  displayName = null,
}) => {
  const normalizedProductId = productId
    ? String(productId).trim().toLowerCase()
    : null;
  const identityHash = macAddressHash || normalizedProductId;
  if (!identityHash) {
    throw new AppError("productId or macAddressHash is required", 400);
  }

  const sql = normalizedProductId
    ? `
      INSERT INTO devices (
        user_id,
        mac_address_hash,
        product_id,
        display_name,
        firmware_version,
        heater_active,
        heater_max_temp,
        heater_activation_temp,
        last_sync_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
      ON CONFLICT (product_id)
      DO UPDATE SET
        firmware_version = COALESCE(EXCLUDED.firmware_version, devices.firmware_version),
        display_name = COALESCE(EXCLUDED.display_name, devices.display_name),
        mac_address_hash = COALESCE(EXCLUDED.mac_address_hash, devices.mac_address_hash),
        heater_active = COALESCE(EXCLUDED.heater_active, devices.heater_active),
        heater_max_temp = COALESCE(EXCLUDED.heater_max_temp, devices.heater_max_temp),
        heater_activation_temp = COALESCE(EXCLUDED.heater_activation_temp, devices.heater_activation_temp),
        last_sync_at = NOW(),
        updated_at = NOW()
      WHERE devices.user_id = $1
      RETURNING
        ${DEVICE_RETURNING}
    `
    : `
      INSERT INTO devices (
        user_id,
        mac_address_hash,
        product_id,
        display_name,
        firmware_version,
        heater_active,
        heater_max_temp,
        heater_activation_temp,
        last_sync_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
      ON CONFLICT (mac_address_hash)
      DO UPDATE SET
        firmware_version = COALESCE(EXCLUDED.firmware_version, devices.firmware_version),
        display_name = COALESCE(EXCLUDED.display_name, devices.display_name),
        product_id = COALESCE(EXCLUDED.product_id, devices.product_id),
        heater_active = COALESCE(EXCLUDED.heater_active, devices.heater_active),
        heater_max_temp = COALESCE(EXCLUDED.heater_max_temp, devices.heater_max_temp),
        heater_activation_temp = COALESCE(EXCLUDED.heater_activation_temp, devices.heater_activation_temp),
        last_sync_at = NOW(),
        updated_at = NOW()
      WHERE devices.user_id = $1
      RETURNING
        ${DEVICE_RETURNING}
    `;
  const result = await pool.query(sql, [
    userId,
    identityHash,
    normalizedProductId,
    displayName,
    firmwareVersion,
    heaterActive,
    heaterMaxTemp,
    heaterActivationTemp,
  ]);

  if (!result.rows[0]) {
    throw new AppError("Device is registered to another account", 409);
  }

  return result.rows[0];
};

/**
 * Get all active devices for a user.
 */
export const getUserDevices = async (userId) => {
  const result = await pool.query(
    `
      SELECT
        id,
        user_id,
        product_id,
        display_name,
        firmware_version,
        heater_active,
        heater_max_temp,
        heater_activation_temp,
        last_sync_at,
        pairing_method,
        possession_verified_at,
        (possession_verified_at IS NOT NULL) AS possession_verified
      FROM devices
      WHERE user_id = $1
      ORDER BY last_sync_at DESC
    `,
    [userId]
  );
  return result.rows;
};

export const getUserDeviceById = async (userId, deviceId) => {
  const result = await pool.query(
    `
      SELECT id, user_id
      FROM devices
      WHERE id = $1 AND user_id = $2
      LIMIT 1
    `,
    [deviceId, userId]
  );
  return result.rows[0] || null;
};

/**
 * Update device settings (heater control).
 */
export const updateDeviceSettings = async ({
  userId,
  deviceId,
  heaterActive,
  heaterMaxTemp,
  heaterActivationTemp,
}) => {
  const result = await pool.query(
    `
      UPDATE devices
      SET
        heater_active = COALESCE($3, heater_active),
        heater_max_temp = COALESCE($4, heater_max_temp),
        heater_activation_temp = COALESCE($5, heater_activation_temp),
        updated_at = NOW()
      WHERE id = $2 AND user_id = $1
      RETURNING
        id,
        user_id,
        firmware_version,
        heater_active,
        heater_max_temp,
        heater_activation_temp,
        last_sync_at,
        pairing_method,
        possession_verified_at,
        (possession_verified_at IS NOT NULL) AS possession_verified
    `,
    [userId, deviceId, heaterActive, heaterMaxTemp, heaterActivationTemp]
  );
  return result.rows[0];
};

