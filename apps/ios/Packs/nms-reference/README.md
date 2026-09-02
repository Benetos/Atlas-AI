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

## Debug preview

Debug builds load a small preview snapshot from the app bundle so the simulator
does not need App Store hosting. Regenerate both the SQLite file and its preview
sidecar with:

```bash
python3 scripts/make_preview_pack.py
```

That command writes `nms-reference.sqlite` and `pack-manifest.json` beside one
another in `apps/ios/Atlas/Resources`. The sidecar is marked
`"pack_role": "preview"`; it must never pass the production packaging gate.
To exercise the complete dataset locally, use generated production outputs
without committing them or changing the preview role.

The SQLite file, sidecar, and `.aar` are generated outputs. Do not vendor the
full production snapshot in Git.
