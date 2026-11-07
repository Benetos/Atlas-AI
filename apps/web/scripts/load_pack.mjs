/**
 * Load NMS pack facts into Postgres/PGlite from the committed seed
 * (exported from the same transform → SQLite pipeline).
 */
import { createGunzip } from "node:zlib";
import { createReadStream } from "node:fs";
import { mkdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import readline from "node:readline";
import pg from "pg";
import { PGlite } from "@electric-sql/pglite";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const seedDir = path.join(root, "seed");
const url = process.env.DATABASE_URL?.trim() ?? "";
const PUBLIC_SOURCE_REPO = "https://github.com/ApexFatality93/NMS-Handbook";

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

if (url !== "") {
  await loadPostgres();
} else {
  console.log("load_pack: DATABASE_URL unset; loading into local PGlite");
  await loadPglite();
}
