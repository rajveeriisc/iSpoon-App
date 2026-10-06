const BASE_URL = process.env.BASE_URL || "http://localhost:5000";
const FIREBASE_ID_TOKEN = process.env.FIREBASE_ID_TOKEN;

async function postJson(path, body) {
  const res = await fetch(`${BASE_URL}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  const text = await res.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = text;
  }
  return { status: res.status, body: data };
}

async function main() {
  if (!FIREBASE_ID_TOKEN) {
    console.log("Current auth flow uses Firebase ID tokens.");
    console.log("Start the server, then run:");
    console.log("  FIREBASE_ID_TOKEN=<firebase-id-token> npm run test:auth");
    console.log("This will call POST /api/auth/firebase/verify.");
    return;
  }

  const result = await postJson("/api/auth/firebase/verify", {
    idToken: FIREBASE_ID_TOKEN,
  });

  console.log("FIREBASE VERIFY:", JSON.stringify(result));
  if (result.status < 200 || result.status >= 300) {
    process.exit(1);
  }
}

main().catch((err) => {
  console.error("Auth test failed:", err?.message || err);
  process.exit(1);
});
