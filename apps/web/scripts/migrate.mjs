import { mkdir, readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { PGlite } from "@electric-sql/pglite";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const migrationsDir = path.join(root, "migrations");
const url = process.env.DATABASE_URL?.trim() ?? "";

async function listMigrationFiles() {
  return (await readdir(migrationsDir).catch(() => []))
    .filter((f) => f.endsWith(".sql"))
    .sort();
}

async function applyWithClient({ query, execSql, runTx }) {
  const files = await listMigrationFiles();
  if (files.length === 0) {
    console.log("migrate: nothing to do");
    return;
  }
  await execSql(
    "create table if not exists schema_migrations (name text primary key, applied_at timestamptz not null default now())",
  );
  const doneRows = await query("select name from schema_migrations");
  const done = new Set(doneRows.map((row) => row.name));
  for (const file of files.filter((f) => !done.has(f))) {
    const sqlText = await readFile(path.join(migrationsDir, file), "utf8");
    await runTx(async () => {
      await execSql(sqlText);
      await query("insert into schema_migrations (name) values ($1)", [file]);
    });
    console.log(`migrate: applied ${file}`);
  }
}

async function migratePostgres() {
  const client = new pg.Client({
    connectionString: process.env.DATABASE_URL_UNPOOLED?.trim() || url,
  });
  await client.connect();
  try {
    await client.query("set lock_timeout = '60s'");
    await client.query("select pg_advisory_lock(7272741)");
    await applyWithClient({
      query: async (text, params = []) => (await client.query(text, params)).rows,
      execSql: async (text) => {
        await client.query(text);
      },
      runTx: async (fn) => {
        await client.query("begin");
        try {
          await fn();
          await client.query("commit");
        } catch (error) {
          await client.query("rollback");
          throw error;
        }
      },
    });
  } finally {
    try {
      await client.query("select pg_advisory_unlock(7272741)");
    } catch {
      /* ignore */
    }
    await client.end();
  }
}

async function migratePglite() {
  const dataDir = path.join(root, ".data", "pglite");
  await mkdir(dataDir, { recursive: true });
  const db = new PGlite(dataDir);
  await db.waitReady;
  await applyWithClient({
    query: async (text, params = []) => (await db.query(text, params)).rows,
    execSql: async (text) => {
      await db.exec(text);
    },
    runTx: async (fn) => {
      await db.exec("begin");
      try {
        await fn();
        await db.exec("commit");
      } catch (error) {
        await db.exec("rollback");
        throw error;
      }
    },
  });
  await db.close();
}

if (url !== "") {
  await migratePostgres();
} else {
  console.log("migrate: DATABASE_URL unset; applying to local PGlite");
  await migratePglite();
}
