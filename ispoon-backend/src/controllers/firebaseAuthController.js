import { pool } from "../config/db.js";
import {
  getFirebaseAuth,
  generateFirebaseVerificationLink
} from "../config/firebaseAdmin.js";
import { generateAuthTokens } from "../services/token.service.js";
import { sendWelcomeEmail } from "../services/email.service.js";
import { findById, deleteUser } from "../repositories/user.repository.js";
import logger from "../utils/logger.js";
import { validateRecentFirebaseProof } from "../services/firebaseReauth.service.js";
import UserService from "../services/userService.js";

/**
 * Verify Firebase ID Token and Create/Update User in Database
 * 
 * AUTH FLOW:
 * 1. Flutter App calls POST /api/auth/firebase/verify with Firebase idToken
 * 2. This function verifies the token with Firebase Admin SDK
 * 3. Extracts user info: uid, email, name, picture, providerId, emailVerified
 * 4. Upserts user in PostgreSQL (finds by firebase_uid or email, or creates new)
 * 5. For email/password auth: requires emailVerified = true (returns 403 if not)
 * 6. For Google OAuth: auto-marks as verified
 * 7. Generates backend JWT tokens (accessToken + refreshToken)
 * 8. Returns { token, tokens, user } to Flutter app
 * 
 * CALLED BY: Flutter auth_service.dart → verifyFirebaseToken()
 * NEXT STEP: Flutter stores tokens in SecureStorage → navigates to HomePage
 * 
 * @param {Request} req - Express request with body.idToken
 * @param {Response} res - Express response
 */
