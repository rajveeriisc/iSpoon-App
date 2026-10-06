import { verifyAccessToken } from "../services/token.service.js";
import logger from "../utils/logger.js";

// Protect routes using JWT from Authorization header only
export const protect = (req, res, next) => {
  const authHeader = req.headers.authorization;

  if (!authHeader) {
    return res.status(401).json({ message: "No token provided" });
  }

  const bearerMatch = /^Bearer\s+(\S+)$/i.exec(authHeader);
  if (!bearerMatch) {
    return res.status(401).json({ message: "Invalid authorization header" });
  }

  try {
    const decoded = verifyAccessToken(bearerMatch[1]);

    // Validate required payload fields (never log token content)
    if (!decoded.id || !decoded.email) {
      logger.warn('Invalid token payload structure', { requestId: req.id, path: req.path });
      return res.status(401).json({ message: "Invalid token" });
    }

    req.user = decoded;
    next();
  } catch (err) {
    logger.warn('Token verification failed', {
      requestId: req.id,
      errorType: err.name,
      path: req.path,
      method: req.method,
    });

    let message = 'Authentication failed';
    const code = err?.data?.code;
    if (err.name === 'TokenExpiredError' || code === 'TOKEN_EXPIRED' || err.message === 'Token expired') {
      message = 'Token has expired';
    } else if (err.name === 'JsonWebTokenError' || code === 'TOKEN_INVALID') {
      // Generic message — don't expose internal JWT error details to clients
      message = 'Invalid token';
    } else if (err.name === 'TokenNotBeforeError') {
      message = 'Token not active yet';
    } else if (err.message && err.statusCode === 401) {
      message = err.message;
    }

    res.status(401).json({ message });
  }
};
