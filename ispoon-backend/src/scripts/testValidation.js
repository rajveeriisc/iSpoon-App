import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { z } from "zod";

import { getDashboardSchema, getSummarySchema } from "../validators/analytics.schema.js";
import { getBitesSchema, syncBitesSchema } from "../validators/bite.schema.js";
import { registerDeviceSchema, updateDeviceSettingsSchema } from "../validators/device.schema.js";
import { createMealSchema, getMealsSchema, updateMealSchema } from "../validators/meal.schema.js";
import { updateProfileSchema } from "../validators/user.schema.js";
import {
  deleteAccountSchema,
  firebaseIdTokenSchema,
  logoutRequestSchema,
  refreshTokenRequestSchema,
} from "../validators/auth.schema.js";
import {
  notificationHistorySchema,
  notificationIdSchema,
  notificationPreferencesSchema,
  registerFCMTokenSchema,
} from "../validators/notification.schema.js";
import { validateRequest } from "../middleware/validateRequest.js";
import { AppError } from "../utils/errors.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const srcDir = path.resolve(__dirname, "..");

const validUuid = "550e8400-e29b-41d4-a716-446655440000";
const laterIso = "2026-01-01T12:30:00.000Z";
const earlierIso = "2026-01-01T12:00:00.000Z";

const checks = [];

function check(name, fn) {
  checks.push({ name, fn });
}

function assertValid(schema, payload, expectedSubset) {
  const result = schema.safeParse(payload);
  assert.equal(result.success, true, result.error?.message);
  if (expectedSubset) {
    assert.deepEqual(result.data, { ...result.data, ...expectedSubset });
  }
  return result.data;
}

function assertInvalid(schema, payload) {
  const result = schema.safeParse(payload);
  assert.equal(result.success, false, "Expected schema to reject payload");
  assert.ok(result.error instanceof z.ZodError);
}

async function readSource(relativePath) {
  return readFile(path.join(srcDir, relativePath), "utf8");
}

check("auth routes use current Firebase/JWT endpoints", async () => {
  const authRoutes = await readSource("routes/auth.routes.js");
  const expectedRoutes = [
    '"/firebase/verify"',
    '"/firebase/request-email-verification"',
    '"/logout"',
    '"/refresh"',
    '"/me"',
  ];

  for (const route of expectedRoutes) {
    assert.ok(authRoutes.includes(route), `Missing auth route: ${route}`);
  }

  assert.equal(authRoutes.includes('"/login"'), false, "Stale /api/auth/login route should not exist");
  assert.equal(authRoutes.includes('"/signup"'), false, "Stale /api/auth/signup route should not exist");
});

check("auth schemas bound token sizes and reject unknown fields", () => {
  assertValid(firebaseIdTokenSchema, { body: { idToken: "x".repeat(100) } });
  assertInvalid(firebaseIdTokenSchema, { body: { idToken: "x", admin: true } });
  assertInvalid(firebaseIdTokenSchema, { body: { idToken: "x".repeat(16_385) } });
  assertValid(refreshTokenRequestSchema, { body: {} });
  assertInvalid(refreshTokenRequestSchema, { body: { fcmToken: "x".repeat(100) } });
  assertValid(logoutRequestSchema, {
    body: { refreshToken: "x".repeat(100), fcmToken: "y".repeat(100) },
  });
  assertInvalid(refreshTokenRequestSchema, { body: { unexpected: true } });
  assertValid(deleteAccountSchema, { body: { idToken: "x".repeat(100) } });
  assertInvalid(deleteAccountSchema, { body: {} });
});

