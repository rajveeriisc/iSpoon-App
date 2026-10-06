import { AppError } from "../utils/errors.js";

export const DESTRUCTIVE_AUTH_MAX_AGE_SECONDS = 5 * 60;
const CLOCK_SKEW_SECONDS = 60;

/**
 * Validate that a Firebase ID token proves a recent authentication for the
 * exact Firebase identity linked to the backend account.
 */
export const validateRecentFirebaseProof = (
  decodedToken,
  expectedFirebaseUid,
  nowSeconds = Math.floor(Date.now() / 1000),
) => {
  if (!decodedToken || decodedToken.uid !== expectedFirebaseUid) {
    throw new AppError("Re-authentication does not match this account", 403);
  }

  const authTime = Number(decodedToken.auth_time);
  if (!Number.isSafeInteger(authTime) || authTime <= 0) {
    throw new AppError("Recent re-authentication is required", 401, {
      code: "RECENT_LOGIN_REQUIRED",
    });
  }

  const ageSeconds = nowSeconds - authTime;
  if (ageSeconds < -CLOCK_SKEW_SECONDS || ageSeconds > DESTRUCTIVE_AUTH_MAX_AGE_SECONDS) {
    throw new AppError("Recent re-authentication is required", 401, {
      code: "RECENT_LOGIN_REQUIRED",
    });
  }

  return decodedToken;
};
