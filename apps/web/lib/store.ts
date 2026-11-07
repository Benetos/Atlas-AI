import { sql } from "./db";

const PUBLIC_SOURCE_REPO = "https://github.com/ApexFatality93/NMS-Handbook";
const SOURCE_COMMIT_RE = /^[0-9a-f]{40}$/;
const TOKEN_RE = /[A-Za-z0-9_]+/g;
const RECIPE_SEARCH_GLUE = new Set([
  "cook",
  "cooked",
  "cooking",
  "craft",
  "crafted",
  "crafting",
  "make",
  "making",
  "recipe",
  "recipes",
  "refine",
  "refined",
  "refiner",
  "refining",
]);

export type Entity = {
  entity_type: string;
  game_id: string;
  name: string | null;
  display_name: string | null;
  subtitle: string | null;
  description: string | null;
  category: string | null;
  subcategory: string | null;
  rarity: string | null;
  legality: string | null;
  base_value: string | null;
  color_r: string | null;
  color_g: string | null;
  color_b: string | null;
  source_dataset: string | null;
  source_commit_sha: string;
  title: string;
};

export type Ingredient = {
  recipe_id: string;
  position: number;
  entity_type: string;
  game_id: string;
  amount: string | null;
  title: string;
};

export type Recipe = {
  recipe_id: string;
  recipe_kind: string;
  output_entity_type: string;
  output_game_id: string;
  output_amount: string | null;
  time_seconds: string | null;
  recipe_type: string | null;
  recipe_name: string | null;
  source_ordinal: number;
  source_commit_sha: string;
  output_title: string;
  ingredients: Ingredient[];
};

export type ContentRecord = {
  dataset: string;
  external_id: string;
  source_ordinal: number;
  display_name: string | null;
  payload: string;
  source_commit_sha: string;
  title: string;
};

export type Manifest = {
  pack_schema_version: number;
  contract_version: number;
  source_repository: string;
  source_commit_sha: string;
  source_committed_at: string | null;
  generated_at: string;
  counts: Record<string, number>;
  input_manifest_sha256: string;
  attribution: string;
  private_notice: string;
};

const ENTITY_SELECT = `
  entity_type, game_id, name, display_name, subtitle, description,
  category, subcategory, rarity, legality, base_value,
  color_r, color_g, color_b, source_dataset, source_commit_sha
`;

const RECIPE_SELECT = `
  r.recipe_id, r.recipe_kind, r.output_entity_type, r.output_game_id,
  r.output_amount, r.time_seconds, r.recipe_type, r.recipe_name,
  r.source_ordinal, r.source_commit_sha,
  coalesce(e.display_name, e.name, r.output_game_id) as output_title
`;

function mapEntity(row: Record<string, unknown>): Entity {
  return {
    entity_type: String(row.entity_type),
    game_id: String(row.game_id),
    name: (row.name as string | null) ?? null,
    display_name: (row.display_name as string | null) ?? null,
    subtitle: (row.subtitle as string | null) ?? null,
    description: (row.description as string | null) ?? null,
    category: (row.category as string | null) ?? null,
    subcategory: (row.subcategory as string | null) ?? null,
    rarity: (row.rarity as string | null) ?? null,
    legality: (row.legality as string | null) ?? null,
    base_value: row.base_value == null ? null : String(row.base_value),
    color_r: row.color_r == null ? null : String(row.color_r),
    color_g: row.color_g == null ? null : String(row.color_g),
    color_b: row.color_b == null ? null : String(row.color_b),
    source_dataset: (row.source_dataset as string | null) ?? null,
    source_commit_sha: String(row.source_commit_sha),
    title: String(row.display_name || row.name || row.game_id),
  };
}

function mapRecipe(row: Record<string, unknown>): Recipe {
  return {
    recipe_id: String(row.recipe_id),
    recipe_kind: String(row.recipe_kind),
    output_entity_type: String(row.output_entity_type),
    output_game_id: String(row.output_game_id),
    output_amount: row.output_amount == null ? null : String(row.output_amount),
    time_seconds: row.time_seconds == null ? null : String(row.time_seconds),
    recipe_type: (row.recipe_type as string | null) ?? null,
    recipe_name: (row.recipe_name as string | null) ?? null,
    source_ordinal: Number(row.source_ordinal),
    source_commit_sha: String(row.source_commit_sha),
    output_title: String(row.output_title),
    ingredients: [],
  };
}

