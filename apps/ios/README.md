# Atlas iOS companion

SwiftUI app for iOS 26+. Canonical NMS facts come from a pinned SQLite
snapshot. Deterministic local results and cards are currently authoritative.
Apple’s `SystemLanguageModel.default` runs on-device and is instructed to
narrate only facts returned by local tools, but structural evidence validation
of its generated prose remains a beta target. There is no cloud-model fallback;
when the system model is unavailable, the deterministic planner, local search,
and cards remain fully usable. Every database tool is backed by the installed
read-only SQLite pack. See [docs/APP.md](../../docs/APP.md).

## Requirements

- Xcode 26+ / iOS 26 SDK
- Python 3.11+ to rebuild the SQLite pack from transform CSVs

## Debug (simulator)

The app bundle includes a **preview** snapshot and matching verification
sidecar (`Atlas/Resources/nms-reference.sqlite` and `pack-manifest.json`) with a
handful of items so Library and Atlas work without App Store asset hosting.

To use a full pack in Debug, transform the pinned source then replace the
preview file:

```bash
./scripts/sync_nms_source.sh
python3 scripts/transform_nms.py
python3 scripts/build_nms_sqlite.py --pack-role production
cp build/nms-sqlite/nms-reference.sqlite \
  apps/ios/Atlas/Resources/nms-reference.sqlite
cp build/nms-sqlite/pack-manifest.json \
  apps/ios/Atlas/Resources/pack-manifest.json
```

Open **`apps/ios/Atlas.xcworkspace`** in Xcode (Finder shows this as a workspace package). You can also open `apps/ios/Atlas.xcodeproj`. Do not open `project.pbxproj` — that file lives inside the `.xcodeproj` package and is not the document Xcode launches.

From the repository root, build and verify the Debug app bundle with:

```bash
./scripts/verify_ios_build.sh
```

The verifier requires the app executable, embedded downloader extension,
Background Assets configuration, privacy manifest, and the correct pack
resource policy. Debug verification reconciles the preview sidecar and SQLite;
Release verification rejects both preview files. Its DerivedData directory defaults to a path under
`/private/tmp`; override it with `--derived-data-path` or
`ATLAS_DERIVED_DATA_PATH`. To inspect an existing build without rebuilding:

```bash
./scripts/verify_ios_build.sh --configuration Debug \
  --app-bundle /path/to/Atlas.app
```

The shared `Atlas` scheme also includes the hosted `AtlasTests` target. It
covers the documented query-planning examples, the fixed local database-tool
registry, direct execution of every registered tool against the preview pack,
and the offline Ferrite Dust, Circuit Board, and broad cooking answer paths.

Copy `Config/Secrets.xcconfig.example` to `Config/Secrets.xcconfig` and add
the publishable Supabase key only if you want explicitly requested live Atlas
comparisons. Supabase is never registered as a model/database tool and never
replaces a local miss or pack error. Debug and Release xcconfigs `#include?`
that file, so the example copy is what actually loads the key. The app runs
fully offline without it.

Debug validates the bundled preview when no activated production release is
present. Release cannot use the preview.

## Release

The production database is an **essential Apple-hosted Background Asset**
(`Packs/nms-reference`). Build and validate the pinned production archive with:

```bash
./scripts/package_nms_asset_pack.sh
./scripts/verify_ios_build.sh --configuration Release
```

The app embeds `AtlasDownloader.appex`, resolves both managed files through
`AssetPackManager`, shows download progress, verifies before atomic activation,
and retains one rollback release. App Store signing still requires registering
`group.ai.atlas.nms` for both the app and extension bundle IDs and uploading
`build/nms-reference.aar` in App Store Connect.

## Architecture

- `Store/SQLiteNMSStore.swift` — every canonical database capability, local FTS5, and recipe graph
- `Store/PackLifecycle.swift` — managed download, verification, atomic activation, and rollback
- `Store/LiveAtlasClient.swift` — optional explicit comparison outside the tool registry
- `Store/WebSearchClient.swift` — optional Fandom + DuckDuckGo
- `AtlasAI/` — on-device system-model session, tools, and deterministic fallback
- `Views/` — Atlas chat, Library, entity/recipe detail, Saved, Info
