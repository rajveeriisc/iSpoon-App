import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  DESTRUCTIVE_AUTH_MAX_AGE_SECONDS,
  validateRecentFirebaseProof,
} from "../src/services/firebaseReauth.service.js";
import { deleteAccountSchema } from "../src/validators/auth.schema.js";
import {
  parseTrustProxy,
  parseBindHost,
  assertSafeListenConfig,
} from "../src/config/security.js";

test("TRUST_PROXY parses booleans and hop counts without string confusion", () => {
  assert.equal(parseTrustProxy(undefined), false);
  assert.equal(parseTrustProxy("false"), false);
  assert.equal(parseTrustProxy("true"), 1);
  assert.equal(parseTrustProxy("2"), 2);
  assert.equal(parseTrustProxy("loopback"), "loopback");
});

test("BIND_HOST defaults to loopback so local testing is not LAN-exposed", () => {
  assert.equal(parseBindHost(undefined), "127.0.0.1");
  assert.equal(parseBindHost(""), "127.0.0.1");
  assert.equal(parseBindHost("  "), "127.0.0.1");
  assert.equal(parseBindHost("0.0.0.0"), "0.0.0.0");
  assert.equal(parseBindHost("127.0.0.1"), "127.0.0.1");
});

test("refuses to bind all interfaces when DATABASE_URL points at Neon", () => {
  const neon = "postgresql://u:p@ep-example-pooler.ap-southeast-1.aws.neon.tech/db";
  assert.throws(
    () => assertSafeListenConfig({
      bindHost: "0.0.0.0",
      databaseUrl: neon,
      allowLanBind: undefined,
    }),
    (error) => /neon/i.test(error.message) && /BIND_HOST|ALLOW_LAN_BIND/i.test(error.message),
  );
  assert.doesNotThrow(() => assertSafeListenConfig({
    bindHost: "127.0.0.1",
    databaseUrl: neon,
    allowLanBind: undefined,
  }));
  assert.doesNotThrow(() => assertSafeListenConfig({
    bindHost: "0.0.0.0",
    databaseUrl: neon,
    allowLanBind: "1",
  }));
  assert.doesNotThrow(() => assertSafeListenConfig({
    bindHost: "0.0.0.0",
    databaseUrl: "postgresql://postgres:postgres@127.0.0.1:5432/ispoon",
    allowLanBind: undefined,
  }));
});

test("recent Firebase proof accepts the linked UID", () => {
  const now = 2_000_000_000;
  const proof = { uid: "firebase-user-1", auth_time: now - 60 };
  assert.equal(validateRecentFirebaseProof(proof, "firebase-user-1", now), proof);
});

test("destructive proof rejects a different Firebase identity", () => {
  assert.throws(
    () => validateRecentFirebaseProof(
      { uid: "attacker", auth_time: 2_000_000_000 },
      "victim",
      2_000_000_000,
    ),
    (error) => error.statusCode === 403,
  );
});

test("destructive proof rejects stale and missing auth_time", () => {
  const now = 2_000_000_000;
  for (const proof of [
    { uid: "user" },
    { uid: "user", auth_time: now - DESTRUCTIVE_AUTH_MAX_AGE_SECONDS - 1 },
  ]) {
    assert.throws(
      () => validateRecentFirebaseProof(proof, "user", now),
      (error) => error.statusCode === 401 && error.data?.code === "RECENT_LOGIN_REQUIRED",
    );
  }
});

test("delete-account schema requires only a bounded Firebase token", () => {
  assert.equal(deleteAccountSchema.safeParse({ body: { idToken: "proof" } }).success, true);
  assert.equal(deleteAccountSchema.safeParse({ body: {} }).success, false);
  assert.equal(deleteAccountSchema.safeParse({ body: { idToken: "proof", admin: true } }).success, false);
  assert.equal(deleteAccountSchema.safeParse({ body: { idToken: "x".repeat(16_385) } }).success, false);
});

test("refresh-family migration includes lineage and replay fields", async () => {
  const sql = await readFile(new URL("../src/migrations/011_refresh_token_families.sql", import.meta.url), "utf8");
  for (const field of ["family_id", "parent_token_id", "replaced_by_token_id", "replay_detected_at"]) {
    assert.match(sql, new RegExp(`\\b${field}\\b`));
  }
});

test("refresh verification handles replay before external identity checks", async () => {
  const source = await readFile(new URL("../src/services/token.service.js", import.meta.url), "utf8");
  assert.match(source, /if \(storedToken\.revoked_at\)/);
  assert.match(source, /revokeRefreshTokenFamilyForReplay/);
});
