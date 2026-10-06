import pkg from "pg";
import dotenv from "dotenv";
import logger from '../utils/logger.js';
dotenv.config();

const { Pool } = pkg;

// Determine SSL dynamically: allow local Postgres without SSL, Neon/managed with SSL
const shouldUseSSL = (() => {
  const flag = String(process.env.DATABASE_SSL || process.env.PGSSLMODE || "").toLowerCase();
  if (flag === "1" || flag === "true" || flag === "require" || flag === "required") return true;
  try {
    const url = new URL(String(process.env.DATABASE_URL || ""));
    if (url.searchParams.get("sslmode") === "require") return true;
    return (url.hostname || "").includes("neon.tech");
  } catch (_) {
    return false;
  }
})();

// Reject unauthorized SSL certs by default. Only explicit local/test modes may
// opt out; a missing or misspelled NODE_ENV therefore fails closed.
const rejectUnauthorized = (() => {
  const explicit = String(process.env.DB_SSL_REJECT_UNAUTHORIZED || "").toLowerCase();
  const allowsInsecureLocalTls = ['development', 'test'].includes(process.env.NODE_ENV);
  if (explicit === "false" && !allowsInsecureLocalTls) {
    throw new Error("DB_SSL_REJECT_UNAUTHORIZED=false is allowed only in development/test");
  }
  if (explicit === "false") return false;
  return true;
})();

// pg 8 treats several legacy SSL modes as verify-full but pg 9 will adopt the
// weaker libpq meanings. Normalize managed TLS URLs now so the certificate and
// hostname verification policy cannot silently weaken after an upgrade.
const connectionString = (() => {
  const raw = process.env.DATABASE_URL;
  if (!raw || !shouldUseSSL || !rejectUnauthorized) return raw;
  try {
    const url = new URL(raw);
    const mode = url.searchParams.get('sslmode');
    if (['prefer', 'require', 'verify-ca'].includes(mode)) {
      url.searchParams.set('sslmode', 'verify-full');
    }
    return url.toString();
  } catch (_) {
    return raw;
  }
})();

export const pool = new Pool({
  connectionString,
  ssl: shouldUseSSL ? { rejectUnauthorized } : false,
  // Connection pool configuration
  max: 10, // Maximum pool size
  idleTimeoutMillis: 30000, // Close idle clients after 30 seconds
  connectionTimeoutMillis: 10000, // Return error after 10 seconds if connection cannot be established
});

// Handle idle client errors and attempt recovery
let reconnectAttempts = 0;
const maxReconnectAttempts = 5;
const baseReconnectDelay = 1000; // 1 second
pool.on("error", async (err) => {
  logger.error("Postgres pool error (idle client)", { context: 'Database', error: err.message });

  // Attempt to recover connection
  if (reconnectAttempts < maxReconnectAttempts) {
    reconnectAttempts++;
    const delay = baseReconnectDelay * Math.pow(2, reconnectAttempts - 1); // Exponential backoff
    logger.info(`Attempting to reconnect in ${delay}ms (attempt ${reconnectAttempts}/${maxReconnectAttempts})`, { context: 'Database' });

    setTimeout(async () => {
      try {
        await pool.query("SELECT 1");
        logger.info("Database connection recovered", { context: 'Database' });
        reconnectAttempts = 0; // Reset counter on success
      } catch (retryErr) {
        logger.error("Reconnection failed", { context: 'Database', error: retryErr.message });
      }
    }, delay);
  } else {
    logger.error("Max reconnection attempts reached. Manual intervention required.", { context: 'Database' });
  }
});

// Explicit startup check. Keeping this out of module initialization means
// importing app/config modules in tests and migration tooling has no network
// side effects.
export const checkDatabaseConnection = async () => {
  try {
    await pool.query("SELECT 1");
    logger.info("Postgres reachable", { context: 'Database' });
    return true;
  } catch (err) {
    logger.error("Postgres startup check failed", { context: 'Database', error: err.message });
    logger.error("Server will continue but database operations will fail", { context: 'Database' });
    return false;
  }
};