check("app mounts current API route groups", async () => {
  const appSource = await readSource("app.js");
  // Path → route handler. Middleware-agnostic: security middleware (authLimiter,
  // verifyHmac, …) may sit between the path and the router, so match the mount
  // by its path + handler rather than an exact string, which drifts every time
  // a middleware is added or reordered.
  const expectedMounts = [
    ["/api/auth", "authRoutes"],
    ["/api/users", "userRoutes"],
    ["/api/devices", "deviceRoutes"],
    ["/api/analytics", "analyticsRoutes"],
    ["/api/meals", "mealsRoutes"],
    ["/api/email", "emailRoutes"],
    ["/api/notifications", "notificationRoutes"],
  ];

  for (const [path, handler] of expectedMounts) {
    const re = new RegExp(
      `app\\.use\\(\\s*["']${path.replace(/[/]/g, "\\/")}["'][^)]*\\b${handler}\\b`,
    );
    assert.ok(re.test(appSource), `Missing app mount: ${path} → ${handler}`);
  }
});

check("request validation middleware writes parsed values back to req", () => {
  const schema = z.object({
    body: z.object({ enabled: z.string().transform((value) => value === "true") }),
    params: z.object({ id: z.string().regex(/^\d+$/) }),
    query: z.object({ limit: z.coerce.number().int().min(1) }),
  });
  const req = { body: { enabled: "true" }, params: { id: "42" }, query: { limit: "10" } };
  let nextArg;

  validateRequest(schema)(req, {}, (error) => {
    nextArg = error;
  });

  assert.equal(nextArg, undefined);
  assert.deepEqual(req, {
    body: { enabled: true },
    params: { id: "42" },
    query: { limit: 10 },
  });
});

check("request validation middleware reports zod failures as AppError 400", () => {
  const req = { body: { count: "NaN" }, params: {}, query: {} };
  let nextArg;

  validateRequest(z.object({ body: z.object({ count: z.number() }) }))(req, {}, (error) => {
    nextArg = error;
  });

  assert.ok(nextArg instanceof AppError);
  assert.equal(nextArg.statusCode, 400);
  assert.match(nextArg.message, /Validation Failed/);
});

check("analytics schemas validate date ranges and dashboard defaults", () => {
  assertValid(getDashboardSchema, { query: {} }, { query: { days: 90 } });
  assertValid(getDashboardSchema, { query: { days: "999" } }, { query: { days: 365 } });
  assertValid(getSummarySchema, { query: { start_date: "2026-01-01", end_date: "2026-01-31" } });
  assertInvalid(getSummarySchema, { query: { start_date: "2026-02-01", end_date: "2026-01-31" } });
});

check("device schemas validate registration and heater settings", () => {
  assertValid(registerDeviceSchema, {
    body: { macAddressHash: "abcdef123456", firmwareVersion: "1.0.0", heaterActive: "true" },
  }, {
    body: {
      macAddressHash: "abcdef123456",
      firmwareVersion: "1.0.0",
      heaterActive: true,
      heaterMaxTemp: 40,
      heaterActivationTemp: 15,
    },
  });
  assertValid(registerDeviceSchema, {
    body: { productId: "0123456789ABCDEF", firmwareVersion: "1.2.0" },
  });
  assertInvalid(registerDeviceSchema, { body: { macAddressHash: "short" } });
  assertInvalid(registerDeviceSchema, { body: { productId: "not-a-device-id" } });
  assertInvalid(registerDeviceSchema, { body: { firmwareVersion: "1.0.0" } });
  assertValid(updateDeviceSettingsSchema, {
    params: { deviceId: "device-1" },
    body: { heaterMaxTemp: "55", heaterActivationTemp: 20 },
  });
  assertInvalid(updateDeviceSettingsSchema, { params: { deviceId: "" }, body: {} });
});

