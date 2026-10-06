import jwt from "jsonwebtoken";
import crypto from "crypto";
import * as tokenRepository from "../repositories/token.repository.js";
import { AppError } from "../utils/errors.js";
import { SECURITY_CONFIG } from "../config/security.js";

// No fallback literals: an unset secret must fail loudly (validated at startup
// in validateSecurityConfig) rather than silently sign tokens with a public,
// well-known default that would allow token forgery.
const ACCESS_TOKEN_SECRET = process.env.JWT_SECRET;
const REFRESH_TOKEN_SECRET = process.env.JWT_REFRESH_SECRET;
const ACCESS_TOKEN_EXPIRY =
  process.env.JWT_ACCESS_EXPIRY ||
  process.env.JWT_EXPIRY ||
  SECURITY_CONFIG.JWT.ACCESS_EXPIRES_IN ||
  "15m";
const REFRESH_TOKEN_EXPIRY = SECURITY_CONFIG.JWT.REFRESH_EXPIRES_IN || "30d";

const getRefreshTokenExpiresAt = () => new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);

const signAccessToken = (user) => jwt.sign(
  {
    id: user.id,
    email: user.email,
    type: "access",
  },
  ACCESS_TOKEN_SECRET,
  {
    algorithm: "HS256",
    expiresIn: ACCESS_TOKEN_EXPIRY,
    issuer: SECURITY_CONFIG.JWT.ISSUER,
    audience: SECURITY_CONFIG.JWT.AUDIENCE,
  }
);

const signRefreshToken = (userId, tokenValue) => jwt.sign(
  {
    id: userId,
    tokenValue,
    type: "refresh",
  },
  REFRESH_TOKEN_SECRET,
  {
    algorithm: "HS256",
    expiresIn: REFRESH_TOKEN_EXPIRY,
    issuer: SECURITY_CONFIG.JWT.ISSUER,
    audience: SECURITY_CONFIG.JWT.AUDIENCE,
  }
);

/**
 * Generate access and refresh tokens for a user
 * @param {Object} user - User object
 * @param {Object} context - Request context (IP, user agent)
 * @returns {Promise<Object>} Access and refresh tokens
 */
export const generateAuthTokens = async (user, context = {}) => {
  // Generate access token (short-lived)
  const accessToken = signAccessToken(user);

  // Generate refresh token (long-lived)
  const refreshTokenValue = crypto.randomBytes(32).toString("hex");
  const expiresAt = getRefreshTokenExpiresAt();

  // Store refresh token in database
  await tokenRepository.createRefreshToken({
    userId: user.id,
    token: refreshTokenValue,
    expiresAt,
    ipAddress: context.ipAddress,
    userAgent: context.userAgent,
  });

  const refreshToken = signRefreshToken(user.id, refreshTokenValue);

  return {
    accessToken,
    refreshToken,
    expiresIn: ACCESS_TOKEN_EXPIRY,
  };
};

/**
 * Rotate a verified refresh token and issue a fresh access/refresh pair.
 * @param {Object} user - User object
 * @param {Object} verifiedRefreshToken - Payload from verifyRefreshToken
 * @param {Object} context - Request context (IP, user agent)
 * @returns {Promise<Object>} Access and refresh tokens
 */
export const rotateRefreshToken = async (user, verifiedRefreshToken, context = {}) => {
  const refreshTokenValue = crypto.randomBytes(32).toString("hex");
  const expiresAt = getRefreshTokenExpiresAt();
  const accessToken = signAccessToken(user);
  const refreshToken = signRefreshToken(user.id, refreshTokenValue);

  try {
    await tokenRepository.rotateRefreshToken({
      userId: user.id,
      oldToken: verifiedRefreshToken.tokenValue,
      newToken: refreshTokenValue,
      expiresAt,
      ipAddress: context.ipAddress,
      userAgent: context.userAgent,
    });
  } catch (error) {
    if (
      error.code === "REFRESH_TOKEN_ROTATION_CONFLICT" ||
      error.code === "REFRESH_TOKEN_REPLAY_DETECTED"
    ) {
      throw new AppError("Refresh token already used or invalid", 401, {
        code: error.code,
      });
    }
    throw error;
  }

  return {
    accessToken,
    refreshToken,
    expiresIn: ACCESS_TOKEN_EXPIRY,
  };
};

