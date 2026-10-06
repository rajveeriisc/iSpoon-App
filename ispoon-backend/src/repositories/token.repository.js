import crypto from "crypto";
import { pool } from "../config/db.js";

/**
 * Hash token for secure storage
 * @param {string} token - Plain text token
 * @returns {string} Hashed token
 */
const hashToken = (token) => {
  return crypto.createHash("sha256").update(token).digest("hex");
};

// ========== Refresh Tokens ==========

/**
 * Create a refresh token
 * @param {Object} tokenData - Token data
 * @returns {Promise<Object>} Created token
 */
export const createRefreshToken = async (tokenData) => {
  const { userId, token, expiresAt, userAgent = null, ipAddress = null } = tokenData;
  const tokenHash = hashToken(token);

  const res = await pool.query(
    `INSERT INTO refresh_tokens (
      user_id, token_hash, expires_at, user_agent, ip_address, created_at
    )
    VALUES ($1, $2, $3, $4, $5, NOW())
    RETURNING *`,
    [userId, tokenHash, expiresAt, userAgent, ipAddress]
  );

  return res.rows[0];
};

/**
 * Atomically create a replacement refresh token and revoke the used token.
 * The insert happens in the same transaction as the revoke, so a failed
 * replacement does not consume the user's current session.
 *
 * @param {Object} tokenData - Rotation data
 * @returns {Promise<Object>} Created replacement token
 */
export const rotateRefreshToken = async (tokenData) => {
  const {
    userId,
    oldToken,
    newToken,
    expiresAt,
    userAgent = null,
    ipAddress = null,
  } = tokenData;
  const oldTokenHash = hashToken(oldToken);
  const newTokenHash = hashToken(newToken);
  const client = await pool.connect();
  let transactionOpen = false;

  try {
    await client.query("BEGIN");
    transactionOpen = true;

    // Serialize rotations for the same token. This closes the race where two
    // requests both observe an active token and each mint a valid child.
    const current = await client.query(
      `SELECT id, family_id, revoked_at, expires_at
       FROM refresh_tokens
       WHERE user_id = $1 AND token_hash = $2
       LIMIT 1
       FOR UPDATE`,
      [userId, oldTokenHash]
    );

    const currentToken = current.rows[0];
    if (!currentToken || new Date(currentToken.expires_at) <= new Date()) {
      const error = new Error("Refresh token already used or invalid");
      error.code = "REFRESH_TOKEN_ROTATION_CONFLICT";
      throw error;
    }

    if (currentToken.revoked_at) {
      // A rotated token was presented again. Revoke the complete family in
      // this transaction so any child held by either party stops refreshing.
      await client.query(
        `UPDATE refresh_tokens
         SET revoked_at = COALESCE(revoked_at, NOW())
         WHERE user_id = $1 AND family_id = $2`,
        [userId, currentToken.family_id]
      );
      await client.query(
        `UPDATE refresh_tokens
         SET replay_detected_at = COALESCE(replay_detected_at, NOW())
         WHERE id = $1`,
        [currentToken.id]
      );
      await client.query("COMMIT");
      transactionOpen = false;

      const error = new Error("Refresh token replay detected");
      error.code = "REFRESH_TOKEN_REPLAY_DETECTED";
      throw error;
    }

    const created = await client.query(
      `INSERT INTO refresh_tokens (
        user_id, token_hash, expires_at, user_agent, ip_address,
        family_id, parent_token_id, created_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, NOW())
      RETURNING *`,
      [
        userId,
        newTokenHash,
        expiresAt,
        userAgent,
        ipAddress,
        currentToken.family_id,
        currentToken.id,
      ]
    );

    const revoked = await client.query(
      `UPDATE refresh_tokens
       SET revoked_at = NOW(), replaced_by_token_id = $2
       WHERE id = $1
         AND revoked_at IS NULL
         AND expires_at > NOW()
       RETURNING id`,
      [currentToken.id, created.rows[0].id]
    );

    if (revoked.rowCount !== 1) {
      const error = new Error("Refresh token already used or invalid");
      error.code = "REFRESH_TOKEN_ROTATION_CONFLICT";
      throw error;
    }

    await client.query("COMMIT");
    transactionOpen = false;
    return created.rows[0];
  } catch (error) {
    if (transactionOpen) {
      await client.query("ROLLBACK");
    }
    throw error;
  } finally {
    client.release();
  }
};

/**
 * Find refresh token
 * @param {number} userId - User ID
 * @param {string} token - Token value
 * @returns {Promise<Object|null>} Token or null
 */