check("meal and bite schemas validate mobile sync payloads", () => {
  assertValid(getMealsSchema, {
    query: {
      limit: "50",
      offset: "0",
      sort_by: "started_at",
      include_bites: "true",
      before_started_at: laterIso,
      before_id: "123",
    },
  }, { query: {
    limit: 50,
    offset: 0,
    sort_by: "started_at",
    include_bites: true,
    before_started_at: laterIso,
    before_id: "123",
  } });
  assertInvalid(getMealsSchema, {
    query: { before_started_at: laterIso },
  });
  assertValid(createMealSchema, {
    body: {
      uuid: validUuid,
      started_at: earlierIso,
      ended_at: laterIso,
      local_date: "2026-07-17",
      meal_type: "Lunch",
    },
  });
  assertInvalid(createMealSchema, {
    body: { started_at: laterIso, ended_at: earlierIso },
  });
  assertInvalid(createMealSchema, {
    body: { device_id: "not-a-device-uuid", started_at: earlierIso },
  });
  assertValid(updateMealSchema, {
    params: { id: "123" },
    body: { total_bites: 10, avg_food_temp_c: 42 },
  });
  assertInvalid(updateMealSchema, { params: { id: "abc" }, body: {} });

  const parsedBites = assertValid(syncBitesSchema, {
    params: { uuid: validUuid },
    body: {
      bites: [
        {
          meal_uuid: validUuid,
          timestamp: earlierIso,
          sequence_number: 1,
          tremor_magnitude: 0.2,
          food_temp_c: 38,
          is_valid: 1,
        },
      ],
    },
  });
  assert.equal(parsedBites.body.bites[0].is_valid, true);
  assertInvalid(syncBitesSchema, { params: { uuid: validUuid }, body: { bites: [] } });
  assertInvalid(syncBitesSchema, {
    params: { uuid: validUuid },
    body: { bites: [{ timestamp: earlierIso }] },
  });
  assertValid(getBitesSchema, { params: { uuid: validUuid }, query: {} }, {
    query: { limit: 500, after_sequence: -1 },
  });
});

check("user profile schema allows current app profile fields", () => {
  assertValid(updateProfileSchema, {
    body: {
      name: "Alice",
      phone: "+15555550100",
      gender: "Female",
      location: "San Francisco",
      age: 42,
      notifications_enabled: true,
    },
  });
  assertInvalid(updateProfileSchema, { body: { age: 151 } });
  assertInvalid(updateProfileSchema, { body: { local_only_extra: "rejected" } });
});

check("notification schemas validate active API contracts", () => {
  const preferences = {
    enabled: true,
    quiet_hours_start: "22:00",
    quiet_hours_end: "07:00",
    health_alerts_enabled: true,
    achievement_enabled: true,
    engagement_enabled: true,
    system_alerts_enabled: true,
    max_daily_notifications: 5,
    weekly_digest_enabled: true,
    weekly_digest_day: 0,
    weekly_digest_time: "20:00",
  };
  assertValid(notificationPreferencesSchema, { body: preferences });
  assertInvalid(notificationPreferencesSchema, {
    body: { ...preferences, enabled: "true" },
  });
  assertInvalid(notificationPreferencesSchema, {
    body: { ...preferences, quiet_hours_start: "25:00" },
  });
  assertInvalid(notificationPreferencesSchema, {
    body: { ...preferences, unknown_preference: true },
  });
  assertValid(registerFCMTokenSchema, { body: { fcm_token: "x".repeat(100) } });
  assertInvalid(registerFCMTokenSchema, { body: { fcm_token: "short" } });
  assertValid(notificationHistorySchema, { query: { limit: "25", offset: "10" } }, {
    query: { limit: 25, offset: 10 },
  });
  assertInvalid(notificationIdSchema, { params: { id: "not-a-number" } });
});

check("user profile query excludes credential fields", async () => {
  const userModel = await readSource("models/userModel.js");
  const getByIdSource = userModel.slice(
    userModel.indexOf("export const getUserById"),
    userModel.indexOf("export const getUserByEmail"),
  );
  assert.equal(getByIdSource.includes("SELECT *"), false);
  for (const forbidden of ["password", "reset_token", "reset_token_expires_at"]) {
    assert.equal(getByIdSource.includes(forbidden), false, `${forbidden} must not be projected`);
  }
});

let failures = 0;

for (const { name, fn } of checks) {
  try {
    await fn();
    console.log(`PASS ${name}`);
  } catch (error) {
    failures += 1;
    console.error(`FAIL ${name}`);
    console.error(error?.stack || error);
  }
}

if (failures > 0) {
  console.error(`Validation checks failed: ${failures}/${checks.length}`);
  process.exit(1);
}

console.log(`Validation checks passed: ${checks.length}/${checks.length}`);