function mapContent(row: Record<string, unknown>): ContentRecord {
  return {
    dataset: String(row.dataset),
    external_id: String(row.external_id),
    source_ordinal: Number(row.source_ordinal),
    display_name: (row.display_name as string | null) ?? null,
    payload: typeof row.payload === "string" ? row.payload : JSON.stringify(row.payload),
    source_commit_sha: String(row.source_commit_sha),
    title: String(row.display_name || row.external_id),
  };
}

function searchTokens(raw: string): string[] {
  return (raw.toLowerCase().match(TOKEN_RE) ?? []).map((t) => t.toLowerCase());
}

function escapeLike(value: string): string {
  return value.replaceAll("\\", "\\\\").replaceAll("%", "\\%").replaceAll("_", "\\_");
}

function recipeKindFromTokens(tokenList: string[]): string | null {
  if (tokenList.some((t) => ["cook", "cooked", "cooking"].includes(t))) {
    return "cooking";
  }
  if (
    tokenList.some((t) =>
      ["refine", "refined", "refiner", "refining"].includes(t),
    )
  ) {
    return "refining";
  }
  if (tokenList.some((t) => ["craft", "crafted", "crafting"].includes(t))) {
    return "crafting";
  }
  return null;
}

function uniquePrefix<T>(
  values: T[],
  limit: number,
  keyFn: (value: T) => string,
): T[] {
  const seen = new Set<string>();
  const result: T[] = [];
  for (const value of values) {
    const key = keyFn(value);
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(value);
    if (result.length >= limit) break;
  }
  return result;
}

async function ingredientsFor(recipeId: string): Promise<Ingredient[]> {
  const rows = await sql(
    `
    select i.recipe_id, i.position, i.ingredient_entity_type, i.ingredient_game_id,
           i.amount, coalesce(e.display_name, e.name, i.ingredient_game_id) as title
      from nms_recipe_ingredients i
      left join nms_entities e
        on e.entity_type = i.ingredient_entity_type
       and e.game_id = i.ingredient_game_id
     where i.recipe_id = $1
     order by i.position
    `,
    [recipeId],
  );
  return rows.map((row) => ({
    recipe_id: String(row.recipe_id),
    position: Number(row.position),
    entity_type: String(row.ingredient_entity_type),
    game_id: String(row.ingredient_game_id),
    amount: row.amount == null ? null : String(row.amount),
    title: String(row.title),
  }));
}

async function hydrateRecipe(recipe: Recipe): Promise<Recipe> {
  recipe.ingredients = await ingredientsFor(recipe.recipe_id);
  return recipe;
}

export async function getManifest(): Promise<Manifest> {
  const rows = await sql(
    `
    select pack_schema_version, contract_version, source_repository,
           source_commit_sha, source_committed_at, generated_at, counts_json,
           input_manifest_sha256
      from pack_manifest
    `,
  );
  if (rows.length !== 1) {
    throw new Error(
      `Atlas pack must contain exactly one manifest row; found ${rows.length}.`,
    );
  }
  const row = rows[0]!;
  const packSchemaVersion = Number(row.pack_schema_version);
  const contractVersion = Number(row.contract_version);
  if (packSchemaVersion !== 1) {
    throw new Error(`Unsupported pack schema version ${packSchemaVersion}.`);
  }
  if (contractVersion !== 1) {
    throw new Error(`Unsupported contract version ${contractVersion}.`);
  }
  const commit = String(row.source_commit_sha);
  if (!SOURCE_COMMIT_RE.test(commit)) {
    throw new Error("Invalid source commit SHA in pack_manifest.");
  }
  const countsRaw =
    typeof row.counts_json === "string"
      ? JSON.parse(row.counts_json)
      : row.counts_json;
  if (!countsRaw || typeof countsRaw !== "object") {
    throw new Error("pack_manifest.counts_json must be an object.");
  }
  const counts: Record<string, number> = {};
  for (const [key, value] of Object.entries(countsRaw as Record<string, unknown>)) {
    counts[key] = Number(value);
  }
  return {
    pack_schema_version: packSchemaVersion,
    contract_version: contractVersion,
    source_repository: PUBLIC_SOURCE_REPO,
    source_commit_sha: commit,
    source_committed_at: (row.source_committed_at as string | null) ?? null,
    generated_at: String(row.generated_at),
    counts,
    input_manifest_sha256: String(row.input_manifest_sha256 ?? ""),
    attribution:
      "Structured data transformed from ApexFatality93/NMS-Handbook (GPL-3.0).",
    private_notice:
      "Private Atlas companion. Licensing posture remains internal.",
  };
}