export const verifyFirebaseToken = async (req, res) => {
  try {
    const { idToken } = req.body || {};
    if (!idToken || typeof idToken !== "string") {
      return res.status(400).json({ message: "idToken is required" });
    }

    const auth = getFirebaseAuth();
    // This is a session-issuing endpoint, so honor Firebase revocation and
    // disabled-user state before minting a long-lived backend refresh token.
    const decoded = await auth.verifyIdToken(idToken, true);

    const firebaseUid = decoded.uid;
    let email = decoded.email || null;
    let name = decoded.name || null;
    let picture = decoded.picture || null;
    let providerId = Array.isArray(decoded.firebase?.sign_in_provider)
      ? decoded.firebase.sign_in_provider[0]
      : decoded.firebase?.sign_in_provider || null;
    let emailVerified = !!decoded.email_verified;

    // Enrich from Admin SDK if claims are missing (common for email/password right after signup)
    if (!name || !picture || !email || !emailVerified) {
      try {
        const userRec = await auth.getUser(firebaseUid);
        email = email || userRec.email || null;
        name = name || userRec.displayName || null;
        picture = picture || userRec.photoURL || null;
        emailVerified = emailVerified || !!userRec.emailVerified;
      } catch (_) { }
    }

    // Force email to lowercase to ensure consistent linking
    if (email) {
      email = email.toLowerCase();
    }

    if (!email) {
      return res.status(400).json({ message: "A verified email is required" });
    }

    // Never mutate/link a database identity from an unverified email claim.
    // The verification-email endpoint remains available with the Firebase
    // token, and the user can retry this exchange after verification.
    if (!emailVerified) {
      return res.status(403).json({
        message: "Email not verified. Please check your inbox and verify your email address.",
        requiresVerification: true,
        provider: providerId || 'firebase',
      });
    }

    // Upsert user in Postgres
    let userRow = null;
    // Try by firebase_uid first
    const byUid = await pool.query("SELECT * FROM users WHERE firebase_uid = $1", [firebaseUid]);
    if (byUid.rows.length > 0) {
      userRow = byUid.rows[0];
      // Update basic profile if changed
      await pool.query(
        `UPDATE users
         SET email = COALESCE($1, email),
             name = COALESCE($2, name),
             avatar_url = COALESCE($3, avatar_url),
             auth_provider = COALESCE($4, auth_provider),
             email_verified = email_verified OR $5,
             updated_at = NOW()
         WHERE id = $6`,
        [email, name, picture, providerId, emailVerified, userRow.id]
      );
      const refreshed = await pool.query("SELECT * FROM users WHERE id = $1", [userRow.id]);
      userRow = refreshed.rows[0];
    } else if (email) {
      // fallback: try by email
      const byEmail = await pool.query("SELECT * FROM users WHERE email = $1", [email.toLowerCase()]);
      if (byEmail.rows.length > 0) {
        userRow = byEmail.rows[0];
        if (userRow.firebase_uid && userRow.firebase_uid !== firebaseUid) {
          logger.warn('[verifyFirebaseToken] blocked conflicting Firebase account link', {
            userId: userRow.id,
            firebaseUid,
            providerId,
          });
          return res.status(409).json({
            message: "This email is already linked to another account.",
          });
        }
        const linked = await pool.query(
          `UPDATE users
           SET firebase_uid = $1,
               name = COALESCE($2, name),
               avatar_url = COALESCE($3, avatar_url),
               auth_provider = COALESCE($4, auth_provider),
               email_verified = email_verified OR $5,
               updated_at = NOW()
           WHERE id = $6
             AND (firebase_uid IS NULL OR firebase_uid = $1)
           RETURNING *`,
          [firebaseUid, name, picture, providerId, emailVerified, userRow.id]
        );
        if (!linked.rows[0]) {
          return res.status(409).json({
            message: "This email is already linked to another account.",
          });
        }
        userRow = linked.rows[0];
      }
    }

    if (!userRow) {
      const inserted = await pool.query(
        `INSERT INTO users (email, name, firebase_uid, avatar_url, auth_provider, email_verified, created_at, updated_at)
         VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW()) RETURNING *`,
        [email, name, firebaseUid, picture, providerId, emailVerified]
      );
      userRow = inserted.rows[0];
    }

    // Determine the current sign-in method from the live Firebase token.
    // providerId from the token reflects what was used THIS sign-in (e.g. 'google.com', 'password').
    // userRow.auth_provider reflects the original/primary provider stored in DB.
    const currentSignInProvider = providerId || userRow.auth_provider;

    logger.info(`[verifyFirebaseToken] uid=${firebaseUid} currentProvider=${currentSignInProvider} emailVerified=${emailVerified} db.email_verified=${userRow.email_verified} db.auth_provider=${userRow.auth_provider}`);

    if (emailVerified) {
      // ✅ Firebase already confirmed the email is verified — allow through for ALL providers.
      // This covers: Google OAuth (always verified), email/password (user clicked verify link),
      // and cross-provider cases (Google user who also set a password).
      if (!userRow.email_verified) {
        await pool.query(
          'UPDATE users SET email_verified = true, updated_at = NOW() WHERE id = $1',
          [userRow.id]
        );
        userRow.email_verified = true;
      }
    } else if (currentSignInProvider === 'password' || currentSignInProvider === 'firebase') {
      // ❌ Email/password sign-in with unverified email — block login.
      // Check DB too: if the user previously verified via Google (same email account),
      // trust the DB value and allow through.
      if (!userRow.email_verified) {
        return res.status(403).json({
          message: "Email not verified. Please check your inbox and verify your email address.",
          requiresVerification: true,
          provider: 'firebase',
        });
      }
    } else if (!userRow.email_verified) {
      // Other OAuth providers that haven't verified — block.
      return res.status(403).json({
        message: "Email not verified. Please verify your email with your authentication provider.",
        requiresVerification: true,
        provider: currentSignInProvider,
      });
    }

    // Welcome email: claim the send flag first so concurrent logins cannot
    // double-send. Only deliver when this request won the claim.
    if (userRow.email_verified && !userRow.welcome_email_sent) {
      try {
        const claimed = await pool.query(
          `UPDATE users
           SET welcome_email_sent = true,
               welcome_email_sent_at = NOW(),
               updated_at = NOW()
           WHERE id = $1 AND welcome_email_sent = false
           RETURNING id`,
          [userRow.id]
        );
        if (claimed.rows.length > 0) {
          logger.info('Sending welcome email', { userId: userRow.id });
          try {
            await sendWelcomeEmail({ email: userRow.email, name: userRow.name });
            logger.info('Welcome email sent', { userId: userRow.id });
          } catch (sendError) {
            await pool.query(
              `UPDATE users
               SET welcome_email_sent = false,
                   welcome_email_sent_at = NULL,
                   updated_at = NOW()
               WHERE id = $1`,
              [userRow.id],
            );
            throw sendError;
          }
        }
      } catch (emailError) {
        // Log but don't block login if email delivery fails
        logger.error('Failed to send welcome email', { userId: userRow.id, error: emailError });
      }
    }

    const tokens = await generateAuthTokens(userRow, {
      userAgent: req.get("user-agent"),
      ipAddress: req.ip,
    });

    return res.json({
      token: tokens.accessToken,
      tokens,
      user: {
        id: userRow.id,
        email: userRow.email,
        name: userRow.name,
        avatar_url: userRow.avatar_url,
        firebase_uid: userRow.firebase_uid,
        auth_provider: userRow.auth_provider,
        email_verified: userRow.email_verified,
        created_at: userRow.created_at,
      },
    });
  } catch (err) {
    const msg = String(err?.message || "");
    const isAuth = /id token|auth|credential|parse private key|pem/i.test(msg);
    logger.error('verifyFirebaseToken failed', { error: err });
    const status = isAuth ? 401 : 500;
    return res.status(status).json({ message: isAuth ? "Invalid Firebase ID token" : "Internal error" });
  }
};

