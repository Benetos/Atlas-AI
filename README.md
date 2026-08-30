# Atlas-AI

Atlas-AI is the home for the No Man's Sky reference-data ingestion project. The
initial source is
[`ApexFatality93/NMS-Handbook`](https://github.com/ApexFatality93/NMS-Handbook),
but the Atlas data model is deliberately source-independent so additional
sources can be assimilated later.

The upstream repository is large and contains thousands of binary assets.
Atlas-AI does **not** vendor that repository or its generated data. Instead, it
uses a shallow partial sparse clone in `.cache/`, transforms the pinned snapshot
into deterministic import files under `build/`, and then bulk-loads those files
into Supabase.

## Project package

- [Roadmap](docs/ROADMAP.md)
- [Source inventory](docs/SOURCE_INVENTORY.md)
- [Canonical data contract](docs/DATA_CONTRACT.md)
- [Supabase architecture and upload runbook](docs/SUPABASE_INGESTION.md)
- [Supabase deployment record](docs/SUPABASE_DEPLOYMENT.md)
- [Initial import verification](docs/INITIAL_IMPORT.md)
- [Baseline validation report](docs/BASELINE_VALIDATION.md)
- [Database schema](supabase/schema/nms_reference_schema.sql)
- [Generated application database types](supabase/types/database.ts)

## Local preparation

Requirements:

- Git 2.25+
- Python 3.11+
- `psql` for the future database-load step
- Supabase CLI 2.81.3+ when the schema is promoted into migrations

Fetch only the data and generator directories from the upstream repository:

```bash
./scripts/sync_nms_source.sh
```

Transform and validate the pinned source snapshot:

```bash
python3 scripts/transform_nms.py \
  --source-dir .cache/nms-handbook/JSON_Files \
  --source-repo .cache/nms-handbook \
  --output-dir build/nms-import
```

The transformer creates CSV files for bulk `COPY`, a lossless raw-record file,
an asset manifest, and `manifest.json` containing the resolved source commit,
input hashes, record counts, validation findings, and output hashes.

Verify those hashes and produce deterministic, resumable SQL batches:

```bash
python3 scripts/prepare_nms_import.py \
  --import-dir build/nms-import \
  --output-dir build/nms-sql
```

The generated plan remains ignored under `build/`. It stages data only in
`nms_private`; the final batch validates all counts and atomically promotes the
new revision to the read-only public tables.

Preview the selective asset plan without downloading image blobs:

```bash
python3 scripts/fetch_nms_assets.py
```

The script performs a dry run unless `--approved` is supplied. Generated assets
remain under ignored `build/` paths and are intended for Supabase Storage, not
Git.

## Source and licensing boundary

The initial analyzed source commit is
`142d9ffd8078944722243398202f22cbef47cd02`. Production imports must record the
exact resolved commit and must never be described only as "latest."

NMS-Handbook declares GPL-3.0. Much of its text and imagery is extracted from
No Man's Sky and may contain rights owned by Hello Games or its licensors.
Atlas-AI keeps source provenance, code licensing, and asset publication as
explicit gates. Do not publicly distribute extracted text or imagery until the
project's licensing posture has been reviewed.
