import assert from "node:assert/strict";
import http from "node:http";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

import app from "../src/app.js";

const source = await readFile(new URL("../src/app.js", import.meta.url), "utf8");

test("generalLimiter is mounted before meal-photo routes", () => {
  const limiterAt = source.indexOf("app.use(generalLimiter)");
  const photosAt = source.indexOf('"/uploads/meal-photos/:userId/:filename"');
  assert.notEqual(limiterAt, -1);
  assert.notEqual(photosAt, -1);
  assert.ok(
    limiterAt < photosAt,
    "unauthenticated photo probes must pay the general rate limit before JWT work",
  );
});

test("express.static is scoped to avatars and never to the uploads root", () => {
  assert.match(source, /express\.static\(path\.join\(process\.cwd\(\), "uploads", "avatars"\)\)/);
  assert.doesNotMatch(
    source,
    /express\.static\(path\.join\(process\.cwd\(\), "uploads"\)\)/,
  );
});

const getStatus = (port, urlPath) => new Promise((resolve, reject) => {
  const request = http.get({ host: "127.0.0.1", port, path: urlPath }, (res) => {
    res.resume();
    resolve(res.statusCode);
  });
  request.on("error", reject);
  request.setTimeout(3000, () => {
    request.destroy();
    reject(new Error("timeout"));
  });
});

test("C4 path encodings never serve a meal photo without a token", async () => {
  const userId = "_c4test";
  const filename = "probe.bin";
  const dir = path.join(process.cwd(), "uploads", "meal-photos", userId);
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, filename), Buffer.from("private-meal-photo"));

  const server = app.listen(0, "127.0.0.1");
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();

  try {
    const paths = [
      `/uploads/meal-photos/${userId}/${filename}`,
      `/uploads//meal-photos/${userId}/${filename}`,
      `/uploads/./meal-photos/${userId}/${filename}`,
      `/uploads/meal-photos%2F${userId}%2F${filename}`,
      `/uploads/%6d%65%61%6c-photos/${userId}/${filename}`,
    ];
    for (const urlPath of paths) {
      const status = await getStatus(port, urlPath);
      assert.notEqual(
        status,
        200,
        `${urlPath} must not serve the file (got ${status})`,
      );
      assert.ok(
        status === 401 || status === 403 || status === 404,
        `${urlPath} expected 401/403/404, got ${status}`,
      );
    }
  } finally {
    await new Promise((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
    });
    await rm(dir, { recursive: true, force: true });
  }
});
