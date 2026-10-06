import express from "express";
import {
    verifyFirebaseToken,
    requestEmailVerification,
    deleteAccount,
} from "../controllers/firebaseAuthController.js";
import { protect } from "../middleware/authMiddleware.js";
import {
    revokeRefreshToken,
    revokeAllUserTokens,
    rotateRefreshToken,
    verifyRefreshToken,
} from "../services/token.service.js";
import { findById } from "../repositories/user.repository.js";
import { getFirebaseAuth } from "../config/firebaseAdmin.js";
import { removeFCMToken } from "../models/notificationModel.js";
import { AppError } from "../utils/errors.js";
import { validateRequest } from "../middleware/validateRequest.js";
import {
    firebaseIdTokenSchema,
    logoutRequestSchema,
    refreshTokenRequestSchema,
    deleteAccountSchema,
} from "../validators/auth.schema.js";

const router = express.Router();

/**
 * Firebase Authentication Routes
 * All authentication is handled by Firebase on the client side.
 * These endpoints verify Firebase tokens and sync users to our database.
 */

// Verify Firebase ID token and create/update user in database
// Returns our JWT tokens for API authentication
router.post("/firebase/verify", validateRequest(firebaseIdTokenSchema), verifyFirebaseToken);

// Request email verification (triggers Firebase to send verification email)
router.post(
    "/firebase/request-email-verification",
    validateRequest(firebaseIdTokenSchema),
    requestEmailVerification,
);

// Logout - revoke refresh token. The refresh token authenticates this action,
// so logout still works when the short-lived access token is expired.
router.post("/logout", validateRequest(logoutRequestSchema), async (req, res) => {
    try {
        const refreshToken = req.body?.refreshToken || req.headers["x-refresh-token"];
        if (!refreshToken) {
            return res.status(400).json({ message: "refreshToken is required" });
        }
        const userId = await revokeRefreshToken(refreshToken);
        if (userId && req.body?.fcmToken) {
            await removeFCMToken(req.body.fcmToken, userId);
        }
        res.json({ message: "Logged out successfully" });
    } catch (err) {
        res.status(500).json({ message: "Logout failed" });
    }
});

// Refresh session - rotate refresh token and return a fresh token pair.
router.post("/refresh", validateRequest(refreshTokenRequestSchema), async (req, res) => {
    try {
        const incomingToken = req.body?.refreshToken || req.headers["x-refresh-token"];
        if (!incomingToken) {
            return res.status(400).json({ message: "refreshToken is required" });
        }

        const verified = await verifyRefreshToken(incomingToken);
        const user = await findById(verified.id);
        if (!user) {
            return res.status(404).json({ message: "User not found" });
        }

        if (!user.firebase_uid) {
            await revokeAllUserTokens(user.id);
            throw new AppError("Session is no longer valid", 401);
        }

        // Keep backend sessions aligned with Firebase disable/revoke events.
        // Firebase checks happen only on refresh, not on every API request.
        let firebaseUser;
        try {
            firebaseUser = await getFirebaseAuth().getUser(user.firebase_uid);
        } catch (error) {
            if (error?.code === 'auth/user-not-found') {
                await revokeAllUserTokens(user.id);
                throw new AppError("Session is no longer valid", 401);
            }
            throw error;
        }
        const validAfterMs = firebaseUser.tokensValidAfterTime
            ? Date.parse(firebaseUser.tokensValidAfterTime)
            : 0;
        if (firebaseUser.disabled || (validAfterMs && verified.iat * 1000 < validAfterMs)) {
            await revokeAllUserTokens(user.id);
            throw new AppError("Session is no longer valid", 401);
        }

        const tokens = await rotateRefreshToken(user, verified, {
            userAgent: req.get("user-agent"),
            ipAddress: req.ip,
        });

        res.json({
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresIn: tokens.expiresIn,
            user: {
                id: user.id,
                email: user.email,
                name: user.name,
                avatar_url: user.avatar_url,
                firebase_uid: user.firebase_uid,
                email_verified: user.email_verified,
            },
        });
    } catch (err) {
        const status = err.statusCode || 500;
        res.status(status).json({
            message: status === 500
                ? "Unable to refresh session"
                : err.message || "Invalid refresh token",
        });
    }
});

// Protected route to get current user info
router.get("/me", protect, async (req, res, next) => {
    try {
        const user = await findById(req.user.id);
        if (!user) {
            return res.status(404).json({ message: "User not found" });
        }
        res.json({
            id: user.id,
            email: user.email,
            name: user.name,
            avatar_url: user.avatar_url,
            firebase_uid: user.firebase_uid,
            email_verified: user.email_verified,
            auth_provider: user.auth_provider,
            created_at: user.created_at,
        });
    } catch (err) {
        next(err);
    }
});

// Delete account - permanently deletes the authenticated user from Firebase + Postgres
// Required for App Store compliance (Guideline 5.1.1(v))
router.delete("/me", protect, validateRequest(deleteAccountSchema), deleteAccount);

export default router;
