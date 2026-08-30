# Supabase architecture and ingestion runbook

## Architecture

Use three boundaries:

- `nms_private`: unexposed import audit and lossless source records.
- `public`: explicitly exposed, read-only application tables.
- Supabase Storage: optional approved images and other binary assets.

Bulk ingestion connects directly to Postgres with a protected database URL.
The mobile/web app uses only a Supabase publishable key and can read approved
public tables through the Data API. Secret/service-role credentials never ship
in a client.

## Current Supabase platform considerations

- New tables are moving to opt-in Data API exposure. Schema migrations must
  include explicit `GRANT` statements; RLS alone does not expose a table.
- Every exposed table has RLS enabled even when its intended contents are
  public.
- `anon` and `authenticated` receive `SELECT` only for reference data.
- Loader writes use a direct Postgres connection or server-side secret. They do
  not use the REST API for bulk import.
- If views are added later, use `security_invoker = true` on supported Postgres
  versions and verify their grants/RLS behavior.

## Prerequisites

1. A development Supabase project separate from production.
2. Current Supabase CLI (2.81.3 or newer for database advisors).
3. PostgreSQL client tools (`psql`).
4. A direct/session-pooler database URL stored only in a local secret manager or
   GitHub Actions secret.
5. A backup/restore point before production imports.

Never commit any of the following:

```text
DATABASE_URL
SUPABASE_SECRET_KEY
SUPABASE_SERVICE_ROLE_KEY
database passwords
```

## 1. Fetch a pinned source snapshot

The analyzed initial revision is pinned explicitly:

```bash
NMS_SOURCE_REF=142d9ffd8078944722243398202f22cbef47cd02 \
  ./scripts/sync_nms_source.sh
```

Using `main` is acceptable for discovery, but the resulting resolved SHA in the
manifest must be reviewed before importing.

## 2. Transform and validate

```bash
python3 scripts/transform_nms.py \
  --source-dir .cache/nms-handbook/JSON_Files \
  --source-repo .cache/nms-handbook \
  --output-dir build/nms-import
```

Blocking validations:

- All required source files exist and parse.
- Top-level source shapes match the contract.
- Canonical entity identities are unique.
- Recipe IDs and ingredient positions are unique.
- Recipe types are recognized.
- Ingredient references resolve to canonical entities.
- A 40-character source commit is available.
- Every generated output hash is recorded.

Advisory validations:

- Localization conflicts.
- Referenced image paths missing from the upstream PNG tree.
- Record-count changes from the prior approved manifest.
- New or removed source fields.

Do not import if the manifest reports blocking errors.

## 3. Promote the schema into a migration

The repository contains a reviewable schema source at
`supabase/schema/nms_reference_schema.sql`. The Supabase CLI is intentionally
not vendored.

After installing the current CLI:

```bash
supabase --version
supabase migration new nms_reference_schema
```

Copy the reviewed schema into the CLI-generated migration file. Do not invent a
migration timestamp manually. Then start local Supabase and apply/test the
migration using the commands reported by the installed CLI's `--help` output.

Before committing the generated migration:

```bash
supabase db advisors
supabase migration list --local
```

Fix all security findings and relevant performance findings.

## 4. Load into temporary staging tables

Production-scale loads should use Postgres `COPY`. The exact `psql` command
depends on the environment and connection string, but the pattern is:

```sql
begin;

create temporary table stage_entities
(like public.nms_entities including defaults)
on commit drop;

-- psql client command, not server SQL:
\copy stage_entities (...) from 'build/nms-import/entities.csv' with (format csv, header true, encoding 'UTF8');

-- Repeat for localizations, recipes, ingredients, content records, and assets.
-- Source records load to a temporary table shaped like nms_private.source_records.
```

The loader first inserts an `nms_private.import_runs` row with status `staged`.
Every staged row is associated with that import-run ID during the merge.

## 5. Reconcile staging before merge

Inside the same controlled session, verify:

```sql
select count(*) from stage_entities;
select entity_type, count(*) from stage_entities group by entity_type;
select count(*) from stage_recipes;
select count(*) from stage_recipe_ingredients;

-- Must return zero.
select count(*)
from stage_recipe_ingredients i
left join stage_entities e
  on e.entity_type = i.ingredient_entity_type
 and e.game_id = i.ingredient_game_id
where e.game_id is null;
```

Compare these counts with `manifest.json`. Also compare source/output SHA-256
values in the trusted runner before opening the database transaction.

## 6. Transactional merge

Merge in dependency order:

1. Import-run audit row.
2. Private source records.
3. Entities.
4. Localizations.
5. Recipes.
6. Recipe ingredients.
7. Feature content records.
8. Asset metadata.

Use `INSERT ... ON CONFLICT ... DO UPDATE` for current rows and remove rows from
the previous source revision only after all staged checks pass. Mark the new run
`active` and the former active run `superseded` in the same transaction.

On any error, roll back. A failed run may be recorded afterward as `failed`, but
must not partially modify active application data.

## 7. Verify API security and behavior

Required checks:

- Anonymous `SELECT` on each approved public table succeeds.
- Anonymous and authenticated `INSERT`, `UPDATE`, and `DELETE` fail.
- `nms_private` is not in the Data API exposed-schema list.
- Public roles have no `USAGE` on `nms_private`.
- Search uses the `nms_entities_search_idx` GIN index.
- Counts match the activated manifest.
- Representative recipes return output and ordered ingredients.

If the Data API returns `42501`, review explicit grants and the project's Data
API settings. Do not weaken RLS to solve a missing grant.

## 8. Asset ingestion

Asset ingestion is optional and legally gated.

The transform emits `assets.csv` without downloading image blobs. It maps source
DDS/PNG references to case-resolved upstream PNG paths using Git tree metadata.

When publication is approved:

1. Create the `nms-assets` bucket. Use a private bucket during review; switch to
   public only if unrestricted public delivery is approved.
2. Fetch only manifest rows whose status is `referenced` and whose upstream PNG
   path exists.
3. Compute SHA-256 and byte size before upload.
4. Upload to immutable paths:

   ```text
   <source-commit-sha>/<lowercase-upstream-png-path>
   ```

5. Update `nms_assets` to `uploaded` only after the Storage response is verified.
6. Never overwrite an object from an older commit. Reconcile and garbage-collect
   old revisions separately after the rollback window.

The app resolves an image through `nms_assets.storage_path`; a missing, blocked,
or not-yet-uploaded asset renders a bundled placeholder.

## 9. GitHub Actions rollout

Start with `workflow_dispatch`, not a schedule:

1. Operator supplies a source ref.
2. Runner sparse-clones and transforms.
3. Validation report and manifest become build artifacts.
4. A protected environment approval gates database merge.
5. Asset upload is a separate protected job and defaults to disabled.

After several successful imports, add a scheduled job that only detects a new
upstream SHA and opens an issue or pull request. It should not auto-activate new
game data without validation and review.

## Rollback

Rollback inputs are the prior source commit, prior transform manifest, and the
database backup/retained prior import.

Preferred first-release rollback:

1. Keep at least one superseded revision and its Storage namespace.
2. Re-run the deterministic merge from the prior manifest or restore the
   pre-import database backup.
3. Mark the failed revision `failed` and reactivate the prior run only after row
   counts and representative queries pass.

Do not delete prior assets as part of the import transaction.
