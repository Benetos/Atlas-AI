/**
 * Load NMS pack facts into Postgres/PGlite from pack/web-seed
 * (exported from the same transform → SQLite pipeline).
 *
 * Seed gzips intentionally live outside apps/web so Cursor publish-app does
 * not ship downloadable archives in the hosted project tree. Hosted builds
 * fetch them from GitHub raw into .data/seed-cache, load DATABASE_URL, then
 * delete the cache.
 */
import { createGunzip } from "node:zlib";
import { createReadStream } from "node:fs";
import { mkdir, readFile, access, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import readline from "node:readline";
import pg from "pg";
import { PGlite } from "@electric-sql/pglite";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const url = process.env.DATABASE_URL?.trim() ?? "";
const PUBLIC_SOURCE_REPO = "https://github.com/ApexFatality93/NMS-Handbook";
const SEED_FILES = [
  "pack_manifest.json",
  "entities.jsonl.gz",
  "recipes.jsonl.gz",
  "recipe_ingredients.jsonl.gz",
  "content_records.jsonl.gz",
];

async function dirHasSeed(dir) {
  try {
    for (const name of SEED_FILES) {
      await access(path.join(dir, name));
    }
    return true;
  } catch {
    return false;
  }
}

function seedFileUrls(repo, repoPath, ref, name) {
  // Keep slashes in branch refs (encodeURIComponent would break cursor/foo).
  const refPath = String(ref)
    .split("/")
    .map((part) => encodeURIComponent(part))
    .join("/");
  return [
    `https://raw.githubusercontent.com/${repo}/${refPath}/${repoPath}/${name}`,
    // jsDelivr as a second path if GitHub raw is blocked on the build host.
    `https://cdn.jsdelivr.net/gh/${repo}@${refPath}/${repoPath}/${name}`,
  ];
}

async function downloadSeedTo(cacheDir, repo, repoPath, ref) {
  await mkdir(cacheDir, { recursive: true });
  for (const name of SEED_FILES) {
    const urls = seedFileUrls(repo, repoPath, ref, name);
    let buf = null;
    let lastError = null;
    for (const urlPath of urls) {
      try {
        const res = await fetch(urlPath);
        if (!res.ok) {
          lastError = new Error(`GET ${urlPath} -> ${res.status}`);
          continue;
        }
        buf = Buffer.from(await res.arrayBuffer());
        break;
      } catch (error) {
        lastError = error;
      }
    }
    if (!buf) {
      throw lastError ?? new Error(`failed to download ${name}`);
    }
    await writeFile(path.join(cacheDir, name), buf);
  }
}

async function resolveSeedDir() {
  const fromEnv = process.env.SEED_DIR?.trim();
  if (fromEnv && (await dirHasSeed(fromEnv))) {
    console.log(`load_pack: using SEED_DIR ${fromEnv}`);
    return { dir: fromEnv, ephemeral: false };
  }

  const repoSeed = path.resolve(root, "..", "..", "pack", "web-seed");
  if (await dirHasSeed(repoSeed)) {
    console.log(`load_pack: using repo seed ${repoSeed}`);
    return { dir: repoSeed, ephemeral: false };
  }

  // Optional in-tree build seed (must never live under public/).
  const buildSeed = path.join(root, "build-seed");
  if (await dirHasSeed(buildSeed)) {
    console.log(`load_pack: using build-seed ${buildSeed}`);
    return { dir: buildSeed, ephemeral: false };
  }

  // Legacy local path (must not be present in publish tree).
  const legacy = path.join(root, "seed");
  if (await dirHasSeed(legacy)) {
    console.log(`load_pack: using legacy ${legacy}`);
    return { dir: legacy, ephemeral: false };
  }

  const source = JSON.parse(
    await readFile(path.join(root, "seed-source.json"), "utf8"),
  );
  const cacheDir = path.join(root, ".data", "seed-cache");
  const refs = [
    process.env.ATLAS_SEED_GIT_REF,
    process.env.VERCEL_GIT_COMMIT_REF,
    process.env.VERCEL_GIT_COMMIT_SHA,
    ...(source.preferredRefs ?? []),
  ].filter(Boolean);

  let lastError = null;
  for (const ref of refs) {
    try {
      console.log(
        `load_pack: fetching ${source.githubRepo}/${source.repoPath} @ ${ref}`,
      );
      await downloadSeedTo(
        cacheDir,
        source.githubRepo,
        source.repoPath,
        ref,
      );
      if (await dirHasSeed(cacheDir)) {
        return { dir: cacheDir, ephemeral: true };
      }
    } catch (error) {
      lastError = error;
      console.warn(`load_pack: ref ${ref} failed: ${error.message ?? error}`);
    }
  }

  throw new Error(
    `Unable to locate pack seed (tried SEED_DIR, ${repoSeed}, GitHub refs). Last error: ${lastError?.message ?? lastError}`,
  );
}

async function scrubEphemeralSeed(seedInfo) {
  if (!seedInfo?.ephemeral) return;
  try {
    await rm(seedInfo.dir, { recursive: true, force: true });
    console.log(`load_pack: scrubbed ephemeral seed cache ${seedInfo.dir}`);
  } catch (error) {
    console.warn(`load_pack: scrub failed: ${error.message ?? error}`);
  }
}

let seedDir = null;
let seedInfo = null;

const ENTITY_COLS = [
  "entity_type",
  "game_id",
  "name_id",
  "name_lower_id",
  "subtitle_id",
  "description_id",
  "name",
  "display_name",
  "subtitle",
  "description",
  "category",
  "subcategory",
  "rarity",
  "legality",
  "base_value",
  "icon_source_path",
  "icon_storage_path",
  "color_r",
  "color_g",
  "color_b",
  "color_a",
  "attributes",
  "source_dataset",
  "source_commit_sha",
];
const RECIPE_COLS = [
  "recipe_id",
  "recipe_kind",
  "output_entity_type",
  "output_game_id",
  "output_amount",
  "time_seconds",
  "recipe_type",
  "recipe_name",
  "source_ordinal",
  "attributes",
  "source_commit_sha",
];
const INGREDIENT_COLS = [
  "recipe_id",
  "position",
  "ingredient_entity_type",
  "ingredient_game_id",
  "amount",
  "attributes",
  "source_commit_sha",
];
const CONTENT_COLS = [
  "dataset",
  "external_id",
  "source_ordinal",
  "display_name",
  "icon_source_path",
  "payload",
  "source_commit_sha",
];

async function readJsonlGz(filePath) {
  const stream = createReadStream(filePath).pipe(createGunzip());
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
  const rows = [];
  for await (const line of rl) {
    if (!line.trim()) continue;
    rows.push(JSON.parse(line));
  }
  return rows;
}

async function insertBatch(query, table, cols, rows, castInts = new Set()) {
  const chunkSize = 100;
  for (let offset = 0; offset < rows.length; offset += chunkSize) {
    const chunk = rows.slice(offset, offset + chunkSize);
    const values = [];
    const params = [];
    let idx = 1;
    for (const row of chunk) {
      const slots = [];
      for (const col of cols) {
        slots.push(`$${idx}`);
        let value = row[col];
        if (castInts.has(col) && value != null) value = Number(value);
        if ((col === "attributes" || col === "payload") && value == null) {
          value = "{}";
        }
        if (
          (col === "attributes" || col === "payload") &&
          typeof value === "object"
        ) {
          value = JSON.stringify(value);
        }
        params.push(value);
        idx += 1;
      }
      values.push(`(${slots.join(", ")})`);
    }
    await query(
      `insert into ${table} (${cols.join(", ")}) values ${values.join(", ")}`,
      params,
    );
  }
}

async function loadWithQuery(query, runTx) {
  const manifest = JSON.parse(
    await readFile(path.join(seedDir, "pack_manifest.json"), "utf8"),
  );
  const expectedCommit = manifest.source_commit_sha;
  const existing = await query(
    "select source_commit_sha from pack_manifest limit 1",
  );
  if (existing[0]?.source_commit_sha === expectedCommit) {
    const counts = await query(
      `select
         (select count(*)::int from nms_entities) as entities,
         (select count(*)::int from nms_recipes) as recipes,
         (select count(*)::int from nms_recipe_ingredients) as recipe_ingredients,
         (select count(*)::int from nms_content_records) as content_records`,
    );
    console.log(
      `load_pack: already loaded commit ${expectedCommit.slice(0, 12)}`,
      counts[0],
    );
    return counts[0];
  }

  const entities = await readJsonlGz(path.join(seedDir, "entities.jsonl.gz"));
  const recipes = await readJsonlGz(path.join(seedDir, "recipes.jsonl.gz"));
  const ingredients = await readJsonlGz(
    path.join(seedDir, "recipe_ingredients.jsonl.gz"),
  );
  const content = await readJsonlGz(
    path.join(seedDir, "content_records.jsonl.gz"),
  );

  if (entities.length !== (manifest.counts?.entities ?? -1)) {
    throw new Error(
      `seed entities ${entities.length} != manifest ${manifest.counts?.entities}`,
    );
  }
  if (recipes.length !== (manifest.counts?.recipes ?? -1)) {
    throw new Error(
      `seed recipes ${recipes.length} != manifest ${manifest.counts?.recipes}`,
    );
  }
  if (ingredients.length !== (manifest.counts?.recipe_ingredients ?? -1)) {
    throw new Error(
      `seed ingredients ${ingredients.length} != manifest ${manifest.counts?.recipe_ingredients}`,
    );
  }
  if (content.length !== (manifest.counts?.content_records ?? -1)) {
    throw new Error(
      `seed content ${content.length} != manifest ${manifest.counts?.content_records}`,
    );
  }

  await runTx(async () => {
    await query("delete from nms_recipe_ingredients");
    await query("delete from nms_recipes");
    await query("delete from nms_content_records");
    await query("delete from nms_entities");
    await query("delete from pack_manifest");

    await insertBatch(query, "nms_entities", ENTITY_COLS, entities);
    await insertBatch(
      query,
      "nms_recipes",
      RECIPE_COLS,
      recipes,
      new Set(["source_ordinal"]),
    );
    await insertBatch(
      query,
      "nms_recipe_ingredients",
      INGREDIENT_COLS,
      ingredients,
      new Set(["position"]),
    );
    await insertBatch(
      query,
      "nms_content_records",
      CONTENT_COLS,
      content,
      new Set(["source_ordinal"]),
    );

    await query(
      `insert into pack_manifest (
         pack_schema_version, contract_version, source_repository,
         source_commit_sha, source_committed_at, generated_at,
         counts_json, input_manifest_sha256
       ) values ($1,$2,$3,$4,$5,$6,$7,$8)`,
      [
        manifest.pack_schema_version,
        manifest.contract_version,
        PUBLIC_SOURCE_REPO,
        manifest.source_commit_sha,
        manifest.source_committed_at ?? null,
        manifest.generated_at,
        JSON.stringify(manifest.counts),
        manifest.input_manifest_sha256 ?? "",
      ],
    );
  });

  const counts = {
    entities: entities.length,
    recipes: recipes.length,
    recipe_ingredients: ingredients.length,
    content_records: content.length,
  };
  console.log(`load_pack: loaded commit ${expectedCommit}`, counts);
  return counts;
}

async function loadPostgres() {
  const client = new pg.Client({
    connectionString: process.env.DATABASE_URL_UNPOOLED?.trim() || url,
  });
  await client.connect();
  try {
    await client.query("set lock_timeout = '120s'");
    await client.query("select pg_advisory_lock(7272742)");
    return await loadWithQuery(
      async (text, params = []) => (await client.query(text, params)).rows,
      async (fn) => {
        await client.query("begin");
        try {
          await fn();
          await client.query("commit");
        } catch (error) {
          await client.query("rollback");
          throw error;
        }
      },
    );
  } finally {
    try {
      await client.query("select pg_advisory_unlock(7272742)");
    } catch {
      /* ignore */
    }
    await client.end();
  }
}

async function loadPglite() {
  const dataDir = path.join(root, ".data", "pglite");
  await mkdir(dataDir, { recursive: true });
  const db = new PGlite(dataDir);
  await db.waitReady;
  try {
    return await loadWithQuery(
      async (text, params = []) => (await db.query(text, params)).rows,
      async (fn) => {
        await db.exec("begin");
        try {
          await fn();
          await db.exec("commit");
        } catch (error) {
          await db.exec("rollback");
          throw error;
        }
      },
    );
  } finally {
    await db.close();
  }
}

seedInfo = await resolveSeedDir();
seedDir = seedInfo.dir;
try {
  if (url !== "") {
    await loadPostgres();
  } else {
    console.log("load_pack: DATABASE_URL unset; loading into local PGlite");
    await loadPglite();
  }
} finally {
  await scrubEphemeralSeed(seedInfo);
}
