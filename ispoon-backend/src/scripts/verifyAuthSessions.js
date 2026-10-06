import "dotenv/config";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

import { pool } from "../config/db.js";
import {
  generateAuthTokens,
  rotateRefreshToken,
  verifyRefreshToken,
} from "../services/token.service.js";

const run = async () => {
  if (
    /neon\.tech/i.test(process.env.DATABASE_URL || '') &&
    process.env.ALLOW_LIVE_DB !== '1'
  ) {
    throw new Error(
      'Refusing to mint session fixtures against Neon. Set ALLOW_LIVE_DB=1 only on a throwaway database.',
    );
  }
  let userId;
  try {
    const suffix = randomUUID();
    const inserted = await pool.query(
      `INSERT INTO users (email, name, firebase_uid, email_verified)
       VALUES ($1, 'Session Integrity Check', $2, TRUE)
       RETURNING *`,
      [`session-${suffix}@example.invalid`, `session-${suffix}`],
    );
    const user = inserted.rows[0];
    userId = user.id;

    const rootTokens = await generateAuthTokens(user, { userAgent: "integrity-check" });
    const rootProof = await verifyRefreshToken(rootTokens.refreshToken);
    const replacement = await rotateRefreshToken(user, rootProof, {
      userAgent: "integrity-check",
    });

    await assert.rejects(
      verifyRefreshToken(rootTokens.refreshToken),
      (error) => error.statusCode === 401 &&
        error.data?.code === "REFRESH_TOKEN_REPLAY_DETECTED",
      "Reusing a rotated token must be detected as replay",
    );
    await assert.rejects(
      verifyRefreshToken(replacement.refreshToken),
      (error) => error.statusCode === 401,
      "Replay must revoke the replacement token too",
    );

    const family = await pool.query(
      `SELECT
         COUNT(*) AS token_count,
         COUNT(*) FILTER (WHERE revoked_at IS NOT NULL) AS revoked_count,
         COUNT(*) FILTER (WHERE replay_detected_at IS NOT NULL) AS replay_count,
         COUNT(DISTINCT family_id) AS family_count
       FROM refresh_tokens
       WHERE user_id = $1`,
      [userId],
    );
    const counts = family.rows[0];
    assert.equal(Number(counts.token_count), 2);
    assert.equal(Number(counts.revoked_count), 2);
    assert.equal(Number(counts.replay_count), 2);
    assert.equal(Number(counts.family_count), 1);

    console.log(JSON.stringify({
      rotation: "passed",
      replayDetection: "passed",
      familyRevocation: "passed",
      tokensChecked: Number(counts.token_count),
    }, null, 2));
  } finally {
    if (userId !== undefined) {
      await pool.query("DELETE FROM users WHERE id = $1", [userId]);
    }
    await pool.end();
  }
};

run().catch((error) => {
  console.error(`Auth session verification failed: ${error.message}`);
  process.exitCode = 1;
});
