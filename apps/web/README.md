# Atlas private web companion

Browser companion for the same pinned NMS pack the iOS app reads. Canonical
facts come from the transform → SQLite pipeline (entities, recipes,
ingredients, content records). Bookmarks stay in `localStorage`.

Licensing posture remains internal. Show NMS-Handbook attribution; do not ship
extracted images.

## Hosted (Cursor publish-app)

`apps/web` is a Next.js app with Postgres:

- `cursor-app.json` declares `{ "database": "postgres" }`
- `migrations/` creates the pack tables
- `seed/*.jsonl.gz` holds pack rows exported from the SQLite snapshot
- `npm run build` applies migrations and loads the seed when `DATABASE_URL` is set
- `/` rewrites to `public/spa.html` (static entry). Do not serve the shell via an
  `app/route.ts` that `fs.readFile`s HTML — Cursor hosting is Vercel for Platforms
  and public files are not in the serverless function file trace.

Publish this folder with Cursor `publish-app` (`project_dir=apps/web`). Private
sign-in at the URL is expected.

## Rebuild pack seed

From the repository root:

```bash
./scripts/prepare_ios_debug_pack.sh
python3 apps/web/scripts/prepare_seed.py
```

Or step by step:

```bash
./scripts/sync_nms_source.sh
python3 scripts/transform_nms.py \
  --source-dir .cache/nms-handbook/JSON_Files \
  --source-repo .cache/nms-handbook \
  --output-dir build/nms-import
python3 scripts/build_nms_sqlite.py \
  --import-dir build/nms-import \
  --output-dir build/nms-sqlite \
  --pack-role production
python3 apps/web/scripts/prepare_seed.py
```

Generated Handbook blobs under `.cache/` and `build/` stay gitignored. The
compressed JSONL seed under `apps/web/seed/` is committed so the hosted build
can load Postgres without shipping upstream Handbook JSON/MXML/images.

Pinned baseline:

- Source commit `142d9ffd8078944722243398202f22cbef47cd02`
- ~2,597 entities and ~2,181 recipes

## Local Python + SQLite

```bash
./scripts/prepare_ios_debug_pack.sh
python3 apps/web/server.py --host 127.0.0.1 --port 8765
```

Open [http://127.0.0.1:8765/](http://127.0.0.1:8765/). Uses
`build/nms-sqlite/nms-reference.sqlite` directly.

## Local Next.js + PGlite

```bash
cd apps/web
npm install
npm run migrate
npm run load-pack
npm run dev
```

When `DATABASE_URL` is unset, migrate/load target local PGlite under `.data/`.

## Slice covered

- Ask: “what is Ferrite Dust for?” → entity + recipe cards from the pack
- Item / recipe detail with producing and using links
- Library browse: products, substances, technology, crafting, refining, cooking
- Saved bookmarks in `localStorage` (no accounts)
- Info: source commit SHA, record counts, NMS-Handbook attribution
- Misses: “not in this snapshot.”
- Icons: type-colored placeholders only
