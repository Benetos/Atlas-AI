-- Atlas-AI NMS reference schema source.
--
-- Review this file, then create a migration with:
--   supabase migration new nms_reference_schema
-- Copy this SQL into the CLI-generated migration file. Do not invent a
-- migration timestamp by hand.

create schema if not exists nms_private;

revoke all on schema nms_private from public, anon, authenticated;
grant usage on schema nms_private to service_role;

-- Keep future API exposure opt-in. Every public table below receives only the
-- explicit grants declared alongside its RLS policies.
alter default privileges for role postgres in schema public
  revoke select, insert, update, delete on tables
  from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke usage, select on sequences
  from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke execute on functions
  from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke execute on functions from public;

create table nms_private.import_runs (
  id uuid primary key default gen_random_uuid(),
  source_repository text not null,
  source_commit_sha text not null
    check (source_commit_sha ~ '^[0-9a-f]{40}$'),
  source_committed_at timestamptz,
  status text not null default 'staged'
    check (status in ('staged', 'validated', 'active', 'failed', 'superseded')),
  manifest jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  activated_at timestamptz,
  error_message text,
  unique (source_repository, source_commit_sha)
);

create unique index import_runs_one_active_idx
  on nms_private.import_runs (status)
  where status = 'active';

create table nms_private.source_records (
  import_run_id uuid not null
    references nms_private.import_runs(id) on delete cascade,
  dataset text not null,
  external_id text not null,
  source_ordinal integer not null check (source_ordinal >= 0),
  payload jsonb not null,
  payload_sha256 text not null
    check (payload_sha256 ~ '^[0-9a-f]{64}$'),
  primary key (import_run_id, dataset, external_id, source_ordinal)
);

create index source_records_dataset_idx
  on nms_private.source_records (import_run_id, dataset);

alter table nms_private.import_runs enable row level security;
alter table nms_private.source_records enable row level security;

