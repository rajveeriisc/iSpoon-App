// Security configuration constants and utilities
const positiveIntegerEnv = (name, fallback) => {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
};

export const SECURITY_CONFIG = {
  // Rate limiting
  RATE_LIMITS: {
    AUTH: {
      windowMs: positiveIntegerEnv('RATE_LIMIT_WINDOW_MS', 15 * 60 * 1000),
      max: positiveIntegerEnv('AUTH_RATE_LIMIT_MAX', 5),
    },
    GENERAL: {
      windowMs: positiveIntegerEnv('RATE_LIMIT_WINDOW_MS', 15 * 60 * 1000),
      max: positiveIntegerEnv('RATE_LIMIT_MAX_REQUESTS', 500),
    },
    RESET: { windowMs: 60 * 60 * 1000, max: 3 }, // 3 resets per hour
  },

  PASSWORD_RESET: {
    TOKEN_TTL_MINUTES: 60,
  },

  EMAIL_VERIFICATION: {
    TOKEN_TTL_MINUTES: 60 * 24, // 24 hours
  },

  // NOTE: no PASSWORD policy config here. Password creation happens entirely
  // client-side via Firebase Auth (this backend never receives a raw
  // password), so the real enforcement points are lib/core/utils/validators.dart
  // (validatePassword: 8+ chars, upper/lower/number/special) and the
  // Firebase/Identity Platform console's own password policy — the actual
  // server-side boundary, since client-side validation alone doesn't stop a
  // modified client or a direct Firebase API call. A previous PASSWORD block
  // here duplicated the Flutter rule but was never referenced by any route —
  // removed rather than left as a config that looked enforced but wasn't.

  // Input limits
  INPUT_LIMITS: {
    EMAIL_MAX_LENGTH: 254,
    NAME_MAX_LENGTH: 100,
    PHONE_MAX_LENGTH: 20,
    LOCATION_MAX_LENGTH: 200,
    BIO_MAX_LENGTH: 500,
    EMERGENCY_CONTACT_MAX_LENGTH: 100,
    ALLERGIES_MAX_COUNT: 20,
    DAILY_GOAL_MAX: 10000,
  },

  // Session/JWT
  JWT: {
    SECRET_MIN_LENGTH: 32,
    EXPIRES_IN: '15m',
    ACCESS_EXPIRES_IN: '15m',
    REFRESH_EXPIRES_IN: '30d',
    ISSUER: 'i-spoon-backend',
    AUDIENCE: 'i-spoon-mobile',
  },

  // CORS allowed origins — read from ALLOWED_ORIGINS env var (comma-separated)
  // Example: ALLOWED_ORIGINS=http://localhost:3000,https://yourdomain.com
  ALLOWED_ORIGINS: process.env.ALLOWED_ORIGINS
    ? process.env.ALLOWED_ORIGINS.split(',').map(o => o.trim()).filter(Boolean)
    : ['http://localhost:3000', 'http://localhost:5000'],
};

/**
 * Convert deployment-friendly TRUST_PROXY strings into values Express
 * understands. In particular, the common value "false" must be the boolean
 * false; passing the literal string makes proxy-addr treat it as a subnet.
 */
export const parseTrustProxy = (rawValue) => {
  if (rawValue === undefined || rawValue === null) return false;
  const value = String(rawValue).trim();
  if (!value || value.toLowerCase() === 'false') return false;
  if (value.toLowerCase() === 'true') return 1;
  if (/^\d+$/.test(value)) return Number(value);
  return value;
};

/**
 * Default to loopback. Binding 0.0.0.0 is an explicit opt-in via BIND_HOST
 * so `npm run dev` on a laptop is not a LAN-exposed production API.
 */
export const parseBindHost = (rawValue) => {
  if (rawValue === undefined || rawValue === null) return '127.0.0.1';
  const value = String(rawValue).trim();
  return value || '127.0.0.1';
};

const isWildcardBind = (host) =>
  host === '0.0.0.0' || host === '::' || host === '[::]';

const isManagedNeonUrl = (databaseUrl) =>
  /(?:^|[.@/])neon\.tech(?:[:/?]|$)/i.test(String(databaseUrl || ''));

/**
 * Refuse the combination that turns a laptop into a production DB listener:
 * all-interfaces bind + a Neon (or similarly remote) DATABASE_URL.
 * ALLOW_LAN_BIND=1 is the explicit override after credentials are rotated.
 */
export const assertSafeListenConfig = ({
  bindHost,
  databaseUrl,
  allowLanBind,
} = {}) => {
  if (!isWildcardBind(bindHost)) return;
  if (String(allowLanBind) === '1') return;
  if (!isManagedNeonUrl(databaseUrl)) return;
  throw new Error(
    'Refusing to bind all interfaces while DATABASE_URL points at Neon. '
    + 'Use BIND_HOST=127.0.0.1 (adb reverse for phones) or set ALLOW_LAN_BIND=1 '
    + 'after rotating leaked credentials and switching to a throwaway database.',
  );
};

// Security utilities
export const validateSecurityConfig = () => {
  const config = SECURITY_CONFIG;

  if (!['development', 'test', 'production'].includes(process.env.NODE_ENV)) {
    throw new Error('NODE_ENV must be one of: development, test, production');
  }

  // Validate JWT secret length
  if (!process.env.JWT_SECRET || process.env.JWT_SECRET.length < config.JWT.SECRET_MIN_LENGTH) {
    throw new Error(`JWT_SECRET must be at least ${config.JWT.SECRET_MIN_LENGTH} characters`);
  }

  // Validate refresh secret too — it signs long-lived refresh tokens, so a
  // missing/weak value is as dangerous as a weak access-token secret.
  if (!process.env.JWT_REFRESH_SECRET || process.env.JWT_REFRESH_SECRET.length < config.JWT.SECRET_MIN_LENGTH) {
    throw new Error(`JWT_REFRESH_SECRET must be at least ${config.JWT.SECRET_MIN_LENGTH} characters`);
  }

  if (process.env.JWT_SECRET === process.env.JWT_REFRESH_SECRET) {
    throw new Error('JWT_SECRET and JWT_REFRESH_SECRET must be different');
  }

  // Validate database URL
  if (!process.env.DATABASE_URL) {
    throw new Error('DATABASE_URL is required');
  }

  return true;
};

// Log security events (implement proper logging later)
export const logSecurityEvent = (event, details = {}) => {
  console.warn(`Security Event: ${event}`, details);
};
