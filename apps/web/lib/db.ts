import { mkdir, readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { PGlite } from "@electric-sql/pglite";
import pg from "pg";

const databaseUrl = process.env.DATABASE_URL?.trim() ?? "";
const root = process.cwd();

let pool: pg.Pool | undefined;
let local: Promise<PGlite> | undefined;
let localReady: Promise<void> | undefined;

export async function sql<T = Record<string, unknown>>(
  text: string,
  params: unknown[] = [],
): Promise<T[]> {
  if (databaseUrl !== "") {
    pool ??= new pg.Pool({ connectionString: databaseUrl, max: 5 });
    return (await pool.query(text, params)).rows as T[];
  }
  const db = await getLocal();
  return (await db.query<T>(text, params)).rows;
}

async function getLocal(): Promise<PGlite> {
  local ??= startLocal().catch((error: unknown) => {
    local = undefined;
    localReady = undefined;
    throw error;
  });
  const db = await local;
  localReady ??= ensureLocalSeed(db);
  await localReady;
  return db;
}

async function startLocal(): Promise<PGlite> {
  const dataDir = path.join(root, ".data", "pglite");
  await mkdir(dataDir, { recursive: true });
  const db = new PGlite(dataDir);
  await db.waitReady;
  const files = (await readdir(path.join(root, "migrations")).catch(() => []))
    .filter((f) => f.endsWith(".sql"))
    .sort();
  await db.exec(
    "create table if not exists schema_migrations (name text primary key, applied_at timestamptz not null default now())",
  );
  const done = new Set(
    (
      await db.query<{ name: string }>("select name from schema_migrations")
    ).rows.map((row) => row.name),
  );
  for (const file of files.filter((f) => !done.has(f))) {
    await db.exec(await readFile(path.join(root, "migrations", file), "utf8"));
    await db.query("insert into schema_migrations (name) values ($1)", [file]);
  }
  return db;
}

async function ensureLocalSeed(db: PGlite): Promise<void> {
  const existing = await db.query<{ source_commit_sha: string }>(
    "select source_commit_sha from pack_manifest limit 1",
  );
  if (existing.rows.length > 0) return;
  // Dev fallback: expect `npm run load-pack` (or build) to have populated data.
  // Avoid importing the heavy loader into the request path.
  const counts = await db.query<{ entities: number }>(
    "select count(*)::int as entities from nms_entities",
  );
  if ((counts.rows[0]?.entities ?? 0) === 0) {
    throw new Error(
      "Pack data is empty. Run `npm run migrate && npm run load-pack` in apps/web (or use python3 server.py with the SQLite pack).",
    );
  }
}
