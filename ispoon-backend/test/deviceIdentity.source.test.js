import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (relative) => readFileSync(join(root, relative), "utf8");

test("device registration accepts a 16-hex product id as the unique key", () => {
  const schema = read("src/validators/device.schema.js");
  assert.match(schema, /productId/);
  assert.match(schema, /\[0-9a-fA-F\]\{16\}/);
});

test("devices are upserted by product_id and stay owned by one user", () => {
  const model = read("src/models/deviceModel.js");
  assert.match(model, /product_id/);
  assert.match(model, /ON CONFLICT \(product_id\)/);
  assert.match(model, /WHERE devices\.user_id = \$1/);
  assert.match(model, /Device is registered to another account/);
  assert.match(model, /SELECT[\s\S]*product_id[\s\S]*FROM devices/);
});

test("migration 016 adds a unique product_id for per-user spoon inventory", () => {
  const sql = read("src/migrations/016_device_product_id.sql");
  assert.match(sql, /ADD COLUMN IF NOT EXISTS product_id VARCHAR\(16\)/);
  assert.match(sql, /UNIQUE \(product_id\)/);
});