create table public.nms_entities (
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
  base_value numeric,
  icon_source_path text,
  icon_storage_path text,
  color_r numeric check (color_r is null or color_r between 0 and 1),
  color_g numeric check (color_g is null or color_g between 0 and 1),
  color_b numeric check (color_b is null or color_b between 0 and 1),
  color_a numeric check (color_a is null or color_a between 0 and 1),
  attributes jsonb not null default '{}'::jsonb,
  source_dataset text not null,
  source_commit_sha text not null
    check (source_commit_sha ~ '^[0-9a-f]{40}$'),
  updated_at timestamptz not null default now(),
  search_vector tsvector generated always as (
    setweight(to_tsvector('english', coalesce(display_name, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(name, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(subtitle, '')), 'B') ||
    setweight(to_tsvector('english', coalesce(description, '')), 'C')
  ) stored,
  primary key (entity_type, game_id)
);

create index nms_entities_display_name_idx
  on public.nms_entities (lower(display_name));

create index nms_entities_category_idx
  on public.nms_entities (entity_type, category);

create index nms_entities_search_idx
  on public.nms_entities using gin (search_vector);

create table public.nms_localizations (
  localization_id text not null,
  locale text not null default 'en',
  source_ordinal integer not null check (source_ordinal >= 0),
  value text not null,
  is_preferred boolean not null default false,
  source_commit_sha text not null
    check (source_commit_sha ~ '^[0-9a-f]{40}$'),
  primary key (localization_id, locale, source_ordinal)
);

create unique index nms_localizations_one_preferred_idx
  on public.nms_localizations (localization_id, locale)
  where is_preferred;

create index nms_localizations_value_search_idx
  on public.nms_localizations using gin (to_tsvector('english', value));

create table public.nms_recipes (
  recipe_id text primary key,
  recipe_kind text not null
    check (recipe_kind in ('crafting', 'refining', 'cooking')),
  output_entity_type text not null
    check (output_entity_type in ('product', 'substance', 'technology')),
  output_game_id text not null,
  output_amount numeric check (output_amount is null or output_amount >= 0),
  time_seconds numeric check (time_seconds is null or time_seconds >= 0),
  recipe_type text,
  recipe_name text,
  source_ordinal integer not null check (source_ordinal >= 0),
  attributes jsonb not null default '{}'::jsonb,
  source_commit_sha text not null
    check (source_commit_sha ~ '^[0-9a-f]{40}$'),
  foreign key (output_entity_type, output_game_id)
    references public.nms_entities (entity_type, game_id)
    on update cascade
);

create index nms_recipes_output_idx
  on public.nms_recipes (output_entity_type, output_game_id);

create index nms_recipes_kind_idx
  on public.nms_recipes (recipe_kind);

create table public.nms_recipe_ingredients (
  recipe_id text not null
    references public.nms_recipes(recipe_id) on delete cascade,
  position integer not null check (position >= 0),
  ingredient_entity_type text not null
    check (ingredient_entity_type in ('product', 'substance', 'technology')),
  ingredient_game_id text not null,
  amount numeric check (amount is null or amount >= 0),
  attributes jsonb not null default '{}'::jsonb,
  source_commit_sha text not null
    check (source_commit_sha ~ '^[0-9a-f]{40}$'),
  primary key (recipe_id, position),
  foreign key (ingredient_entity_type, ingredient_game_id)
    references public.nms_entities (entity_type, game_id)
    on update cascade
);

create index nms_recipe_ingredients_entity_idx
  on public.nms_recipe_ingredients
  (ingredient_entity_type, ingredient_game_id);

create table public.nms_content_records (
  dataset text not null,
  external_id text not null,
  source_ordinal integer not null check (source_ordinal >= 0),
  display_name text,
  icon_source_path text,
  payload jsonb not null,
  source_commit_sha text not null
    check (source_commit_sha ~ '^[0-9a-f]{40}$'),
  updated_at timestamptz not null default now(),
  primary key (dataset, external_id, source_ordinal)
);

create index nms_content_records_name_idx
  on public.nms_content_records (dataset, lower(display_name));

create index nms_content_records_payload_idx
  on public.nms_content_records using gin (payload jsonb_path_ops);

create table public.nms_assets (
  source_commit_sha text not null
    check (source_commit_sha ~ '^[0-9a-f]{40}$'),
  source_path text not null,
  upstream_png_path text,
  storage_bucket text,
  storage_path text,
  mime_type text not null default 'image/png',
  content_sha256 text
    check (content_sha256 is null or content_sha256 ~ '^[0-9a-f]{64}$'),
  byte_size bigint check (byte_size is null or byte_size >= 0),
  status text not null default 'referenced'
    check (status in ('referenced', 'missing', 'approved', 'uploaded', 'blocked')),
  referenced_by jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (source_commit_sha, source_path)
);

create index nms_assets_status_idx
  on public.nms_assets (source_commit_sha, status);

comment on schema nms_private is
  'Unexposed NMS import audit and lossless source staging.';
comment on table public.nms_entities is
  'Canonical No Man''s Sky products, substances, and technologies.';
comment on table public.nms_content_records is
  'Lossless feature records awaiting app-driven typed projections.';
comment on table public.nms_assets is
  'Versioned source-to-Supabase Storage asset manifest.';

alter table public.nms_entities enable row level security;
alter table public.nms_localizations enable row level security;
alter table public.nms_recipes enable row level security;
alter table public.nms_recipe_ingredients enable row level security;
alter table public.nms_content_records enable row level security;
alter table public.nms_assets enable row level security;

grant usage on schema public to anon, authenticated, service_role;

revoke all on table public.nms_entities from anon, authenticated;
revoke all on table public.nms_localizations from anon, authenticated;
revoke all on table public.nms_recipes from anon, authenticated;
revoke all on table public.nms_recipe_ingredients from anon, authenticated;
revoke all on table public.nms_content_records from anon, authenticated;
revoke all on table public.nms_assets from anon, authenticated;

grant select on table public.nms_entities to anon, authenticated;
grant select on table public.nms_localizations to anon, authenticated;
grant select on table public.nms_recipes to anon, authenticated;
grant select on table public.nms_recipe_ingredients to anon, authenticated;
grant select on table public.nms_content_records to anon, authenticated;
grant select on table public.nms_assets to anon, authenticated;

grant select, insert, update, delete on table public.nms_entities to service_role;
grant select, insert, update, delete on table public.nms_localizations to service_role;
grant select, insert, update, delete on table public.nms_recipes to service_role;
grant select, insert, update, delete on table public.nms_recipe_ingredients to service_role;
grant select, insert, update, delete on table public.nms_content_records to service_role;
grant select, insert, update, delete on table public.nms_assets to service_role;
grant select, insert, update, delete on table nms_private.import_runs to service_role;
grant select, insert, update, delete on table nms_private.source_records to service_role;

create policy nms_entities_public_read
  on public.nms_entities for select
  to anon, authenticated
  using (true);

create policy nms_localizations_public_read
  on public.nms_localizations for select
  to anon, authenticated
  using (true);

create policy nms_recipes_public_read
  on public.nms_recipes for select
  to anon, authenticated
  using (true);

create policy nms_recipe_ingredients_public_read
  on public.nms_recipe_ingredients for select
  to anon, authenticated
  using (true);

create policy nms_content_records_public_read
  on public.nms_content_records for select
  to anon, authenticated
  using (true);

create policy nms_assets_public_read
  on public.nms_assets for select
  to anon, authenticated
  using (true);