/**
 * Request Email Verification for Firebase Users
 * 
 * Sends a verification email to users who signed up with email/password.
 * This endpoint triggers Firebase to send the verification email directly.
 * 
 * AUTH FLOW:
 * 1. Flutter App calls POST /api/auth/firebase/request-email-verification with idToken
 * 2. This function verifies the token with Firebase Admin SDK
 * 3. Checks if email is already verified (returns 400 if yes)
 * 4. Generates Firebase verification link via Admin SDK
 * 5. Firebase sends verification email to user
 * 6. Returns success message to Flutter app
 * 
 * CALLED BY: Flutter login_screen.dart → _sendEmailVerificationLink()
 *            (via firebase_auth_service.dart → sendEmailVerificationLink())
 * 
 * @param {Request} req - Express request with body.idToken
 * @param {Response} res - Express response
 */
export const requestEmailVerification = async (req, res) => {
  try {
    const { idToken } = req.body || {};

    if (!idToken || typeof idToken !== "string") {
      return res.status(400).json({ message: "idToken is required" });
    }

    const auth = getFirebaseAuth();
    const decoded = await auth.verifyIdToken(idToken, true);

    // Check if already verified
    if (decoded.email_verified) {
      return res.status(400).json({
        message: "Email is already verified",
        verified: true
      });
    }

    const email = decoded.email;
    if (!email) {
      return res.status(400).json({
        message: "No email associated with this account"
      });
    }

    // Generate verification link and send email using Firebase Admin SDK
    try {
      // generateFirebaseVerificationLink returns a URL
      // Firebase Admin SDK's generateEmailVerificationLink creates the link
      // but does NOT send the email automatically — we need to send it ourselves
      const verificationLink = await generateFirebaseVerificationLink(email);

      // Send the verification email via our email service
      const { sendVerificationEmail } = await import("../services/email.service.js");
      await sendVerificationEmail({ email, verificationLink });

      return res.json({
        message: "Verification email sent. Please check your inbox.",
        email: email,
        sent: true
      });
    } catch (linkError) {
      logger.error('Failed to generate/send verification link', { error: linkError });
      return res.status(500).json({
        message: "Failed to send verification email. Please try again later."
      });
    }
  } catch (err) {
    const msg = String(err?.message || "");
    const isAuth = /id token|auth|credential|parse private key|pem/i.test(msg);
    logger.error('requestEmailVerification failed', { error: err });
    const status = isAuth ? 401 : 500;
    return res.status(status).json({
      message: isAuth ? "Invalid Firebase ID token" : "Internal error"
    });
  }
};

