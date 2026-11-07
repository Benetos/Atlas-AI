-- Atlas web companion pack schema (same contract as the SQLite pack).
-- Additive only. Tables mirror the offline pack the iOS app reads.

create table if not exists pack_manifest (
  pack_schema_version integer not null,
  contract_version integer not null,
  source_repository text not null,
  source_commit_sha text not null
    check (source_commit_sha ~ '^[0-9a-f]{40}$'),
  source_committed_at text,
  generated_at text not null,
  counts_json text not null,
  input_manifest_sha256 text not null
);

create table if not exists nms_entities (
  entity_type text not null
    check (entity_type in ('product', 'substance', 'technology')),
  game_id text not null,
  name_id text,
  name_lower_id text,
  subtitle_id text,
  description_id text,
  name text,
  display_name text,
  subtitle text,
  description text,
  category text,
  subcategory text,
  rarity text,
  legality text,
  base_value text,
  icon_source_path text,
  icon_storage_path text,
  color_r text,
  color_g text,
  color_b text,
  color_a text,
  attributes text not null default '{}',
  source_dataset text not null,
  source_commit_sha text not null
    check (source_commit_sha ~ '^[0-9a-f]{40}$'),
  primary key (entity_type, game_id)
);

create index if not exists nms_entities_display_name_idx
  on nms_entities (lower(coalesce(display_name, name, game_id)));

create index if not exists nms_entities_type_idx
  on nms_entities (entity_type);

create table if not exists nms_recipes (
  recipe_id text primary key,
  recipe_kind text not null
    check (recipe_kind in ('crafting', 'refining', 'cooking')),
  output_entity_type text not null
    check (output_entity_type in ('product', 'substance', 'technology')),
  output_game_id text not null,
  output_amount text,
  time_seconds text,
  recipe_type text,
  recipe_name text,
  source_ordinal integer not null check (source_ordinal >= 0),
  attributes text not null default '{}',
  source_commit_sha text not null
    check (source_commit_sha ~ '^[0-9a-f]{40}$'),
  foreign key (output_entity_type, output_game_id)
    references nms_entities (entity_type, game_id)
);

create index if not exists nms_recipes_output_idx
  on nms_recipes (output_entity_type, output_game_id);

create index if not exists nms_recipes_kind_idx
  on nms_recipes (recipe_kind);

create table if not exists nms_recipe_ingredients (
  recipe_id text not null
    references nms_recipes (recipe_id) on delete cascade,
  position integer not null check (position >= 0),
  ingredient_entity_type text not null
    check (ingredient_entity_type in ('product', 'substance', 'technology')),
  ingredient_game_id text not null,
  amount text,
  attributes text not null default '{}',
  source_commit_sha text not null
    check (source_commit_sha ~ '^[0-9a-f]{40}$'),
  primary key (recipe_id, position),
  foreign key (ingredient_entity_type, ingredient_game_id)
    references nms_entities (entity_type, game_id)
);

create index if not exists nms_recipe_ingredients_entity_idx
  on nms_recipe_ingredients (ingredient_entity_type, ingredient_game_id);

create table if not exists nms_content_records (
  dataset text not null,
  external_id text not null,
  source_ordinal integer not null check (source_ordinal >= 0),
  display_name text,
  icon_source_path text,
  payload text not null,
  source_commit_sha text not null
    check (source_commit_sha ~ '^[0-9a-f]{40}$'),
  primary key (dataset, external_id, source_ordinal)
);

create index if not exists nms_content_records_name_idx
  on nms_content_records (dataset, lower(coalesce(display_name, external_id)));
