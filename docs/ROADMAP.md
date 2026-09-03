# NMS data assimilation roadmap

## Outcome

Atlas-AI maintains a reproducible No Man's Sky reference snapshot for the
phone app. The player-facing database is the pinned SQLite pack, not a
hosted API.

```text
Pinned upstream commit
  -> sparse local cache (JSON_Files)
  -> deterministic transform and validation
  -> versioned SQLite pack + sidecar
  -> Debug bundle or Apple-hosted Background Asset
```

A Postgres/Supabase load path exists from an earlier idea: publish the same
transform into read-only tables. That path is **parked**. The companion does
not query it. If a public snapshot is ever wanted, free Supabase is enough.
If custom user data later needs an account, that is a different hosted
product (Supabase, Firebase, or similar) and does not replace this pack
pipeline.

Work on the app itself is sliced in [WORK_SLICES.md](WORK_SLICES.md).

## Guiding decisions

1. **Pin every import.** Every dataset is traceable to a full Git commit SHA,
   source URL, input hash, and pack sidecar.
2. **Preserve before normalizing.** Lossless source records stay in the
   transform output. The phone pack carries canonical entities, recipes,
   preferred localizations, and feature payloads.
3. **The phone pack is the product database.** Library, Atlas, and specialist
   slices execute SQL on the installed snapshot.
4. **Do not over-normalize unknown features.** Recipes and canonical entities
   are typed now. Feature families stay in `nms_content_records` until a
   slice needs filters or calculations.
5. **Attribution, not ownership.** Atlas transforms NMS-Handbook JSON. It
   does not copy that project’s Python or website, and it does not claim to
   own Hello Games material.
6. **Hosted handbook is optional and later.** Do not build runtime answers
   against Postgres.

## Phases

### Phase 0 — source boundary

Status: **done for the current product.**

- Ingest `JSON_Files` from a pinned NMS-Handbook commit.
- Keep Atlas transformer/pack scripts in this repo.
- Attribute the source on Info and in the README.
- Do not bundle extracted images.

### Phase 1 — repository and reproducible source sync

Status: **complete for the pinned baseline**.

- Sparse clone of `JSON_Files` (and unused upstream `Python Files` cache
  only — Atlas does not ship or execute that code).
- Pinned commit `142d9ffd8078944722243398202f22cbef47cd02`.
- Transform manifest with source and output hashes.

### Phase 2 — canonical entities and localizations

Status: **complete in the SQLite pack**.

### Phase 3 — recipe graph and search

Status: **complete in the SQLite pack**.

FTS and recipe joins run on the device.

### Phase 4 — assets

Status: **not started, not blocking.**

Icons stay placeholders until you want them. Do not upload extracted
textures to a public bucket as part of the current slices.

### Phase 5 — app-driven feature projections

Status: **in progress on the phone.**

First screens are in [APP.md](APP.md). Next slices are the recipe planner
and a versioned local saved-data store, then typed fish / expedition /
building / ship families as needed. See [WORK_SLICES.md](WORK_SLICES.md).

### Phase 6 — pack updates

Status: **local and manual.**

Rebuild the pack from a new pinned commit when the source moves. Release
can ship that pack as an Apple-hosted asset. A GitHub Action is optional
convenience, not a required gate.

The parked Supabase import/activation flow is recorded in
[SUPABASE_INGESTION.md](SUPABASE_INGESTION.md) and
[SUPABASE_DEPLOYMENT.md](SUPABASE_DEPLOYMENT.md) in case a snapshot host
is wanted later.

## Suggested implementation order

1. ~~Review and approve the data contract and SQL schema.~~
2. ~~Transform the pinned source.~~
3. ~~Ship the iOS companion against the packed SQLite snapshot.~~
4. Recipe planner and local saved artifacts ([WORK_SLICES.md](WORK_SLICES.md)).
5. One specialist family at a time.
6. Optional user-data sync only if another device or an account is wanted.
7. Optional free-Supabase handbook snapshot only if a public read API is
   wanted.

## Definition of done for a pack rebuild

- Source commit and every input/output hash are recorded.
- Validation checks pass or have reviewed exceptions.
- Debug embeds the new production pair; Release verification still rejects
  a bundled database.
- Attribution remains in the app and repository.