/**
 * Delete Account (Firebase + Postgres)
 *
 * Permanently deletes the authenticated user's account. Required for App Store
 * compliance (Guideline 5.1.1(v) — apps that support account creation must also
 * support in-app account deletion).
 *
 * DELETION ORDER (and rationale):
 * 1. Look up the user's firebase_uid from Postgres via req.user.id (from JWT).
 * 2. Verify a second, revoked-checked Firebase ID token for that exact UID and
 *    require its auth_time to be no more than five minutes old.
 * 3. Delete the Firebase Auth user first. If a concurrent deletion removes it
 *    after proof verification, treat that as success. Any other Firebase error aborts the
 *    request before we touch Postgres, so we never end up with a deleted
 *    Postgres row but a still-active Firebase identity (which would let the
 *    user keep signing in to a "ghost" account with no backend data).
 * 4. Only after Firebase deletion (or confirmed absence) succeeds, delete the
 *    Postgres user row. The DB schema cascades (ON DELETE CASCADE) so all
 *    related rows (meals, devices, sessions, etc.) are removed automatically.
 *
 * PARTIAL FAILURE BEHAVIOR:
 * - If the Firebase delete fails for a reason other than "already deleted"
 *   (network error, permission error, etc.), we abort with 500 and do NOT
 *   touch Postgres. The user's account remains fully intact in both systems,
 *   so they can simply retry — no orphaned state is created.
 * - If Firebase deletion succeeds but the subsequent Postgres delete throws,
 *   we log this loudly as a CRITICAL inconsistency (Firebase identity is gone,
 *   but the Postgres row — and the user's data — still exists, so the user can
 *   no longer log in to reach it). We still return an error to the client
 *   rather than claiming success, since the user's data was NOT actually
 *   erased. This case needs manual/ops follow-up (rerun deleteUser for that id),
 *   which is why it's logged at error level with the userId and firebaseUid.
 *
 * CALLED BY: Flutter auth_service.dart → deleteAccount()
 *
 * @param {Request} req - Express request, authenticated via `protect` (req.user.id)
 * @param {Response} res - Express response
 */
export const deleteAccount = async (req, res) => {
  const userId = req.user?.id;
  try {
    const user = await findById(userId);
    if (!user) {
      return res.status(404).json({ message: "User not found" });
    }

    const firebaseUid = user.firebase_uid;

    if (!firebaseUid) {
      logger.error("deleteAccount: account has no Firebase identity", { userId });
      return res.status(409).json({
        message: "Account identity is not linked. Please contact support.",
      });
    }

    const auth = getFirebaseAuth();
    try {
      const proof = await auth.verifyIdToken(req.body.idToken, true);
      validateRecentFirebaseProof(proof, firebaseUid);
    } catch (proofError) {
      if (proofError?.statusCode) {
        return res.status(proofError.statusCode).json({
          message: proofError.message,
          ...(proofError.data ? { error: proofError.data } : {}),
        });
      }
      if (/^auth\/(?:argument-error|id-token-expired|id-token-revoked|invalid-id-token|user-disabled|user-not-found)$/.test(proofError?.code || "")) {
        return res.status(401).json({
          message: "Invalid Firebase re-authentication proof",
        });
      }
      logger.error("deleteAccount: Firebase proof verification failed", {
        userId,
        firebaseUid,
        error: proofError,
      });
      return res.status(500).json({
        message: "Unable to verify your identity. Please try again.",
      });
    }

    try {
      await auth.deleteUser(firebaseUid);
    } catch (fbErr) {
      if (fbErr?.code === "auth/user-not-found") {
        // The proof was already verified and bound above. A concurrent delete
        // reaching this point is therefore safe to treat as idempotent.
        logger.warn("deleteAccount: Firebase user already absent", {
          userId,
          firebaseUid,
        });
      } else {
        logger.error("deleteAccount: Firebase deletion failed, aborting before Postgres delete", {
          userId,
          firebaseUid,
          error: fbErr,
        });
        return res.status(500).json({
          message: "Failed to delete account. Please try again.",
        });
      }
    }

    try {
      await deleteUser(userId);
    } catch (dbErr) {
      // CRITICAL: Firebase identity is already gone but Postgres row survived.
      // The user can no longer sign in, but their data still exists in Postgres.
      // Needs manual/ops follow-up — log with full context for that.
      logger.error("deleteAccount: CRITICAL — Firebase user deleted but Postgres delete failed; orphaned DB row", {
        userId,
        firebaseUid,
        error: dbErr,
      });
      return res.status(500).json({
        message: "Account deletion partially failed. Please contact support.",
      });
    }

    try {
      await UserService.deleteUserFiles(userId, user.avatar_url);
    } catch (fileError) {
      // The account and database rows are already deleted. Log storage cleanup
      // for operations without incorrectly telling the user deletion failed.
      logger.error("deleteAccount: user upload cleanup failed", {
        userId,
        error: fileError,
      });
    }

    logger.info("deleteAccount: account deleted successfully", { userId, firebaseUid });
    return res.json({ message: "Account deleted successfully" });
  } catch (err) {
    logger.error("deleteAccount failed", { userId, error: err });
    return res.status(500).json({ message: "Failed to delete account. Please try again." });
  }
};

