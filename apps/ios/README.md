# Atlas iOS companion

SwiftUI app for iOS 26+. Canonical NMS facts come from a pinned SQLite
snapshot. Apple Foundation Models run on-device and may only speak facts
returned by tools. See [docs/APP.md](../../docs/APP.md).

## Requirements

- Xcode 26+ / iOS 26 SDK
- Python 3.11+ to rebuild the SQLite pack from transform CSVs

## Debug (simulator)

The app bundle includes a **preview** snapshot (`Atlas/Resources/nms-reference.sqlite`)
with a handful of items so Library and Atlas work without App Store asset
hosting.

To use a full pack in Debug, transform the pinned source then replace the
preview file:

```bash
./scripts/sync_nms_source.sh
python3 scripts/transform_nms.py
python3 scripts/build_nms_sqlite.py
cp build/nms-sqlite/nms-reference.sqlite \
  apps/ios/Atlas/Resources/nms-reference.sqlite
```

Open **`apps/ios/Atlas.xcworkspace`** in Xcode (Finder shows this as a workspace package). You can also open `apps/ios/Atlas.xcodeproj`. Do not open `project.pbxproj` — that file lives inside the `.xcodeproj` package and is not the document Xcode launches.

Copy `Config/Secrets.xcconfig.example` to `Config/Secrets.xcconfig` and add
the publishable Supabase key only if you want live Atlas search. Debug and
Release xcconfigs `#include?` that file, so the example copy is what actually
loads the key. The app runs fully offline without it.

Pack lookup prefers the app-group / Application Support copy (the hosted
Background Asset) over the bundled preview SQLite, so a Release build can keep
the preview file in the target without shadowing the full pack.

## Release

The production database is an **essential Apple-hosted Background Asset**
(`Packs/nms-reference`). See that folder’s README for `ba-package` steps.

## Architecture

- `Store/SQLiteNMSStore.swift` — local FTS5 and recipe graph
- `Store/LiveAtlasClient.swift` — optional PostgREST reads (anon key)
- `Store/WebSearchClient.swift` — optional Fandom + DuckDuckGo
- `AtlasAI/` — Foundation Models session, tools, keyword fallback
- `Views/` — Atlas chat, Library, entity/recipe detail, Saved, Info
