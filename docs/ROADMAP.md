# NMS data assimilation roadmap

## Outcome

Atlas-AI will maintain a reproducible, queryable, and updateable No Man's Sky
reference dataset in Supabase without copying the entire upstream repository
into Atlas-AI's Git history.

The target pipeline is:

```text
Pinned upstream commit
  -> sparse local cache
  -> deterministic transform and validation
  -> private Supabase staging
  -> transactional merge
  -> read-only public API tables
  -> versioned Storage assets
```

## Guiding decisions

1. **Pin every import.** Every dataset and asset is traceable to a full Git
   commit SHA, source URL, input hash, and import run.
2. **Preserve before normalizing.** Every upstream record is retained losslessly
   in a private JSONB staging table. Stable app concepts are also projected into
   typed public tables.
3. **Bulk-load through Postgres.** The generated CSVs are loaded through
   `COPY`, not thousands of Data API requests.
4. **Expose an intentional API.** Private staging is outside the Data API.
   Public reference tables are read-only, explicitly granted, and protected by
   RLS.
5. **Treat assets as versioned data.** Images are addressed by source commit and
   stored outside Postgres. The first import may omit images while preserving
   every source path in an asset manifest.
6. **Do not over-normalize unknown features.** Recipes and canonical entities
   are normalized immediately. Feature datasets remain queryable JSONB until
   actual app screens establish their stable fields.

## Phases

### Phase 0 — governance and source boundary

Deliverables:

- Confirm GPL obligations for any reused generator or website code.
- Review the separate rights implications of game-derived text and images.
- Record attribution language and a publication decision for each asset class.
- Decide whether the initial app is internal, public non-commercial, or
  commercial.

Exit criteria:

- A written decision exists for source code, structured game data, localization
  text, and images independently.
- Public asset upload remains disabled until approved.

### Phase 1 — repository and reproducible source sync

Deliverables:

- Atlas-AI repository structure and documentation.
- Shallow partial sparse-clone script.
- Pinned initial upstream commit.
- Generated import manifest with source and output hashes.

Exit criteria:

- A clean checkout can reproduce the same transformed files without fetching
  the full texture tree.
- No upstream JSON, MXML, or PNG files are committed to Atlas-AI.

### Phase 2 — database foundation and core entities

Deliverables:

- Private import-run and raw-record staging tables.
- Canonical products, substances, and technology in `nms_entities`.
- Full English localization history, including duplicate/conflicting IDs.
- Explicit grants and RLS for read-only public reference access.

Exit criteria:

- Counts and hashes reconcile with the transform manifest.
- Anonymous clients can read approved tables and cannot mutate them.
- Private source records are inaccessible through the Data API.

### Phase 3 — recipe graph and search

Deliverables:

- Crafting, refining, and cooking recipes.
- Ordered ingredient relationships with validated entity references.
- Full-text search index over item name, subtitle, and description.
- Search/query fixtures for common app interactions.

Exit criteria:

- Every transformed recipe has an output and its original ingredient order.
- Missing entity references are either zero or explicitly allowlisted.
- Representative searches use indexes and return expected results.

### Phase 4 — selective asset pipeline

Deliverables:

- Asset manifest mapping game DDS references to repository PNG paths.
- Selective fetch of referenced assets only.
- Content hashing, immutable Storage object names, and upload reconciliation.
- Placeholder behavior for missing or legally gated assets.

Exit criteria:

- The importer can run without downloading assets.
- When enabled, only referenced and approved assets are downloaded/uploaded.
- Re-running the upload skips unchanged hashes and never exposes write
  credentials to the client.

### Phase 5 — app-driven feature projections

Candidate projections:

- Fish, bait, habitats, conditions, and catch requirements.
- Expeditions, milestones, rewards, and season metadata.
- Building, corvette, and ship-part facets.
- Fossils, stories, legacy conversions, special purchases, and rewards.

Exit criteria:

- Each projection is justified by a concrete query or app screen.
- The lossless `nms_content_records` payload remains the compatibility fallback.

### Phase 6 — update automation and operations

Deliverables:

- Manual GitHub Action first; scheduled discovery only after the pipeline is
  stable.
- Validation report attached to every import run.
- Database advisors, backup/rollback procedure, and storage reconciliation.
- Alerting for source changes, schema drift, missing assets, or count drops.

Exit criteria:

- A failed import leaves the active dataset unchanged.
- A previous import can be restored from its commit and manifest.
- Deployment and data-import secrets exist only in GitHub/Supabase secret
  stores.

## Suggested implementation order

1. Review and approve the data contract and SQL schema.
2. Install the current Supabase CLI and initialize/link the chosen project.
3. Create a migration using `supabase migration new nms_reference_schema` and
   move the reviewed schema into that generated file.
4. Apply to a local Supabase database and run schema/security tests.
5. Transform the pinned source and bulk-load a development project.
6. Reconcile counts, broken references, search behavior, and Data API access.
7. Add the asset upload only after the publication gate is approved.
8. Promote the verified flow into a manually dispatched GitHub Action.

## Definition of done for the first production import

- Source commit and every input/output hash are recorded.
- All validation checks pass or have reviewed exceptions.
- Database merge is transactional and repeatable.
- Public roles have read-only access only to approved objects.
- Staging data and credentials are not publicly exposed.
- Asset status is explicit: omitted, private, or approved public.
- Attribution and licensing notices ship with the app and repository.