export const findRefreshToken = async (userId, token) => {
  const tokenHash = hashToken(token);
  const res = await pool.query(
    `SELECT * FROM refresh_tokens
     WHERE user_id = $1 AND token_hash = $2
     LIMIT 1`,
    [userId, tokenHash]
  );
  return res.rows[0] || null;
};

/**
 * Record replay of a revoked token and revoke every token in its family.
 * This fast path runs before controller-level Firebase checks; rotation still
 * repeats the check under FOR UPDATE to cover concurrent refresh requests.
 */
export const revokeRefreshTokenFamilyForReplay = async (userId, token) => {
  const tokenHash = hashToken(token);
  const client = await pool.connect();

  try {
    await client.query("BEGIN");
    const replayed = await client.query(
      `SELECT id, family_id
       FROM refresh_tokens
       WHERE user_id = $1 AND token_hash = $2 AND revoked_at IS NOT NULL
       LIMIT 1
       FOR UPDATE`,
      [userId, tokenHash]
    );

    if (replayed.rows[0]) {
      await client.query(
        `UPDATE refresh_tokens
         SET revoked_at = COALESCE(revoked_at, NOW())
         WHERE user_id = $1 AND family_id = $2`,
        [userId, replayed.rows[0].family_id]
      );
      await client.query(
        `UPDATE refresh_tokens
         SET replay_detected_at = COALESCE(replay_detected_at, NOW())
         WHERE id = $1`,
        [replayed.rows[0].id]
      );
    }

    await client.query("COMMIT");
    return Boolean(replayed.rows[0]);
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
  }
};

/**
 * Revoke a refresh token
 * @param {number} userId - User ID
 * @param {string} token - Token value
 */
export const revokeRefreshToken = async (userId, token) => {
  const tokenHash = hashToken(token);
  await pool.query(
    `UPDATE refresh_tokens
     SET revoked_at = NOW()
     WHERE user_id = $1 AND token_hash = $2 AND revoked_at IS NULL`,
    [userId, tokenHash]
  );
};

/**
 * Revoke all refresh tokens for a user
 * @param {number} userId - User ID
 */
export const revokeAllUserTokens = async (userId) => {
  await pool.query(
    `UPDATE refresh_tokens
     SET revoked_at = NOW()
     WHERE user_id = $1 AND revoked_at IS NULL`,
    [userId]
  );
};

/**
 * Delete expired tokens
 */
export const deleteExpiredTokens = async () => {
  await pool.query(
    `DELETE FROM refresh_tokens
     WHERE expires_at < NOW() OR revoked_at < NOW() - INTERVAL '30 days'`
  );
};

// ========== Email Verification Tokens ==========

/**
 * Create email verification token
 * @param {number} userId - User ID
 * @param {string} token - Token value
 * @param {Date} expiresAt - Expiration date
 * @returns {Promise<Object>} Created token
 */
export const createEmailVerificationToken = async (userId, token, expiresAt) => {
  const tokenHash = hashToken(token);

  // Delete any existing verification tokens for this user
  await pool.query(
    "DELETE FROM email_verification_tokens WHERE user_id = $1",
    [userId]
  );

  const res = await pool.query(
    `INSERT INTO email_verification_tokens (
      user_id, token_hash, token_expires_at, created_at
    )
    VALUES ($1, $2, $3, NOW())
    RETURNING *`,
    [userId, tokenHash, expiresAt]
  );

  return res.rows[0];
};

/**
 * Find user by verification token
 * @param {string} token - Token value
 * @returns {Promise<Object|null>} User data or null
 */
export const findUserByVerificationToken = async (token) => {
  const tokenHash = hashToken(token);
  const res = await pool.query(
    `SELECT
      evt.id as token_id,
      evt.user_id,
      evt.token_expires_at,
      evt.consumed_at,
      u.id,
      u.email,
      u.name,
      u.email_verified
    FROM email_verification_tokens evt
    JOIN users u ON u.id = evt.user_id
    WHERE evt.token_hash = $1
      AND evt.consumed_at IS NULL
      AND evt.token_expires_at > NOW()
    LIMIT 1`,
    [tokenHash]
  );
  return res.rows[0] || null;
};

/**
 * Consume (mark as used) a verification token
 * @param {string} token - Token value
 */
export const consumeVerificationToken = async (token) => {
  const tokenHash = hashToken(token);
  await pool.query(
    `UPDATE email_verification_tokens
     SET consumed_at = NOW()
     WHERE token_hash = $1 AND consumed_at IS NULL`,
    [tokenHash]
  );
};

/**
 * Delete verification tokens for a user
 * @param {number} userId - User ID
 */
export const deleteVerificationTokensForUser = async (userId) => {
  await pool.query(
    "DELETE FROM email_verification_tokens WHERE user_id = $1",
    [userId]
  );
};
