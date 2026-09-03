# Atlas iOS companion

SwiftUI app for iOS 26+. Canonical NMS facts come from a pinned SQLite
snapshot. Deterministic local results and cards are currently authoritative.
Apple’s `SystemLanguageModel.default` runs on-device and is instructed to
narrate only facts returned by local tools, but structural evidence validation
of its generated prose remains a beta target. Atlas waits up to eight seconds
for that narration and then uses the verified database answer if generation
fails or stalls. There is no cloud-model fallback; when the system model is
unavailable, the deterministic planner, local search, and cards remain fully
usable. Every database tool is backed by the installed
read-only SQLite pack. See [docs/APP.md](../../docs/APP.md).

## Requirements

- Xcode 26+ / iOS 26 SDK
- Python 3.11+ to rebuild the SQLite pack from transform CSVs

## Debug (simulator)

Normal Debug builds use the complete pinned database, not the small test
fixture. Prepare the ignored generated pack from the repository root before
opening or building the app:

```bash
./scripts/prepare_ios_debug_pack.sh
```

The Xcode project references `build/nms-sqlite/nms-reference.sqlite` and its
production sidecar directly for Debug. These generated files remain ignored by
Git. A missing pack fails the build instead of silently launching a misleading
three-item catalog. The small preview pair lives under `AtlasTests/Fixtures`
and is only used by tests that need a disposable database to corrupt or mutate.

Open **`apps/ios/Atlas.xcworkspace`** in Xcode (Finder shows this as a workspace package). You can also open `apps/ios/Atlas.xcodeproj`. Do not open `project.pbxproj` — that file lives inside the `.xcodeproj` package and is not the document Xcode launches.

From the repository root, build and verify the Debug app bundle with:

```bash
./scripts/verify_ios_build.sh
```

The verifier requires the app executable, embedded downloader extension,
Background Assets configuration, privacy manifest, and the correct pack
resource policy. Debug verification reconciles the full sidecar and SQLite;
Release verification rejects both bundled files. Debug also requires the full
pinned counts (2,597 entities, 2,181 recipes, and 4,752 feature records). Its
DerivedData directory defaults to a path under
`/private/tmp`; override it with `--derived-data-path` or
`ATLAS_DERIVED_DATA_PATH`. To inspect an existing build without rebuilding:

```bash
./scripts/verify_ios_build.sh --configuration Debug \
  --app-bundle /path/to/Atlas.app
```

The shared `Atlas` scheme also includes the hosted `AtlasTests` target. Search,
category, tool-registry, and offline-answer integration checks run with the full
pack embedded in the host app. Narrow corruption and malformed-manifest tests
use the separate disposable fixture.

The app runs fully offline without secrets. A publishable Supabase key is
leftover from a parked live-handbook idea and is not required. Do not add
one unless that parked path is deliberately revived. See
[docs/WORK_SLICES.md](../../docs/WORK_SLICES.md).

Debug validates and opens the bundled full pack directly so an older simulator
activation cannot mask the database under test. Release never bundles a pack;
it installs the verified Apple-hosted production asset.

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
- `Store/SavedStore.swift` — local bookmarks and recents; richer artifacts are Slice 2
- `Store/LiveAtlasClient.swift` — parked leftover, not a current player feature
- `Store/WebSearchClient.swift` — optional Fandom + DuckDuckGo
- `AtlasAI/` — on-device system-model session, tools, and deterministic fallback
- `Views/` — Atlas chat, Library, entity/recipe detail, Saved, Info
