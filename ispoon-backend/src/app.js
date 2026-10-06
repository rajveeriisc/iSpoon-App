import "dotenv/config";
import express from "express";
import cors from "cors";
import helmet from "helmet";
import rateLimit from "express-rate-limit";
import path from "path";

// Routes - all from single location
import {
  authRoutes,
  userRoutes,
  deviceRoutes,
  analyticsRoutes,
  mealsRoutes,
  emailRoutes,
  notificationRoutes,
} from "./routes/index.js";

// Config & Utils
import { errorMiddleware } from "./utils/errorHandler.js";
import { parseTrustProxy, SECURITY_CONFIG } from "./config/security.js";
import { pool } from "./config/db.js";
import { getFirebaseAdmin } from "./config/firebaseAdmin.js";
import { createHealthHandlers } from "./health.js";
import logger from "./utils/logger.js";
import requestId from "./middleware/requestId.js";
import { protect } from "./middleware/authMiddleware.js";
import { verifyHmac } from "./middleware/hmacMiddleware.js";

const app = express();

// Trust proxy headers only when explicitly configured by deployment.
// This prevents direct clients from spoofing X-Forwarded-For and bypassing
// IP-based rate limits if Node is exposed directly.
app.set('trust proxy', parseTrustProxy(process.env.TRUST_PROXY));

// ─── Security headers ─────────────────────────────────────────────────────────
app.use(helmet({
  crossOriginOpenerPolicy: false,
  crossOriginEmbedderPolicy: false,
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'"],
      styleSrc: ["'self'"],
      imgSrc: ["'self'", "data:", "https:"],
      connectSrc: ["'self'", "https://*.googleapis.com", "https://*.firebaseio.com"],
    },
  },
}));

// ─── CORS ─────────────────────────────────────────────────────────────────────
const corsOptions = {
  origin: SECURITY_CONFIG.ALLOWED_ORIGINS,
  credentials: true,
  methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization', 'X-Request-Id'],
};
app.use(cors(corsOptions));
// Preflight must use the SAME restricted config, not the wide-open default.
app.options("*", cors(corsOptions));

// ─── Core middleware ──────────────────────────────────────────────────────────
app.use(requestId);        // attach req.id + X-Request-Id response header
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true, limit: '1mb' }));

// ─── Structured request logger ────────────────────────────────────────────────
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const duration = Date.now() - start;
    const level = res.statusCode >= 500 ? 'error' : res.statusCode >= 400 ? 'warn' : 'info';
    logger[level](`${req.method} ${req.path}`, {
      requestId: req.id,
      status: res.statusCode,
      durationMs: duration,
    });
  });
  next();
});

// ─── Rate limiters ────────────────────────────────────────────────────────────
// In development, use very relaxed limits so testing doesn't get blocked.
const isDev = process.env.NODE_ENV !== 'production';

const authLimiter = rateLimit({
  windowMs: isDev ? 60 * 1000 : SECURITY_CONFIG.RATE_LIMITS.AUTH.windowMs,
  max: isDev ? 100 : SECURITY_CONFIG.RATE_LIMITS.AUTH.max,
  message: { message: 'Too many authentication attempts, please try again later.' },
  standardHeaders: true,
  legacyHeaders: false,
  // Refresh/logout are session maintenance, not credential attempts. Counting
  // them against a five-attempt login bucket locks out normal mobile clients.
  skip: (req) => req.path === '/refresh' || req.path === '/logout',
});

const generalLimiter = rateLimit({
  windowMs: isDev ? 60 * 1000 : SECURITY_CONFIG.RATE_LIMITS.GENERAL.windowMs,
  max: isDev ? 1000 : SECURITY_CONFIG.RATE_LIMITS.GENERAL.max,
  message: { message: 'Too many requests, please try again later.' },
  standardHeaders: true,
  legacyHeaders: false,
});

// ─── Root / health (unlimited — orchestrators probe these) ────────────────────
app.get("/", (req, res) => {
  res.json({ status: "ok", service: "i-spoon-api" });
});

const health = createHealthHandlers({ pool, getFirebaseAdmin });
app.get("/api/health/live", health.live);
app.get("/api/health/ready", health.ready);
// Backwards-compatible alias; health now has readiness semantics so an
// orchestrator will stop routing traffic when core dependencies are down.
app.get("/api/health", health.ready);

// Everything below, including meal-photo JWT checks, pays the general budget.
app.use(generalLimiter);

// ─── Upload file serving ──────────────────────────────────────────────────────
// Meal photos are health-adjacent private data.
// They are ONLY reachable through the authenticated route below.
// express.static is intentionally scoped to uploads/avatars/ only — it must
// NEVER serve the meal-photos subtree, because its liberal path normalisation
// (decodeURIComponent, dot-segment resolution, double-slash collapse) allows
// all four known bypass vectors to sail past the strict route patterns above.
app.get("/uploads/meal-photos/:userId/:filename", protect, (req, res) => {
  if (String(req.user.id) !== String(req.params.userId)) {
    return res.status(403).json({ message: "Access denied" });
  }

  const filename = path.basename(req.params.filename);
  if (filename !== req.params.filename) {
    return res.status(400).json({ message: "Invalid filename" });
  }

  res.setHeader("Cache-Control", "private, max-age=300");
  return res.sendFile(
    path.join(process.cwd(), "uploads", "meal-photos", String(req.user.id), filename),
  );
});

// Block any other path under /uploads/meal-photos — this is the backstop
// in case a future refactor accidentally widens the static scope again.
app.use("/uploads/meal-photos", (_req, res) => {
  res.status(404).json({ message: "Not found" });
});

// Public static assets — ONLY the avatars subdirectory.
// Keeping this separate from meal-photos prevents any middleware-chain
// confusion; the avatars directory contains no private data.
app.use("/uploads/avatars", (req, res, next) => {
  res.setHeader("Cache-Control", "public, max-age=31536000, immutable");
  next();
});
app.use("/uploads/avatars", express.static(path.join(process.cwd(), "uploads", "avatars")));

// Deny everything else under /uploads that wasn't already matched above.
app.use("/uploads", (_req, res) => {
  res.status(404).json({ message: "Not found" });
});

// ─── Routes ───────────────────────────────────────────────────────────────────
app.use("/api/auth", authLimiter, authRoutes);
app.use("/api/users", verifyHmac, userRoutes);
app.use("/api/devices", verifyHmac, deviceRoutes);
app.use("/api/analytics", verifyHmac, analyticsRoutes);
app.use("/api/meals", verifyHmac, mealsRoutes);
app.use("/api/email", emailRoutes);
app.use("/api/notifications", notificationRoutes);

// ─── 404 ──────────────────────────────────────────────────────────────────────
// eslint-disable-next-line no-unused-vars
app.use((req, res, _next) => {
  res.status(404).json({ message: 'Not Found' });
});

// ─── Global error handler (must be last) ──────────────────────────────────────
app.use(errorMiddleware);

export default app;
