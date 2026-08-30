# Initial Atlas-AI NMS import

## Result

The first pinned NMS-Handbook structured dataset is active in the Atlas-AI
Supabase project.

- Supabase project reference: `amgezynqenbgopnnpxso`
- Import run: `987e1f86-e6a7-53c7-a191-8264e0c3f371`
- Upstream repository: `ApexFatality93/NMS-Handbook`
- Source commit: `142d9ffd8078944722243398202f22cbef47cd02`
- Contract version: 1
- Import status: `active`
- Activated: 2026-08-30

No image blobs were downloaded or uploaded. The asset rows are references and
future Storage destinations only.

## Reproducibility and validation

The source was regenerated from the pinned sparse checkout immediately before
the import. The transform completed with zero blocking errors and 17 warnings:
16 upstream image paths had no matching PNG and 23 localization IDs had more
than one historical value. Duplicate localization history is intentionally
retained; one value per ID and locale is marked preferred.

`scripts/prepare_nms_import.py` independently verified all seven output hashes
and produced 127 resumable SQL batches. The batches staged 184,530 rows in the
private schema. Atomic activation revalidated every count and source SHA before
writing the public tables, then removed all normalized staging rows.

## Reconciled counts

| Dataset | Rows |
|---|---:|
| Lossless private source records | 88,009 |
| Canonical entities | 2,597 |
| English localization history | 79,756 |
| Recipes | 2,181 |
| Recipe ingredients | 4,003 |
| Feature content records | 4,752 |
| Asset references | 3,232 |
| Remaining normalized staging rows | 0 |

## Integrity checks

- Staged source-commit mismatches: 0
- Missing recipe output entities: 0
- Missing ingredient entities: 0
- Duplicate preferred localization values per ID/locale: 0
- Representative three-ingredient cooking recipe joined successfully.
- Full-text search for `ferrite dust` used the
  `nms_entities_search_idx` GIN index.

## API and security checks

- Anonymous entity search returned HTTP 200 with Ferrite Dust, Pure Ferrite,
  and Magnetised Ferrite.
- Anonymous insert returned `42501` / HTTP 401.
- A Data API request targeting `nms_private` returned `PGRST106` / HTTP 406;
  only `public` and `graphql_public` are exposed.
- Supabase security advisors reported no warning or error findings.
- The three private tables produce informational no-policy notices by design:
  RLS is enabled, the schema is not exposed, and public roles have no access.
- Performance advisors reported only unused-index informational notices. Those
  are expected immediately after the first load; an explicit search plan
  confirmed the primary full-text index is selected.

## Next gate

Structured data is ready for application queries. Image publication remains a
separate approval because upstream game-derived assets have different rights
and storage implications from the structured dataset.
