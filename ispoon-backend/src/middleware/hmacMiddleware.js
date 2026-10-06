import crypto from 'crypto';
import logger from '../utils/logger.js';

// In a real production environment, this secret should be securely injected via ENV or KMS
// For this implementation, we are using a hardcoded secret as discussed in the implementation plan.
const HMAC_SECRET = process.env.HMAC_SECRET || 'smartspoon_hmac_secret_2026';

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
      .createHmac('sha256', HMAC_SECRET)
      .update(bodyString)
      .digest('hex');

    if (signature !== expectedSignature) {
      logger.warn('Invalid API signature', { context: 'Security', ip: req.ip });
      return res.status(401).json({ success: false, message: 'Invalid API signature' });
    }

    next();
  } catch (error) {
    logger.error('HMAC verification failed', { context: 'Security', error: error.message });
    return res.status(500).json({ success: false, message: 'Internal server error during signature verification' });
  }
};
