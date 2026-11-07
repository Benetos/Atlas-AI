# Web companion pack seed

JSONL.gz rows exported from the same transform → SQLite pipeline the iOS app
uses. Counts must stay aligned with the pinned Handbook snapshot.

These files are **build inputs only**. They live outside `apps/web` so Cursor
`publish-app` (`project_dir=apps/web`) does not pack them into the hosted app
tree (avoids Public visibility privacy review on downloadable seed archives).

`apps/web` `load_pack` resolves them from:

1. `SEED_DIR` if set
2. this directory when the full repo is checked out
3. GitHub raw download into `apps/web/.data/seed-cache` during hosted builds

After a successful load into `DATABASE_URL`, the cache is deleted.
