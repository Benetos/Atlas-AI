# Supabase deployment record

## Active development project

- Project: `Atlas-AI`
- Project reference: `amgezynqenbgopnnpxso`
- Organization: `Benetos's Org`
- Region: `us-east-2`
- PostgreSQL: 17
- Initial migration: `20260830043257_nms_reference_schema`
- Import pipeline migration: `20260830044648_nms_import_pipeline`
- Migration applied: 2026-08-29 (America/Chicago)

The project reference and API URL are public identifiers, not credentials.
Never commit database passwords, secret keys, or service-role keys.

## Deployed foundation

The reference-schema and import-pipeline migrations created:

- `nms_private.import_runs`
- `nms_private.source_records`
- `nms_private.staged_records`
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

- Migration history contains the two Atlas-AI migrations listed above.
- All nine expected tables exist with their primary and foreign keys.
- Security advisor: no warning or error findings.
- At initial schema deployment, the performance advisor reported only expected
  unused-index informational findings on the then-empty tables. Post-import
  verification is recorded in `docs/INITIAL_IMPORT.md`.
- Private-table no-policy notices are intentional: the schema is not exposed,
  public roles have no schema usage, and only `service_role` has table grants.
- Generated live TypeScript definitions are stored at
  `supabase/types/database.ts`.

## Active data revision

- Import run: `987e1f86-e6a7-53c7-a191-8264e0c3f371`
- Source commit: `142d9ffd8078944722243398202f22cbef47cd02`
- Status: `active`
- Activated: 2026-08-30
- Full verification: `docs/INITIAL_IMPORT.md`

## Legacy NMS project decision

The older `NMS` project was inspected but not modified. It contains 1,103 rows
across five flattened legacy data tables plus an empty `profiles` table. Its
schema uses columns such as `RequiredItems/0/Id` and has legacy security-advisor
warnings. Atlas-AI therefore uses a clean, separate Supabase project.

## Next deployment gate

The structured baseline is active. Asset blob upload remains disabled until the
licensing/publication gate passes. The next engineering step is a manually
dispatched GitHub Action that reproduces the validated transform and submits the
same resumable private batches under protected environment approval.
