import assert from "node:assert/strict";
import test from "node:test";

import { createHealthHandlers } from "../src/health.js";

const request = ({ ip = "203.0.113.10", authorization } = {}) => ({
  ip,
  get: (name) => name.toLowerCase() === "authorization" ? authorization : undefined,
});

const response = () => ({
  headers: {},
  statusCode: undefined,
  body: undefined,
  setHeader(name, value) { this.headers[name] = value; },
  status(code) { this.statusCode = code; return this; },
  json(body) { this.body = body; return this; },
});

test("liveness does not depend on external services", () => {
  const health = createHealthHandlers({
    pool: { query: () => { throw new Error("must not run"); } },
    getFirebaseAdmin: () => { throw new Error("must not run"); },
  });
  const res = response();

  health.live(request(), res);

  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { status: "ok" });
  assert.equal(res.headers["Cache-Control"], "no-store");
});

test("readiness is 200 when required dependencies are available", async () => {
  let query;
  const health = createHealthHandlers({
    pool: { query: async (value) => { query = value; } },
    getFirebaseAdmin: () => ({ name: "app" }),
  });
  const res = response();

  await health.ready(request(), res);

  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { status: "ready" });
  assert.equal(query.text, "SELECT 1");
  assert.equal(query.query_timeout, 2_000);
});

test("readiness is 503 and public response does not leak dependency details", async () => {
  const health = createHealthHandlers({
    pool: { query: async () => { throw new Error("secret database hostname"); } },
    getFirebaseAdmin: () => ({ name: "app" }),
  });
  const res = response();

  await health.ready(request(), res);

  assert.equal(res.statusCode, 503);
  assert.deepEqual(res.body, { status: "not_ready" });
});

test("authorized readiness response includes bounded service status", async () => {
  const health = createHealthHandlers({
    pool: { query: async () => undefined },
    getFirebaseAdmin: () => { throw new Error("private credential path"); },
    healthToken: "internal-health-token",
  });
  const res = response();

  await health.ready(request({ authorization: "Bearer internal-health-token" }), res);

  assert.equal(res.statusCode, 503);
  assert.equal(res.body.status, "not_ready");
  assert.deepEqual(res.body.services, { database: "ok", firebase: "error" });
  assert.equal("error" in res.body, false);
  assert.match(res.body.timestamp, /^\d{4}-\d{2}-\d{2}T/);
});

test("loopback readiness remains public without the health token", async () => {
  const health = createHealthHandlers({
    pool: { query: async () => undefined },
    getFirebaseAdmin: () => ({ name: "app" }),
    healthToken: "internal-health-token",
  });
  const res = response();

  await health.ready(request({ ip: "127.0.0.1" }), res);

  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { status: "ready" });
});

test("readiness times out stalled dependencies", async () => {
  const health = createHealthHandlers({
    pool: { query: () => new Promise(() => {}) },
    getFirebaseAdmin: () => ({ name: "app" }),
    timeoutMs: 10,
  });
  const res = response();

  await health.ready(request(), res);

  assert.equal(res.statusCode, 503);
  assert.deepEqual(res.body, { status: "not_ready" });
});

test("invalid readiness timeout falls back to a safe bounded value", async () => {
  let query;
  const health = createHealthHandlers({
    pool: { query: async (value) => { query = value; } },
    getFirebaseAdmin: () => ({ name: "app" }),
    timeoutMs: -1,
  });
  const res = response();

  await health.ready(request(), res);

  assert.equal(res.statusCode, 200);
  assert.equal(query.query_timeout, 2_000);
});
