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

// Measured from the Mumbai VPS against the Singapore Neon endpoint:
//
//   cold (TCP + TLS + auth + query)  494 ms
//   warm (connection reused)          66 ms
//   penalty                          428 ms
//
// The pool used to drop idle connections after 30 s, so any user opening the
// app after a quiet minute paid that 428 ms on their first request — which is
// most requests for an app used in meal-length bursts. Holding connections
// longer is the single largest latency win available without moving the
// database into the same region as the server.
//
// IDLE_TIMEOUT_MS is deliberately just under Neon's 5-minute autosuspend
// rather than "as long as possible": an open connection keeps the Neon
// compute awake, and pinning it 24/7 would burn far more compute hours than
// a free-tier allowance covers. Four minutes keeps a meal session warm
// throughout without keeping the database awake any longer than the activity
// itself already does. Raise it if the Neon plan is paid and always-on.
const IDLE_TIMEOUT_MS = Number(process.env.DB_IDLE_TIMEOUT_MS || 240_000);

export const pool = new Pool({
  connectionString,
  ssl: shouldUseSSL ? { rejectUnauthorized } : false,
  // Connection pool configuration
  max: 10, // Maximum pool size
  idleTimeoutMillis: IDLE_TIMEOUT_MS,
  connectionTimeoutMillis: 10000, // Return error after 10 seconds if connection cannot be established
  // Without TCP keepalives a connection held open across a NAT or a cloud
  // firewall can be silently discarded mid-flight. The pool would then hand
  // out a dead socket and the request hangs until connectionTimeoutMillis
  // instead of failing fast or reconnecting.
  keepAlive: true,
  keepAliveInitialDelayMillis: 30_000,
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
