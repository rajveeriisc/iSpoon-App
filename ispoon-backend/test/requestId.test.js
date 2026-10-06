import assert from "node:assert/strict";
import test from "node:test";

import requestId from "../src/middleware/requestId.js";

const run = (headers) => {
  const req = { headers };
  const responseHeaders = {};
  const res = { setHeader: (name, value) => { responseHeaders[name] = value; } };
  let called = false;
  requestId(req, res, () => { called = true; });
  return { req, responseHeaders, called };
};

test("request ID middleware preserves a safe caller ID", () => {
  const result = run({ "x-request-id": "gateway-req:1234" });
  assert.equal(result.req.id, "gateway-req:1234");
  assert.equal(result.responseHeaders["X-Request-Id"], "gateway-req:1234");
  assert.equal(result.called, true);
});

test("request ID middleware rejects unsafe or oversized caller IDs", () => {
  for (const candidate of ["short", "contains spaces", "x".repeat(129)]) {
    const result = run({ "x-request-id": candidate });
    assert.match(result.req.id, /^[a-f0-9]{8}$/);
    assert.notEqual(result.req.id, candidate);
  }
});

test("request ID middleware falls back to a valid correlation ID", () => {
  const result = run({
    "x-request-id": "invalid id",
    "x-correlation-id": "correlation.123",
  });
  assert.equal(result.req.id, "correlation.123");
});
