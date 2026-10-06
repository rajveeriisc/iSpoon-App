import { timingSafeEqual } from "node:crypto";

const DEFAULT_TIMEOUT_MS = 2_000;

const normalizeTimeout = (value) => {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 && parsed <= 30_000
    ? parsed
    : DEFAULT_TIMEOUT_MS;
};

const safeTokenEqual = (supplied, expected) => {
  if (!supplied || !expected) return false;
  const suppliedBuffer = Buffer.from(supplied);
  const expectedBuffer = Buffer.from(expected);
  return suppliedBuffer.length === expectedBuffer.length &&
    timingSafeEqual(suppliedBuffer, expectedBuffer);
};

const canViewServiceDetails = (req, healthToken) => {
  const suppliedToken = req.get("authorization")?.replace(/^Bearer\s+/i, "");
  // Never infer trust from a loopback peer: local tunnel/reverse-proxy agents
  // also connect over loopback. Detailed dependency state requires an
  // explicit shared health token.
  return safeTokenEqual(suppliedToken, healthToken);
};

const runWithTimeout = (check, timeoutMs, name) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error(`${name} health check timed out`)), timeoutMs);
  // Keep the timer referenced under node:test so stalled-dependency probes
  // can actually fire. Production HTTP servers already hold the loop open;
  // unref only there so a hanging probe does not block process exit.
  if (process.env.NODE_ENV !== "test") {
    timer.unref();
  }

  Promise.resolve()
    .then(check)
    .then(resolve, reject)
    .finally(() => clearTimeout(timer));
});

/**
 * Health handlers are dependency-injected so probe semantics can be tested
 * without connecting to production infrastructure.
 */
export const createHealthHandlers = ({
  pool,
  getFirebaseAdmin,
  healthToken = process.env.HEALTH_TOKEN,
  timeoutMs = process.env.HEALTH_CHECK_TIMEOUT_MS,
} = {}) => {
  if (!pool?.query || typeof getFirebaseAdmin !== "function") {
    throw new TypeError("Health handlers require database and Firebase dependencies");
  }

  const boundedTimeoutMs = normalizeTimeout(timeoutMs);

  const live = (_req, res) => {
    res.setHeader("Cache-Control", "no-store");
    return res.status(200).json({ status: "ok" });
  };

  const ready = async (req, res) => {
    res.setHeader("Cache-Control", "no-store");

    const [database, firebase] = await Promise.allSettled([
      runWithTimeout(
        () => pool.query({ text: "SELECT 1", query_timeout: boundedTimeoutMs }),
        boundedTimeoutMs,
        "Database",
      ),
      runWithTimeout(() => getFirebaseAdmin(), boundedTimeoutMs, "Firebase"),
    ]);

    const isReady = database.status === "fulfilled" && firebase.status === "fulfilled";
    const statusCode = isReady ? 200 : 503;
    const publicBody = { status: isReady ? "ready" : "not_ready" };

    if (!canViewServiceDetails(req, healthToken)) {
      return res.status(statusCode).json(publicBody);
    }

    return res.status(statusCode).json({
      ...publicBody,
      timestamp: new Date().toISOString(),
      uptimeSeconds: Math.floor(process.uptime()),
      services: {
        database: database.status === "fulfilled" ? "ok" : "error",
        firebase: firebase.status === "fulfilled" ? "ok" : "error",
      },
    });
  };

  return { live, ready };
};