/**
 * Verify access token
 * @param {string} token - JWT access token
 * @returns {Object} Decoded token payload
 */
export const verifyAccessToken = (token) => {
  try {
    const decoded = jwt.verify(token, ACCESS_TOKEN_SECRET, {
      issuer: SECURITY_CONFIG.JWT.ISSUER,
      audience: SECURITY_CONFIG.JWT.AUDIENCE,
      algorithms: ['HS256'],
    });
    if (decoded.type !== "access") {
      throw new AppError("Invalid token type", 401);
    }
    return decoded;
  } catch (error) {
    if (error.name === "TokenExpiredError") {
      const expired = new AppError("Token expired", 401, { code: "TOKEN_EXPIRED" });
      expired.name = "TokenExpiredError";
      throw expired;
    }
    if (error.name === "JsonWebTokenError") {
      const invalid = new AppError("Invalid token", 401, { code: "TOKEN_INVALID" });
      invalid.name = "JsonWebTokenError";
      throw invalid;
    }
    throw error;
  }
};

/**
 * Verify refresh token
 * @param {string} token - JWT refresh token
 * @returns {Promise<Object>} Decoded token payload
 */
export const verifyRefreshToken = async (token) => {
  try {
    const decoded = jwt.verify(token, REFRESH_TOKEN_SECRET, {
      issuer: SECURITY_CONFIG.JWT.ISSUER,
      audience: SECURITY_CONFIG.JWT.AUDIENCE,
      algorithms: ['HS256'],
    });
    if (decoded.type !== "refresh" || !decoded.tokenValue) {
      throw new AppError("Invalid token type", 401);
    }

    // Rotation performs the authoritative revoked-state check under a row
    // lock. Returning a revoked record here is intentional: it lets rotation
    // recognize replay and revoke the entire token family atomically.
    const storedToken = await tokenRepository.findRefreshToken(
      decoded.id,
      decoded.tokenValue
    );

    if (!storedToken) {
      throw new AppError("Token revoked or invalid", 401);
    }

    if (storedToken.revoked_at) {
      await tokenRepository.revokeRefreshTokenFamilyForReplay(
        decoded.id,
        decoded.tokenValue,
      );
      throw new AppError("Refresh token already used or invalid", 401, {
        code: "REFRESH_TOKEN_REPLAY_DETECTED",
      });
    }

    if (new Date() > new Date(storedToken.expires_at)) {
      throw new AppError("Token expired", 401);
    }

    return decoded;
  } catch (error) {
    if (error.name === "TokenExpiredError") {
      throw new AppError("Refresh token expired", 401);
    }
    if (error.name === "JsonWebTokenError") {
      throw new AppError("Invalid refresh token", 401);
    }
    throw error;
  }
};

/**
 * Revoke a refresh token
 * @param {string} token - JWT refresh token
 */
export const revokeRefreshToken = async (token) => {
  try {
    const decoded = jwt.verify(token, REFRESH_TOKEN_SECRET, {
      issuer: SECURITY_CONFIG.JWT.ISSUER,
      audience: SECURITY_CONFIG.JWT.AUDIENCE,
      algorithms: ['HS256'],
    });
    if (decoded.type !== "refresh" || !decoded.tokenValue) {
      return null;
    }
    await tokenRepository.revokeRefreshToken(decoded.id, decoded.tokenValue);
    return decoded.id;
  } catch (error) {
    // Silent fail for logout
    return null;
  }
};

/**
 * Revoke all refresh tokens for a user
 * @param {number} userId - User ID
 */
export const revokeAllUserTokens = async (userId) => {
  await tokenRepository.revokeAllUserTokens(userId);
};

/**
 * Clean up expired tokens
 */
export const cleanupExpiredTokens = async () => {
  await tokenRepository.deleteExpiredTokens();
};
