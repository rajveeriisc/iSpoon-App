import assert from "node:assert/strict";
import test from "node:test";

import { handleError } from "../src/utils/errorHandler.js";

const response = () => ({
  headersSent: false,
  statusCode: undefined,
  body: undefined,
  status(code) { this.statusCode = code; return this; },
  json(body) { this.body = body; return this; },
});

test("server errors never expose internal messages", () => {
  const res = response();
  handleError(res, new Error("database password leaked"), {
    id: "request-123",
    method: "GET",
    url: "/private",
  });

  assert.equal(res.statusCode, 500);
  assert.deepEqual(res.body, {
    message: "Internal Server Error",
    requestId: "request-123",
    code: "INTERNAL_ERROR",
  });
});

test("upload errors have stable safe status codes", () => {
  const res = response();
  const error = Object.assign(new Error("implementation detail"), {
    name: "MulterError",
    code: "LIMIT_FILE_SIZE",
  });

  handleError(res, error);

  assert.equal(res.statusCode, 413);
  assert.deepEqual(res.body, { message: "Uploaded file is too large" });
});

test("error handler does not write a second response", () => {
  const res = response();
  res.headersSent = true;
  assert.equal(handleError(res, new Error("late failure")), false);
  assert.equal(res.statusCode, undefined);
});
