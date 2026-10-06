import { cert, getApps, initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import fs from "fs";
import path from "path";

let firebaseApp = null;

function normalizePrivateKey(raw) {
  if (!raw) return raw;
  let k = String(raw);
  // Strip surrounding quotes if present
  if ((k.startsWith('"') && k.endsWith('"')) || (k.startsWith("'") && k.endsWith("'"))) {
    k = k.slice(1, -1);
  }
  // Convert escaped newlines ("\n") to real newlines
  if (k.includes("\\n")) k = k.replace(/\\n/g, "\n");
  // Normalize CRLF to LF
  if (k.includes("\r\n")) k = k.replace(/\r\n/g, "\n");
  return k.trim();
}

/**
 * Send email verification link via Firebase
 * @param {string} email - User's email address
 * @returns {Promise<string>} Verification link
 */
export async function generateFirebaseVerificationLink(email) {
  const auth = getFirebaseAuth();
  
  const actionCodeSettings = {
    url: process.env.FIREBASE_EMAIL_VERIFICATION_REDIRECT || 
         process.env.APP_BASE_URL || 
         'http://localhost:5000',
    handleCodeInApp: process.env.FIREBASE_HANDLE_CODE_IN_APP === 'true',
  };
  
  try {
    const link = await auth.generateEmailVerificationLink(
      email,
      actionCodeSettings
    );
    return link;
  } catch (error) {
    throw new Error(`Failed to generate verification link: ${error.message}`);
  }
}

/**
 * Send password reset link via Firebase
 * @param {string} email - User's email address
 * @returns {Promise<string>} Password reset link
 */
export async function generateFirebasePasswordResetLink(email) {
  const auth = getFirebaseAuth();
  
  const actionCodeSettings = {
    url: process.env.FIREBASE_EMAIL_VERIFICATION_REDIRECT || 
         process.env.APP_BASE_URL || 
         'http://localhost:5000',
  };
  
  try {
    const link = await auth.generatePasswordResetLink(
      email,
      actionCodeSettings
    );
    return link;
  } catch (error) {
    throw new Error(`Failed to generate password reset link: ${error.message}`);
  }
}

export function getFirebaseAdmin() {
  if (firebaseApp) return firebaseApp;

  const existingApp = getApps()[0];
  if (existingApp) {
    firebaseApp = existingApp;
    return firebaseApp;
  }

  const gac = process.env.GOOGLE_APPLICATION_CREDENTIALS ||
    process.env.FIREBASE_SERVICE_ACCOUNT_PATH;

  // Build two candidate credential sources: file first (if GAC set), then env
  const candidates = [];
  if (gac) {
    try {
      const credPath = path.isAbsolute(gac) ? gac : path.join(process.cwd(), gac);
      const json = JSON.parse(fs.readFileSync(credPath, "utf8"));
      candidates.push({
        source: "gac",
        projectId: json.project_id,
        clientEmail: json.client_email,
        privateKey: normalizePrivateKey(json.private_key),
      });
    } catch (_) {
      // ignore; fall back to env below
    }
  }
  // Fallback: look for a local serviceAccount.json next to the backend
  try {
    const localPath = path.join(process.cwd(), "serviceAccount.json");
    if (fs.existsSync(localPath)) {
      const json = JSON.parse(fs.readFileSync(localPath, "utf8"));
      candidates.push({
        source: "local",
        projectId: json.project_id,
        clientEmail: json.client_email,
        privateKey: normalizePrivateKey(json.private_key),
      });
    }
  } catch (_) {}
  
  // Look for a Base64 encoded full JSON credential string (Best for Render/Railway)
  if (process.env.FIREBASE_SERVICE_ACCOUNT_BASE64) {
    try {
      const decoded = Buffer.from(process.env.FIREBASE_SERVICE_ACCOUNT_BASE64, 'base64').toString('utf8');
      const json = JSON.parse(decoded);
      candidates.push({
        source: "env_base64",
        projectId: json.project_id,
        clientEmail: json.client_email,
        privateKey: normalizePrivateKey(json.private_key),
      });
    } catch (_) {
      console.warn("Failed to parse FIREBASE_SERVICE_ACCOUNT_BASE64");
    }
  }

  // Look for a raw JSON string in environment variable
  if (process.env.FIREBASE_SERVICE_ACCOUNT_JSON) {
    try {
      const json = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON);
      candidates.push({
        source: "env_json",
        projectId: json.project_id,
        clientEmail: json.client_email,
        privateKey: normalizePrivateKey(json.private_key),
      });
    } catch (_) {
      console.warn("Failed to parse FIREBASE_SERVICE_ACCOUNT_JSON");
    }
  }

  // Fallback to individual environment variables
  candidates.push({
    source: "env_individual",
    projectId: process.env.FIREBASE_PROJECT_ID,
    clientEmail: process.env.FIREBASE_CLIENT_EMAIL,
    privateKey: normalizePrivateKey(process.env.FIREBASE_PRIVATE_KEY),
  });

  // Try candidates in order; if init fails with PEM error, try next
  let lastErr = null;
  for (const c of candidates) {
    if (!c.projectId || !c.clientEmail || !c.privateKey) {
      continue;
    }
    try {
      firebaseApp = initializeApp({
        credential: cert({
          projectId: c.projectId,
          clientEmail: c.clientEmail,
          privateKey: c.privateKey,
        }),
      });
      return firebaseApp;
    } catch (e) {
      lastErr = e;
    }
  }

  const hint = "Check FIREBASE_SERVICE_ACCOUNT_PATH/GOOGLE_APPLICATION_CREDENTIALS or FIREBASE_PRIVATE_KEY formatting (use one line with \\n in .env).";
  throw new Error(`Firebase Admin init failed: ${lastErr?.message || "no valid credentials"}. ${hint}`);
}

export function getFirebaseAuth() {
  return getAuth(getFirebaseAdmin());
}


