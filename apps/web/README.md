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
- Pack seed JSONL.gz lives in **`pack/web-seed/`** (repo root), outside this
  publish folder, so Public privacy review is not tripped by downloadable
  archives in the app upload
- `npm run build` applies migrations and `load_pack` (resolves seed from the
  repo checkout, `SEED_DIR`, or GitHub raw → `.data/seed-cache`, then scrubs
  the cache after loading `DATABASE_URL`)
- `/` is `app/route.ts` returning bundled `SPA_HTML` from `lib/spa-html.ts`
  (synced from `public/spa.html`). Do not `fs.readFile` the shell from
  `public/` — Cursor hosting is Vercel for Platforms and public files are not
  in the serverless function file trace

`vercel.json` sets `"framework": "nextjs"` so Cursor/Vercel for Platforms does
not treat `public/` as a static-only “Other” output (that symptom is hard text
`NOT_FOUND` on `/` and `/api/*` while `/spa.html` still 200s).

Publish this folder with Cursor `publish-app` (`project_dir=apps/web`). Private
sign-in at the URL is expected until visibility is set to Public.

## Rebuild pack seed

From the repository root:

```bash
./scripts/prepare_ios_debug_pack.sh
python3 apps/web/scripts/prepare_seed.py
```

Writes `pack/web-seed/*.jsonl.gz` + `pack_manifest.json`. Generated Handbook
blobs under `.cache/` and `build/` stay gitignored.

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
`load_pack` reads `../../pack/web-seed` from a full repo checkout.

## Slice covered

- Ask: “what is Ferrite Dust for?” → entity + recipe cards from the pack
- Item / recipe detail with producing and using links
- Library browse: products, substances, technology, crafting, refining, cooking
- Saved bookmarks in `localStorage` (no accounts)
- Info: source commit SHA, record counts, NMS-Handbook attribution
- Misses: “not in this snapshot.”
- Icons: type-colored placeholders only
