# nms-reference asset pack

This directory is the Managed Background Assets pack for the pinned Atlas
SQLite snapshot.

## Production release archive

Generate `build/nms-import` from the pinned source checkout, then run the
release packager from the repository root (macOS, Xcode 26+):

```bash
scripts/package_nms_asset_pack.sh
```

Use `DEVELOPER_DIR` when the required Xcode is not selected globally:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  scripts/package_nms_asset_pack.sh
```

The script always calls `build_nms_sqlite.py` with `--pack-role production`.
It refuses to package anything except the approved full import at source commit
`142d9ffd8078944722243398202f22cbef47cd02` and reconciles the pinned transform
counts against the generated SQLite tables, embedded SQLite manifest, and
`pack-manifest.json`. It also verifies the SQLite SHA-256 and byte size,
`quick_check`, foreign keys, FTS tables, asset-pack ID, essential install policy,
and both required file selectors.

After validation, the script creates a private staging directory containing
only:

- `nms-reference.sqlite`
- `pack-manifest.json`
- `Manifest.json`

It runs `xcrun ba-package` from that directory because `fileSelectors` are
relative to the current working directory. The final outputs are:

- `build/nms-sqlite/nms-reference.sqlite`
- `build/nms-sqlite/pack-manifest.json`
- `build/nms-reference.aar`

The archive replaces an older archive only after packaging succeeds. The `iOS`
platform value covers both iPhone and iPad; `iPadOS` is not a valid manifest
platform value.

Upload `build/nms-reference.aar` to App Store Connect as an Apple-hosted pack.
The app reads it through `AssetPackManager` using asset pack ID
`nms-reference`.

## Debug and test data

Debug builds embed the complete generated production snapshot so simulator,
search, category, tool, and Ask Atlas testing exercise the same catalog users
will receive. Prepare it with:

```bash
./scripts/prepare_ios_debug_pack.sh
```

The ignored `build/nms-sqlite` pair is referenced directly by the Atlas Debug
target and keeps `"pack_role": "production"`. The build fails when it is
missing rather than falling back to a catalog too small to reveal data or
search defects.

`python3 scripts/make_preview_pack.py` separately regenerates the three-row
fixture under `apps/ios/AtlasTests/Fixtures`. That fixture is bundled only with
the test target and is reserved for focused tests that mutate or corrupt a
throwaway database.

The SQLite file, sidecar, and `.aar` are generated outputs. Do not vendor the
full production snapshot in Git.
