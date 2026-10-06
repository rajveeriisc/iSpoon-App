import "dotenv/config";
import app from "./app.js";
import FCMService from "./services/fcmService.js";
import logger from "./utils/logger.js";
import { checkDatabaseConnection, pool } from "./config/db.js";
import {
  assertSafeListenConfig,
  parseBindHost,
  validateSecurityConfig,
} from "./config/security.js";

const PORT = process.env.PORT || 5000;
const BIND_HOST = parseBindHost(process.env.BIND_HOST);

// Async initialization
(async () => {
  // Validate before accepting traffic. Importing app modules must never exit
  // the process, because test runners and deployment tooling import them too.
  validateSecurityConfig();
  assertSafeListenConfig({
    bindHost: BIND_HOST,
    databaseUrl: process.env.DATABASE_URL,
    allowLanBind: process.env.ALLOW_LAN_BIND,
  });

  // Warm and verify the database pool before listening. The readiness probe
  // remains authoritative, so a temporary outage does not crash-loop deploys.
  await checkDatabaseConnection();

  // Initialize FCM Service
  try {
    const fcmReady = await FCMService.initialize();
    if (fcmReady) {
      logger.info('FCM Service initialized', { context: 'Server' });
    } else {
      logger.warn('Push notifications are unavailable', { context: 'Server' });
    }
  } catch (error) {
    logger.warn(`FCM Service initialization failed: ${error.message}`, { context: 'Server' });
    logger.warn('Push notifications will not be sent', { context: 'Server' });
  }

  // Start server
  const server = app.listen(PORT, BIND_HOST, () =>
    logger.info(`iSpoon Backend running on ${BIND_HOST}:${PORT}`, { context: 'Server' })
  );
  server.on('error', (error) => {
    logger.error('HTTP server failed to start', { context: 'Server', error });
    void pool.end().finally(() => {
      process.exitCode = 1;
    });
  });

  let shuttingDown = false;
  const shutdown = async (signal) => {
    if (shuttingDown) return;
    shuttingDown = true;
    logger.info(`${signal} received: shutting down`, { context: 'Server' });

    const forceTimer = setTimeout(() => {
      logger.error('Graceful shutdown timed out', { context: 'Server' });
      process.exit(1);
    }, 10_000);
    forceTimer.unref();

    try {
      await new Promise((resolve, reject) => {
        server.close((error) => error ? reject(error) : resolve());
      });
      await pool.end();
      logger.info('HTTP server and database pool closed', { context: 'Server' });
      process.exitCode = 0;
    } catch (error) {
      logger.error('Graceful shutdown failed', { context: 'Server', error });
      process.exitCode = 1;
    } finally {
      clearTimeout(forceTimer);
    }
  };

  process.once('SIGTERM', () => void shutdown('SIGTERM'));
  process.once('SIGINT', () => void shutdown('SIGINT'));
})().catch(async (error) => {
  logger.error('Server startup failed', { context: 'Server', error });
  try {
    await pool.end();
  } catch (closeError) {
    logger.error('Database pool cleanup after startup failure failed', {
      context: 'Server',
      error: closeError,
    });
  }
  process.exitCode = 1;
});
