import fs from "fs";
import path from "path";
import { createHash } from "crypto";
import dotenv from "dotenv";
import { pool } from "../config/db.js";

dotenv.config();

const MIGRATION_LOCK_KEY = "ispoon-backend:schema-migrations:v1";

function checksum(sql) {
  return createHash("sha256").update(sql, "utf8").digest("hex");
}

async function ensureMigrationsTable(client) {
  await client.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      id BIGSERIAL PRIMARY KEY,
      filename TEXT UNIQUE NOT NULL,
      checksum CHAR(64),
      applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    ALTER TABLE schema_migrations ADD COLUMN IF NOT EXISTS checksum CHAR(64);
  `);
}

async function getApplied(client) {
  const res = await client.query(`SELECT filename, checksum FROM schema_migrations`);
  return new Map(res.rows.map((row) => [row.filename, row.checksum?.trim() || null]));
}

async function applyMigration(client, filename, sql, sqlChecksum) {
  console.log(`→ Applying ${filename} ...`);
  try {
    await client.query("BEGIN");
    await client.query(sql);
    await client.query(
      "INSERT INTO schema_migrations (filename, checksum) VALUES ($1, $2)",
      [filename, sqlChecksum]
    );
    await client.query("COMMIT");
    console.log(`✅ Applied ${filename}`);
  } catch (err) {
    await client.query("ROLLBACK");
    console.error(`❌ Migration failed (${filename}):`, err.message);
    throw err;
  }
}

async function run() {
  let client;
  try {
    if (!process.env.DATABASE_URL) {
      throw new Error("DATABASE_URL is not set. Please add it to .env");
    }

    const migrationsDir = path.join(process.cwd(), "src", "migrations");
    if (!fs.existsSync(migrationsDir)) {
      console.log("No migrations directory found; nothing to do.");
      return;
    }

    client = await pool.connect();
    // A session-level lock covers discovery, checksum verification, and every
    // migration transaction, preventing two deploys from racing each other.
    await client.query("SELECT pg_advisory_lock(hashtext($1))", [MIGRATION_LOCK_KEY]);
    await ensureMigrationsTable(client);
    const applied = await getApplied(client);

    const files = fs
      .readdirSync(migrationsDir)
      .filter((f) => f.endsWith(".sql"))
      .sort();

    const fileSet = new Set(files);
    const missingAppliedFile = [...applied.keys()].find((filename) => !fileSet.has(filename));
    if (missingAppliedFile) {
      throw new Error(`Applied migration file is missing: ${missingAppliedFile}`);
    }

    for (const f of files) {
      const sql = fs.readFileSync(path.join(migrationsDir, f), "utf8");
      if (!sql.trim()) continue;
      const sqlChecksum = checksum(sql);
      const appliedChecksum = applied.get(f);

      if (applied.has(f)) {
        if (appliedChecksum == null) {
          // Legacy rows predate checksums. Pin the deployed repository content
          // once; every subsequent edit is rejected.
          await client.query(
            "UPDATE schema_migrations SET checksum = $2 WHERE filename = $1 AND checksum IS NULL",
            [f, sqlChecksum]
          );
        } else if (appliedChecksum !== sqlChecksum) {
          throw new Error(`Applied migration was modified: ${f}`);
        }
        continue;
      }

      await applyMigration(client, f, sql, sqlChecksum);
    }

    console.log("🏁 Migrations complete");
    process.exitCode = 0;
  } catch (err) {
    console.error("❌ migrate.js failed:", err.message);
    process.exitCode = 1;
  } finally {
    if (client) {
      try {
        await client.query("SELECT pg_advisory_unlock(hashtext($1))", [MIGRATION_LOCK_KEY]);
      } finally {
        client.release();
      }
    }
    await pool.end();
  }
}

run();


