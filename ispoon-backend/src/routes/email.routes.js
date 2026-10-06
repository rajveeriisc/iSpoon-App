import express from 'express';
import rateLimit from 'express-rate-limit';
import { sendWelcomeEmail } from '../services/email.service.js';
import { protect } from '../middleware/authMiddleware.js';
import { pool } from '../config/db.js';
import logger from '../utils/logger.js';

const router = express.Router();

// Uniform response for every welcome-email call so an attacker can't tell
// whether an account exists / whether an email was actually sent.
const GENERIC_OK = { message: 'Request received' };

const isDev = process.env.NODE_ENV !== 'production';
const welcomeLimiter = rateLimit({
    windowMs: 60 * 60 * 1000,
    max: isDev ? 100 : 5,
    keyGenerator: (req) => (req.user?.id ? `welcome:${req.user.id}` : req.ip),
    message: GENERIC_OK,
    standardHeaders: true,
    legacyHeaders: false,
});

/**
 * Send Welcome Email — authenticated + rate limited.
 * Note: the primary welcome-email trigger is server-side in
 * firebaseAuthController (on first verified login). This endpoint is a
 * best-effort manual re-trigger and always returns a uniform response.
 */
router.post('/welcome', protect, welcomeLimiter, async (req, res) => {
    // Only ever act on the caller's OWN email (from the verified JWT) — never a
    // body-supplied address — so this can't enumerate or spam other accounts.
    const email = (req.user?.email || '').toLowerCase();
    const name = req.body?.name;

    try {
        if (email) {
            const claimed = await pool.query(
                `UPDATE users
                 SET welcome_email_sent = true,
                     welcome_email_sent_at = NOW(),
                     updated_at = NOW()
                 WHERE email = $1 AND welcome_email_sent = false
                 RETURNING id`,
                [email]
            );
            if (claimed.rows[0]) {
                try {
                    await sendWelcomeEmail({ email, name: name || email.split('@')[0] });
                    logger.info('Welcome email sent', { context: 'EmailRoutes', userId: claimed.rows[0].id });
                } catch (sendError) {
                    await pool.query(
                        `UPDATE users
                         SET welcome_email_sent = false,
                             welcome_email_sent_at = NULL,
                             updated_at = NOW()
                         WHERE id = $1`,
                        [claimed.rows[0].id],
                    );
                    throw sendError;
                }
            }
        }
    } catch (error) {
        // Email is not critical — log server-side, never leak detail to client.
        logger.error('Welcome email endpoint error', { context: 'EmailRoutes', error: error.message });
    }

    // Always the same response regardless of outcome.
    return res.status(200).json(GENERIC_OK);
});

export default router;
