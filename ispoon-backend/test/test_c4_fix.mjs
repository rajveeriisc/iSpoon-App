/**
 * test_c4_fix.mjs — Verifies all four C4 path-bypass vectors are blocked.
 * Run from ispoon-backend/:  node test/test_c4_fix.mjs
 * Requires the server to be running on PORT 5000.
 */
import http from "node:http";

const BASE = "http://localhost:5002";
const VICTIM_ID = "2";
const FILENAME = "meal_1783582469860_hmn1cv.jpg";

const attacks = [
  {
    label: "Exact protected route (no auth header) → expect 401",
    path: `/uploads/meal-photos/${VICTIM_ID}/${FILENAME}`,
    expect: 401,
  },
  {
    label: "Double-slash bypass → expect 404",
    path: `/uploads//meal-photos/${VICTIM_ID}/${FILENAME}`,
    expect: 404,
  },
  {
    label: "Dot-segment (normalized by Express to authenticated route) → expect 401",
    path: `/uploads/./meal-photos/${VICTIM_ID}/${FILENAME}`,
    expect: 401,
  },
  {
    label: "URL-encoded slash bypass → expect 404",
    path: `/uploads/meal-photos%2F${VICTIM_ID}%2F${FILENAME}`,
    expect: 404,
  },
  {
    label: "Hex-encoded path bypass → expect 404",
    path: `/uploads/%6d%65%61%6c-photos/${VICTIM_ID}/${FILENAME}`,
    expect: 404,
  },
  {
    label: "Normal avatar (sanity check) → expect 200",
    path: `/uploads/avatars/u_1764921457742_b9l4jd.webp`,
    expect: 200,
  },
];

function get(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, (res) => { res.resume(); resolve(res.statusCode); });
    req.on("error", reject);
    req.setTimeout(3000, () => { req.destroy(); reject(new Error("timeout")); });
  });
}

let passed = 0, failed = 0;
for (const attack of attacks) {
  try {
    const status = await get(`${BASE}${attack.path}`);
    const ok = status === attack.expect;
    console.log(`${ok ? "✅" : "❌"} [${status} expected ${attack.expect}] ${attack.label}`);
    ok ? passed++ : failed++;
  } catch (e) {
    console.log(`❌ ERROR — ${attack.label}: ${e.message}`);
    failed++;
  }
}
console.log(`\n${passed}/${passed + failed} passed`);
if (failed > 0) process.exit(1);
