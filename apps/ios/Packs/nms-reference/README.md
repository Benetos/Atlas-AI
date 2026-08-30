# nms-reference asset pack

This directory is the Managed Background Assets pack for the pinned Atlas
SQLite snapshot.

Release packaging (macOS, Xcode 26+):

```bash
python3 scripts/build_nms_sqlite.py \
  --import-dir build/nms-import \
  --output-dir build/nms-sqlite

cp build/nms-sqlite/nms-reference.sqlite \
  apps/ios/Packs/nms-reference/nms-reference.sqlite

xcrun ba-package apps/ios/Packs/nms-reference
```

Upload the resulting `.aar` to App Store Connect as an Apple-hosted pack.
The app reads it through `AssetPackManager` using asset pack ID
`nms-reference`.

Debug builds load `apps/ios/Atlas/Resources/nms-reference.sqlite` (a small
preview snapshot) from the app bundle so the simulator does not need App
Store hosting. Replace that file with the full `build/nms-sqlite` output
to exercise the complete dataset locally.

The SQLite file is generated output. Do not vendor the full production
snapshot in Git.
