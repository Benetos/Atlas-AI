-- Resumable private staging and atomic activation for Atlas-AI NMS imports.

create table nms_private.staged_records (
  import_run_id uuid not null
    references nms_private.import_runs(id) on delete cascade,
  target text not null
    check (target in (
      'entities',
      'localizations',
      'recipes',
      'recipe_ingredients',
      'content_records',
      'assets'
    )),
  record_key text not null,
  source_ordinal integer not null check (source_ordinal >= 0),
  payload jsonb not null,
  payload_sha256 text not null
    check (payload_sha256 ~ '^[0-9a-f]{64}$'),
  primary key (import_run_id, target, record_key, source_ordinal)
);

create index staged_records_target_idx
  on nms_private.staged_records (import_run_id, target);

alter table nms_private.staged_records enable row level security;

grant select, insert, update, delete
  on table nms_private.staged_records to service_role;

create or replace function nms_private.activate_import(p_import_run_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public, nms_private
as $function$
declare
  v_manifest jsonb;
  v_source_commit_sha text;
  v_status text;
  v_source_records bigint;
  v_stage_counts jsonb;
begin
  perform pg_advisory_xact_lock(
    pg_catalog.hashtextextended('atlas-ai:nms-import', 0)
  );

  select manifest, source_commit_sha, status
    into v_manifest, v_source_commit_sha, v_status
  from nms_private.import_runs
  where id = p_import_run_id
  for update;

  if not found then
    raise exception 'Unknown NMS import run: %', p_import_run_id;
  end if;

  if v_status not in ('staged', 'validated', 'active') then
    raise exception 'Import run % has non-activatable status %',
      p_import_run_id, v_status;
  end if;

  if coalesce((v_manifest #>> '{validation,passed}')::boolean, false) is not true then
    raise exception 'Import run % did not pass transform validation', p_import_run_id;
  end if;

  select count(*) into v_source_records
  from nms_private.source_records
  where import_run_id = p_import_run_id;

  if v_source_records <> (v_manifest #>> '{outputs,source_records.csv,rows}')::bigint then
    raise exception 'source_records count mismatch: expected %, found %',
      v_manifest #>> '{outputs,source_records.csv,rows}', v_source_records;
  end if;

  select coalesce(jsonb_object_agg(target, row_count), '{}'::jsonb)
    into v_stage_counts
  from (
    select target, count(*)::bigint as row_count
    from nms_private.staged_records
    where import_run_id = p_import_run_id
    group by target
  ) counts;

  if coalesce((v_stage_counts ->> 'entities')::bigint, 0)
      <> (v_manifest #>> '{outputs,entities.csv,rows}')::bigint then
    raise exception 'entities count mismatch: expected %, found %',
      v_manifest #>> '{outputs,entities.csv,rows}',
      coalesce(v_stage_counts ->> 'entities', '0');
  end if;
  if coalesce((v_stage_counts ->> 'localizations')::bigint, 0)
      <> (v_manifest #>> '{outputs,localizations.csv,rows}')::bigint then
    raise exception 'localizations count mismatch: expected %, found %',
      v_manifest #>> '{outputs,localizations.csv,rows}',
      coalesce(v_stage_counts ->> 'localizations', '0');
  end if;
  if coalesce((v_stage_counts ->> 'recipes')::bigint, 0)
      <> (v_manifest #>> '{outputs,recipes.csv,rows}')::bigint then
    raise exception 'recipes count mismatch: expected %, found %',
      v_manifest #>> '{outputs,recipes.csv,rows}',
      coalesce(v_stage_counts ->> 'recipes', '0');
  end if;
  if coalesce((v_stage_counts ->> 'recipe_ingredients')::bigint, 0)
      <> (v_manifest #>> '{outputs,recipe_ingredients.csv,rows}')::bigint then
    raise exception 'recipe_ingredients count mismatch: expected %, found %',
      v_manifest #>> '{outputs,recipe_ingredients.csv,rows}',
      coalesce(v_stage_counts ->> 'recipe_ingredients', '0');
  end if;
  if coalesce((v_stage_counts ->> 'content_records')::bigint, 0)
      <> (v_manifest #>> '{outputs,content_records.csv,rows}')::bigint then
    raise exception 'content_records count mismatch: expected %, found %',
      v_manifest #>> '{outputs,content_records.csv,rows}',
      coalesce(v_stage_counts ->> 'content_records', '0');
  end if;
  if coalesce((v_stage_counts ->> 'assets')::bigint, 0)
      <> (v_manifest #>> '{outputs,assets.csv,rows}')::bigint then
    raise exception 'assets count mismatch: expected %, found %',
      v_manifest #>> '{outputs,assets.csv,rows}',
      coalesce(v_stage_counts ->> 'assets', '0');
  end if;

  if exists (
    select 1
    from nms_private.staged_records
    where import_run_id = p_import_run_id
      and payload ->> 'source_commit_sha' is distinct from v_source_commit_sha
  ) then
    raise exception 'One or more staged rows do not match source commit %',
      v_source_commit_sha;
  end if;

  update nms_private.import_runs
  set status = 'validated', finished_at = now(), error_message = null
  where id = p_import_run_id;

  insert into public.nms_entities (
    entity_type, game_id, name_id, name_lower_id, subtitle_id,
    description_id, name, display_name, subtitle, description, category,
    subcategory, rarity, legality, base_value, icon_source_path,
    icon_storage_path, color_r, color_g, color_b, color_a, attributes,
    source_dataset, source_commit_sha, updated_at
  )
  select
    row_data.entity_type, row_data.game_id, row_data.name_id,
    row_data.name_lower_id, row_data.subtitle_id, row_data.description_id,
    row_data.name, row_data.display_name, row_data.subtitle,
    row_data.description, row_data.category, row_data.subcategory,
    row_data.rarity, row_data.legality, row_data.base_value,
    row_data.icon_source_path, row_data.icon_storage_path,
    row_data.color_r, row_data.color_g, row_data.color_b, row_data.color_a,
    row_data.attributes, row_data.source_dataset,
    row_data.source_commit_sha, now()
  from nms_private.staged_records staged
  cross join lateral jsonb_to_record(staged.payload) as row_data(
    entity_type text, game_id text, name_id text, name_lower_id text,
    subtitle_id text, description_id text, name text, display_name text,
    subtitle text, description text, category text, subcategory text,
    rarity text, legality text, base_value numeric, icon_source_path text,
    icon_storage_path text, color_r numeric, color_g numeric, color_b numeric,
    color_a numeric, attributes jsonb, source_dataset text,
    source_commit_sha text
  )
  where staged.import_run_id = p_import_run_id
    and staged.target = 'entities'
  on conflict (entity_type, game_id) do update set
    name_id = excluded.name_id,
    name_lower_id = excluded.name_lower_id,
    subtitle_id = excluded.subtitle_id,
    description_id = excluded.description_id,
    name = excluded.name,
    display_name = excluded.display_name,
    subtitle = excluded.subtitle,
    description = excluded.description,
    category = excluded.category,
    subcategory = excluded.subcategory,
    rarity = excluded.rarity,
    legality = excluded.legality,
    base_value = excluded.base_value,
    icon_source_path = excluded.icon_source_path,
    icon_storage_path = excluded.icon_storage_path,
    color_r = excluded.color_r,
    color_g = excluded.color_g,
    color_b = excluded.color_b,
    color_a = excluded.color_a,
    attributes = excluded.attributes,
    source_dataset = excluded.source_dataset,
    source_commit_sha = excluded.source_commit_sha,
    updated_at = excluded.updated_at;

  update public.nms_localizations
  set is_preferred = false
  where source_commit_sha <> v_source_commit_sha
    and is_preferred;

  insert into public.nms_localizations (
    localization_id, locale, source_ordinal, value, is_preferred,
    source_commit_sha
  )
  select
    row_data.localization_id, row_data.locale, row_data.source_ordinal,
    row_data.value, row_data.is_preferred, row_data.source_commit_sha
  from nms_private.staged_records staged
  cross join lateral jsonb_to_record(staged.payload) as row_data(
    localization_id text, locale text, source_ordinal integer, value text,
    is_preferred boolean, source_commit_sha text
  )
  where staged.import_run_id = p_import_run_id
    and staged.target = 'localizations'
  on conflict (localization_id, locale, source_ordinal) do update set
    value = excluded.value,
    is_preferred = excluded.is_preferred,
    source_commit_sha = excluded.source_commit_sha;

  insert into public.nms_recipes (
    recipe_id, recipe_kind, output_entity_type, output_game_id,
    output_amount, time_seconds, recipe_type, recipe_name, source_ordinal,
    attributes, source_commit_sha
  )
  select
    row_data.recipe_id, row_data.recipe_kind,
    row_data.output_entity_type, row_data.output_game_id,
    row_data.output_amount, row_data.time_seconds, row_data.recipe_type,
    row_data.recipe_name, row_data.source_ordinal, row_data.attributes,
    row_data.source_commit_sha
  from nms_private.staged_records staged
  cross join lateral jsonb_to_record(staged.payload) as row_data(
    recipe_id text, recipe_kind text, output_entity_type text,
    output_game_id text, output_amount numeric, time_seconds numeric,
    recipe_type text, recipe_name text, source_ordinal integer,
    attributes jsonb, source_commit_sha text
  )
  where staged.import_run_id = p_import_run_id
    and staged.target = 'recipes'
  on conflict (recipe_id) do update set
    recipe_kind = excluded.recipe_kind,
    output_entity_type = excluded.output_entity_type,
    output_game_id = excluded.output_game_id,
    output_amount = excluded.output_amount,
    time_seconds = excluded.time_seconds,
    recipe_type = excluded.recipe_type,
    recipe_name = excluded.recipe_name,
    source_ordinal = excluded.source_ordinal,
    attributes = excluded.attributes,
    source_commit_sha = excluded.source_commit_sha;

  insert into public.nms_recipe_ingredients (
    recipe_id, position, ingredient_entity_type, ingredient_game_id,
    amount, attributes, source_commit_sha
  )
  select
    row_data.recipe_id, row_data.position,
    row_data.ingredient_entity_type, row_data.ingredient_game_id,
    row_data.amount, row_data.attributes, row_data.source_commit_sha
  from nms_private.staged_records staged
  cross join lateral jsonb_to_record(staged.payload) as row_data(
    recipe_id text, position integer, ingredient_entity_type text,
    ingredient_game_id text, amount numeric, attributes jsonb,
    source_commit_sha text
  )
  where staged.import_run_id = p_import_run_id
    and staged.target = 'recipe_ingredients'
  on conflict (recipe_id, position) do update set
    ingredient_entity_type = excluded.ingredient_entity_type,
    ingredient_game_id = excluded.ingredient_game_id,
    amount = excluded.amount,
    attributes = excluded.attributes,
    source_commit_sha = excluded.source_commit_sha;

  insert into public.nms_content_records (
    dataset, external_id, source_ordinal, display_name, icon_source_path,
    payload, source_commit_sha, updated_at
  )
  select
    row_data.dataset, row_data.external_id, row_data.source_ordinal,
    row_data.display_name, row_data.icon_source_path, row_data.payload,
    row_data.source_commit_sha, now()
  from nms_private.staged_records staged
  cross join lateral jsonb_to_record(staged.payload) as row_data(
    dataset text, external_id text, source_ordinal integer,
    display_name text, icon_source_path text, payload jsonb,
    source_commit_sha text
  )
  where staged.import_run_id = p_import_run_id
    and staged.target = 'content_records'
  on conflict (dataset, external_id, source_ordinal) do update set
    display_name = excluded.display_name,
    icon_source_path = excluded.icon_source_path,
    payload = excluded.payload,
    source_commit_sha = excluded.source_commit_sha,
    updated_at = excluded.updated_at;

  insert into public.nms_assets (
    source_commit_sha, source_path, upstream_png_path, storage_bucket,
    storage_path, mime_type, content_sha256, byte_size, status,
    referenced_by, updated_at
  )
  select
    row_data.source_commit_sha, row_data.source_path,
    row_data.upstream_png_path, row_data.storage_bucket,
    row_data.storage_path, row_data.mime_type, row_data.content_sha256,
    row_data.byte_size, row_data.status, row_data.referenced_by, now()
  from nms_private.staged_records staged
  cross join lateral jsonb_to_record(staged.payload) as row_data(
    source_commit_sha text, source_path text, upstream_png_path text,
    storage_bucket text, storage_path text, mime_type text,
    content_sha256 text, byte_size bigint, status text, referenced_by jsonb
  )
  where staged.import_run_id = p_import_run_id
    and staged.target = 'assets'
  on conflict (source_commit_sha, source_path) do update set
    upstream_png_path = excluded.upstream_png_path,
    storage_bucket = excluded.storage_bucket,
    storage_path = excluded.storage_path,
    mime_type = excluded.mime_type,
    content_sha256 = excluded.content_sha256,
    byte_size = excluded.byte_size,
    status = excluded.status,
    referenced_by = excluded.referenced_by,
    updated_at = excluded.updated_at;

  delete from public.nms_recipe_ingredients
  where source_commit_sha <> v_source_commit_sha;
  delete from public.nms_recipes
  where source_commit_sha <> v_source_commit_sha;
  delete from public.nms_localizations
  where source_commit_sha <> v_source_commit_sha;
  delete from public.nms_content_records
  where source_commit_sha <> v_source_commit_sha;
  delete from public.nms_entities
  where source_commit_sha <> v_source_commit_sha;

  update nms_private.import_runs
  set status = 'superseded'
  where status = 'active'
    and id <> p_import_run_id;

  update nms_private.import_runs
  set status = 'active',
      finished_at = now(),
      activated_at = now(),
      error_message = null
  where id = p_import_run_id;

  delete from nms_private.staged_records
  where import_run_id = p_import_run_id;

  return jsonb_build_object(
    'import_run_id', p_import_run_id,
    'source_commit_sha', v_source_commit_sha,
    'source_records', v_source_records,
    'staged_rows', v_stage_counts,
    'status', 'active'
  );
end;
$function$;

revoke all on function nms_private.activate_import(uuid)
  from public, anon, authenticated;
grant execute on function nms_private.activate_import(uuid)
  to service_role;

comment on table nms_private.staged_records is
  'Resumable normalized import batches, removed after atomic activation.';
comment on function nms_private.activate_import(uuid) is
  'Validates a staged NMS import against its manifest and atomically promotes it.';
