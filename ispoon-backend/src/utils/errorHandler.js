import { logSecurityEvent } from '../config/security.js';
import logger from './logger.js';

// Enhanced error handler with security considerations
export const handleError = (res, error, req = null) => {
  if (res.headersSent) {
    return false;
  }
  const isMulterError = error?.name === 'MulterError';
  const statusCode = isMulterError
    ? (error.code === 'LIMIT_FILE_SIZE' ? 413 : 400)
    : (error?.statusCode || error?.status || 500);

  // Log security-related errors
  const msg = isMulterError
    ? (error.code === 'LIMIT_FILE_SIZE' ? 'Uploaded file is too large' : 'Invalid file upload')
    : (error?.message || '');
  if (msg.includes('Invalid') || msg.includes('Unauthorized')) {
    logSecurityEvent('AUTH_ERROR', {
      message: msg,
      url: req?.url,
      method: req?.method,
      ip: req?.ip,
      requestId: req?.id,
    });
  }

  if (statusCode >= 500) {
    logger.error(msg || 'Internal server error', {
      requestId: req?.id,
      url: req?.url,
      method: req?.method,
      error,
    });
  } else {
    logger.warn(msg || 'Client error', {
      requestId: req?.id,
      statusCode,
    });
  }

  const response = {
    message: statusCode >= 500
      ? 'Internal Server Error'
      : (msg || 'Request Error'),
    ...(req?.id ? { requestId: req.id } : {}),
    ...(statusCode >= 500 ? { code: 'INTERNAL_ERROR' } : {}),
  };

  res.status(statusCode).json(response);
  return true;
};

// Middleware for catching unhandled errors
export const errorMiddleware = (err, req, res, next) => {
  if (!err) return next();
  if (!handleError(res, err, req)) return next(err);
};
