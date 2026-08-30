# Supabase deployment record

## Active development project

- Project: `Atlas-AI`
- Project reference: `amgezynqenbgopnnpxso`
- Organization: `Benetos's Org`
- Region: `us-east-2`
- PostgreSQL: 17
- Initial migration: `20260830043257_nms_reference_schema`
- Migration applied: 2026-08-29 (America/Chicago)

The project reference and API URL are public identifiers, not credentials.
Never commit database passwords, secret keys, or service-role keys.

## Deployed foundation

The initial migration created:

- `nms_private.import_runs`
- `nms_private.source_records`
- `public.nms_entities`
- `public.nms_localizations`
- `public.nms_recipes`
- `public.nms_recipe_ingredients`
- `public.nms_content_records`
- `public.nms_assets`

All tables have RLS enabled. `anon` and `authenticated` receive `SELECT` only
on the six public reference tables. They receive no access to `nms_private`.
Future public tables and functions use opt-in grants through explicit default
privilege revocation.

## Verification snapshot

- Migration history contains exactly the initial Atlas-AI migration.
- All eight expected tables exist with their primary and foreign keys.
- Security advisor: no warning or error findings.
- Performance advisor: only expected unused-index informational findings on
  empty tables.
- Private-table no-policy notices are intentional: the schema is not exposed,
  public roles have no schema usage, and only `service_role` has table grants.
- Generated live TypeScript definitions are stored at
  `supabase/types/database.ts`.

## Legacy NMS project decision

The older `NMS` project was inspected but not modified. It contains 1,103 rows
across five flattened legacy data tables plus an empty `profiles` table. Its
schema uses columns such as `RequiredItems/0/Id` and has legacy security-advisor
warnings. Atlas-AI therefore uses a clean, separate Supabase project.

## Next deployment gate

The schema is ready but intentionally empty. Before the first bulk import:

1. Reproduce the pinned transform and confirm zero blocking validation errors.
2. Build a transactional loader for the seven generated CSV/JSONL outputs.
3. Load and reconcile counts against `manifest.json`.
4. Test anonymous reads and rejected mutations through the Data API.
5. Keep asset blob upload disabled until the licensing/publication gate passes.
