import crypto from 'crypto';
import logger from '../utils/logger.js';

// Request signing shared with the Flutter client (lib/core/services/resilient_http.dart).
//
// This value was previously hardcoded here AND in the client, and the literal
// was published to a public repository. A secret compiled into a mobile app is
// extractable from the APK regardless, so this layer is defence in depth
// against casual scripted traffic — the `protect` JWT middleware is the real
// authorisation boundary on every route this is mounted on. Treat it as such:
// never rely on it alone.
//
// Production must inject HMAC_SECRET (enforced in validateSecurityConfig at
// startup). Outside production we fall back to the well-known development
// value so local work keeps running, and say so loudly.
const DEV_FALLBACK_SECRET = 'smartspoon_hmac_secret_2026';

const resolveSecret = () => {
  const fromEnv = process.env.HMAC_SECRET;
  if (fromEnv) return fromEnv;

  if (process.env.NODE_ENV === 'production') {
    // validateSecurityConfig should have refused to boot. Fail closed instead
    // of silently signing with a value that is public.
    throw new Error('HMAC_SECRET is required in production');
  }
  return DEV_FALLBACK_SECRET;
};

export const verifyHmac = (req, res, next) => {
  // We only require HMAC signatures for state-mutating requests from the mobile app
  if (req.method === 'GET' || req.method === 'OPTIONS') {
    return next();
  }

  const signature = req.headers['x-signature'];
  if (!signature) {
    logger.warn('Missing X-Signature header', { context: 'Security', ip: req.ip });
    return res.status(401).json({ success: false, message: 'Missing API signature' });
  }

  try {
    // Stringify the body to generate the signature. Note: Body must be exactly as sent by the client.
    // Ensure body-parser is configured properly.
    const bodyString = Object.keys(req.body).length === 0 ? '' : JSON.stringify(req.body);
    const expectedSignature = crypto
      .createHmac('sha256', resolveSecret())
      .update(bodyString)
      .digest('hex');

    // Constant-time comparison. `!==` on the hex digests leaks how many leading
    // characters matched through its early exit, which is enough to recover a
    // valid signature byte by byte over many requests. timingSafeEqual throws
    // on a length mismatch, so screen the length first — that is not secret,
    // a SHA-256 hex digest is always 64 characters.
    const expectedBuf = Buffer.from(expectedSignature, 'utf8');
    const providedBuf = Buffer.from(String(signature), 'utf8');
    const signatureValid =
      providedBuf.length === expectedBuf.length &&
      crypto.timingSafeEqual(providedBuf, expectedBuf);

    if (!signatureValid) {
      logger.warn('Invalid API signature', { context: 'Security', ip: req.ip });
      return res.status(401).json({ success: false, message: 'Invalid API signature' });
    }

    next();
  } catch (error) {
    logger.error('HMAC verification failed', { context: 'Security', error: error.message });
    return res.status(500).json({ success: false, message: 'Internal server error during signature verification' });
  }
};
