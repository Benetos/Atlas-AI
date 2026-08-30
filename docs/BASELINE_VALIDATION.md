# Baseline transform validation

Validation date: 2026-08-29
Source commit: `142d9ffd8078944722243398202f22cbef47cd02`
Contract version: 1

## Result

The repository transformer completed successfully against the pinned sparse
checkout with zero blocking errors.

| Generated output | Rows |
|---|---:|
| Lossless source records | 88,009 |
| Canonical entities | 2,597 |
| Localization rows | 79,756 |
| Recipes | 2,181 |
| Recipe ingredients | 4,003 |
| Feature content records | 4,752 |
| Referenced asset paths | 3,232 |

Generated import artifacts totaled approximately 54 MB. They are ignored by
Git and are reproducible from the source commit.

## Validation findings

- Blocking errors: 0.
- Advisory warnings: 17.
- Conflicting localization IDs: 23.
- Asset references resolved to upstream PNGs: 3,216.
- Asset references without an upstream PNG conversion: 16.

The 16 unresolved asset references are mission/building/component images not
present as PNGs in the current upstream texture tree. They remain in the asset
manifest with status `missing`; clients must use a bundled placeholder.

## Verified invariants

- All 19 required JSON files exist and parse with the expected top-level shape.
- The authoritative source commit is a full 40-character SHA.
- Canonical entity identities are unique.
- Recipe IDs are deterministic and unique.
- Recipe ingredient positions are unique within each recipe.
- All recipe output and ingredient references resolve to products or substances.
- All numeric fields promoted by the transform parse successfully.
- Every generated CSV has a SHA-256 recorded in `manifest.json`.
- The asset fetch command defaults to dry-run and selected 3,216 resolvable
  images without downloading them.

## Reproduction

```bash
NMS_SOURCE_REF=142d9ffd8078944722243398202f22cbef47cd02 \
  ./scripts/sync_nms_source.sh

python3 scripts/transform_nms.py \
  --source-dir .cache/nms-handbook/JSON_Files \
  --source-repo .cache/nms-handbook \
  --output-dir build/nms-import

python3 scripts/fetch_nms_assets.py
```

The final command is a dry run unless `--approved` is explicitly supplied.
