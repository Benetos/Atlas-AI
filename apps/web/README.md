# Atlas private web companion

A local-only browser companion for the same pinned NMS SQLite pack the iOS app
reads. It does **not** publish a public URL, call a cloud LLM, or invent a second
data model. Canonical facts come only from `build/nms-sqlite/nms-reference.sqlite`.

Licensing posture remains internal. Show NMS-Handbook attribution; do not ship
extracted images.

## Rebuild the snapshot

From the repository root:

```bash
./scripts/prepare_ios_debug_pack.sh
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
```

Generated JSON/CSV/SQLite under `.cache/` and `build/` stay gitignored. Do not
commit upstream Handbook JSON, MXML, or images.

Pinned baseline (see `docs/BASELINE_VALIDATION.md`):

- Source commit `142d9ffd8078944722243398202f22cbef47cd02`
- ~2,597 entities and ~2,181 recipes

If a different Handbook commit is imported, the Info page shows that SHA.

## Start the local server

```bash
python3 apps/web/server.py --host 127.0.0.1 --port 8765
```

Open [http://127.0.0.1:8765/](http://127.0.0.1:8765/). Bind only to localhost
unless you intentionally share on a private network. Do not publish this app.

Optional pack override:

```bash
python3 apps/web/server.py --pack /path/to/nms-reference.sqlite
```

## Slice covered

- Ask: “what is Ferrite Dust for?” → entity + recipe cards from the pack
- Item page: `display_name`, then `name`, then `game_id`, plus type / category /
  subcategory / rarity / legality / base value / subtitle / description
- Recipes that produce or consume the item, with kind, amounts, time, and
  ordered ingredient links
- Library browse: products, substances, technology, crafting, refining, cooking
- Saved bookmarks in `localStorage` (no accounts)
- Info: source commit SHA, record counts, NMS-Handbook attribution
- Misses: “not in this snapshot.”
- Icons: type-colored placeholders only