export async function getEntity(
  entityType: string,
  gameId: string,
): Promise<Entity | null> {
  const rows = await sql(
    `select ${ENTITY_SELECT} from nms_entities where entity_type = $1 and game_id = $2`,
    [entityType, gameId],
  );
  return rows[0] ? mapEntity(rows[0]) : null;
}

export async function listEntities(
  entityType: string,
  limit = 100,
  offset = 0,
): Promise<Entity[]> {
  const rows = await sql(
    `
    select ${ENTITY_SELECT}
      from nms_entities
     where entity_type = $1
     order by lower(coalesce(display_name, name, game_id))
     limit $2 offset $3
    `,
    [entityType, limit, offset],
  );
  return rows.map(mapEntity);
}

export async function searchEntities(
  query: string,
  entityType: string | null = null,
  limit = 20,
): Promise<Entity[]> {
  const tokenList = searchTokens(query);
  if (!tokenList.length || limit <= 0) return [];

  const params: unknown[] = [];
  let sqlText = `
    select ${ENTITY_SELECT}
      from nms_entities e
     where 1 = 1
  `;
  if (entityType) {
    params.push(entityType);
    sqlText += ` and e.entity_type = $${params.length}`;
  }
  const columns = [
    "e.entity_type",
    "e.game_id",
    "e.name",
    "e.display_name",
    "e.subtitle",
    "e.description",
    "e.category",
    "e.subcategory",
    "e.rarity",
    "e.legality",
    "e.source_dataset",
  ];
  for (const token of tokenList) {
    const predicates = columns
      .map((column) => {
        params.push(`%${escapeLike(token)}%`);
        return `lower(coalesce(${column}, '')) like $${params.length} escape '\\'`;
      })
      .join(" or ");
    sqlText += ` and (${predicates})`;
  }
  const normalized = query.trim().toLowerCase();
  params.push(normalized, normalized, normalized, limit);
  sqlText += `
     order by case
                when lower(coalesce(e.display_name, e.name, e.game_id)) = $${params.length - 3} then 0
                when lower(e.game_id) = $${params.length - 2} then 1
                when lower(e.entity_type) = $${params.length - 1} then 2
                else 3
              end,
              lower(coalesce(e.display_name, e.name, e.game_id))
     limit $${params.length}
  `;
  const rows = await sql(sqlText, params);
  return uniquePrefix(rows.map(mapEntity), limit, (e) => `${e.entity_type}:${e.game_id}`);
}

export async function listRecipes(
  kind: string | null = null,
  limit = 100,
  offset = 0,
): Promise<Recipe[]> {
  const params: unknown[] = [];
  let sqlText = `
    select ${RECIPE_SELECT}
      from nms_recipes r
      left join nms_entities e
        on e.entity_type = r.output_entity_type
       and e.game_id = r.output_game_id
  `;
  if (kind) {
    params.push(kind);
    sqlText += ` where r.recipe_kind = $${params.length}`;
  }
  params.push(limit, offset);
  sqlText += ` order by lower(coalesce(r.recipe_name, e.display_name, r.recipe_id)) limit $${params.length - 1} offset $${params.length}`;
  const rows = await sql(sqlText, params);
  return Promise.all(rows.map((row) => hydrateRecipe(mapRecipe(row))));
}

export async function searchRecipes(
  query: string,
  kind: string | null = null,
  limit = 20,
): Promise<Recipe[]> {
  const rawTokens = searchTokens(query);
  const resolvedKind = kind ?? recipeKindFromTokens(rawTokens);
  const tokenList = rawTokens.filter((token) => !RECIPE_SEARCH_GLUE.has(token));
  if ((!tokenList.length && resolvedKind == null) || limit <= 0) return [];

  const params: unknown[] = [];
  let sqlText = `
    select ${RECIPE_SELECT}
      from nms_recipes r
      left join nms_entities e
        on e.entity_type = r.output_entity_type
       and e.game_id = r.output_game_id
     where 1 = 1
  `;
  if (resolvedKind) {
    params.push(resolvedKind);
    sqlText += ` and r.recipe_kind = $${params.length}`;
  }
  for (const token of tokenList) {
    params.push(`%${escapeLike(token)}%`);
    sqlText += `
      and lower(
            coalesce(r.recipe_name, '') || ' ' ||
            coalesce(e.display_name, e.name, '') || ' ' ||
            r.output_game_id
          ) like $${params.length} escape '\\'
    `;
  }
  params.push(limit);
  sqlText += ` order by lower(coalesce(r.recipe_name, e.display_name, r.recipe_id)) limit $${params.length}`;
  const rows = await sql(sqlText, params);
  return Promise.all(rows.map((row) => hydrateRecipe(mapRecipe(row))));
}

export async function getRecipe(recipeId: string): Promise<Recipe | null> {
  const rows = await sql(
    `
    select ${RECIPE_SELECT}
      from nms_recipes r
      left join nms_entities e
        on e.entity_type = r.output_entity_type
       and e.game_id = r.output_game_id
     where r.recipe_id = $1
    `,
    [recipeId],
  );
  if (!rows[0]) return null;
  return hydrateRecipe(mapRecipe(rows[0]));
}

export async function recipesProducing(
  entityType: string,
  gameId: string,
  limit = 10_000,
): Promise<Recipe[]> {
  if (limit <= 0) return [];
  const rows = await sql(
    `
    select ${RECIPE_SELECT}
      from nms_recipes r
      left join nms_entities e
        on e.entity_type = r.output_entity_type
       and e.game_id = r.output_game_id
     where r.output_entity_type = $1 and r.output_game_id = $2
     order by r.recipe_kind, r.recipe_id
     limit $3
    `,
    [entityType, gameId, limit],
  );
  return Promise.all(rows.map((row) => hydrateRecipe(mapRecipe(row))));
}

export async function recipesUsing(
  entityType: string,
  gameId: string,
  limit = 10_000,
): Promise<Recipe[]> {
  if (limit <= 0) return [];
  const rows = await sql(
    `
    select ${RECIPE_SELECT}
      from nms_recipe_ingredients i
      join nms_recipes r on r.recipe_id = i.recipe_id
      left join nms_entities e
        on e.entity_type = r.output_entity_type
       and e.game_id = r.output_game_id
     where i.ingredient_entity_type = $1 and i.ingredient_game_id = $2
     order by r.recipe_kind, r.recipe_id
     limit $3
    `,
    [entityType, gameId, limit],
  );
  return Promise.all(rows.map((row) => hydrateRecipe(mapRecipe(row))));
}

export async function searchContent(
  query: string,
  dataset: string | null = null,
  limit = 5,
): Promise<ContentRecord[]> {
  const tokenList = searchTokens(query);
  if (!tokenList.length || limit <= 0) return [];

  const params: unknown[] = [];
  let sqlText = `
    select dataset, external_id, source_ordinal, display_name, payload, source_commit_sha
      from nms_content_records
     where 1 = 1
  `;
  if (dataset) {
    params.push(dataset);
    sqlText += ` and dataset = $${params.length}`;
  }
  const columns = ["dataset", "external_id", "display_name", "payload"];
  for (const token of tokenList) {
    const predicates = columns
      .map((column) => {
        params.push(`%${escapeLike(token)}%`);
        return `lower(coalesce(${column}::text, '')) like $${params.length} escape '\\'`;
      })
      .join(" or ");
    sqlText += ` and (${predicates})`;
  }
  params.push(limit);
  sqlText += ` order by lower(coalesce(display_name, external_id)) limit $${params.length}`;
  const rows = await sql(sqlText, params);
  return uniquePrefix(
    rows.map(mapContent),
    limit,
    (r) => `${r.dataset}:${r.external_id}:${r.source_ordinal}`,
  );
}
