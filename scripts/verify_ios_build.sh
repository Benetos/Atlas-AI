#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
project_path="${repo_root}/apps/ios/Atlas.xcodeproj"
scheme="Atlas"

derived_data_path="${ATLAS_DERIVED_DATA_PATH:-/private/tmp/atlas-ai-ios-derived}"
app_bundle="${ATLAS_APP_BUNDLE:-}"
configuration="${ATLAS_CONFIGURATION:-Debug}"

usage() {
  cat <<'EOF'
Usage: ./scripts/verify_ios_build.sh [options]

Build Atlas and verify the resulting app bundle.

Options:
  --configuration NAME     Build/verify Debug or Release (default: Debug).
  --derived-data-path PATH  Build into an absolute path under /tmp or /private/tmp.
  --app-bundle PATH         Verify an existing Atlas.app without building.
  -h, --help                Show this help.

Environment overrides:
  ATLAS_CONFIGURATION      Equivalent to --configuration.
  ATLAS_DERIVED_DATA_PATH   Equivalent to --derived-data-path.
  ATLAS_APP_BUNDLE          Equivalent to --app-bundle.
EOF
}

fail() {
  echo "Atlas iOS verification failed: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || fail "--configuration requires a value"
      configuration="$2"
      shift 2
      ;;
    --derived-data-path)
      [[ $# -ge 2 ]] || fail "--derived-data-path requires a value"
      derived_data_path="$2"
      shift 2
      ;;
    --app-bundle)
      [[ $# -ge 2 ]] || fail "--app-bundle requires a value"
      app_bundle="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

case "${configuration}" in
  Debug|Release)
    ;;
  *)
    fail "--configuration must be Debug or Release (received: ${configuration})"
    ;;
esac

if [[ -z "${app_bundle}" ]]; then
  [[ "${derived_data_path}" = /* ]] || fail "DerivedData path must be absolute"
  case "/${derived_data_path}/" in
    *"/../"*|*"/./"*)
      fail "DerivedData path must not contain . or .. components"
      ;;
  esac
  case "${derived_data_path}" in
    /tmp/*|/private/tmp/*)
      ;;
    *)
      fail "DerivedData path must be under /tmp or /private/tmp"
      ;;
  esac

  command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is not available"
  xcodebuild \
    -project "${project_path}" \
    -scheme "${scheme}" \
    -configuration "${configuration}" \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "${derived_data_path}" \
    CODE_SIGNING_ALLOWED=NO \
    build

  app_bundle="${derived_data_path}/Build/Products/${configuration}-iphonesimulator/Atlas.app"
elif [[ "${app_bundle}" != /* ]]; then
  app_bundle="${PWD}/${app_bundle}"
fi

[[ -d "${app_bundle}" ]] || fail "app bundle not found: ${app_bundle}"

info_plist="${app_bundle}/Info.plist"
[[ -f "${info_plist}" ]] || fail "Info.plist is missing from ${app_bundle}"

supabase_url="$(plutil -extract SUPABASE_URL raw -o - "${info_plist}" 2>/dev/null)" \
  || fail "SUPABASE_URL is missing from Info.plist"
[[ "${supabase_url}" == "https://amgezynqenbgopnnpxso.supabase.co" ]] \
  || fail "SUPABASE_URL is malformed: ${supabase_url}"

background_assets_app_group="$(plutil -extract BAAppGroupID raw -o - "${info_plist}" 2>/dev/null)" \
  || fail "BAAppGroupID is missing from Info.plist"
[[ "${background_assets_app_group}" == "group.ai.atlas.nms" ]] \
  || fail "BAAppGroupID is incorrect: ${background_assets_app_group}"

has_managed_asset_packs="$(plutil -extract BAHasManagedAssetPacks raw -o - "${info_plist}" 2>/dev/null)" \
  || fail "BAHasManagedAssetPacks is missing from Info.plist"
[[ "${has_managed_asset_packs}" == "true" ]] \
  || fail "BAHasManagedAssetPacks must be true"

uses_apple_hosting="$(plutil -extract BAUsesAppleHosting raw -o - "${info_plist}" 2>/dev/null)" \
  || fail "BAUsesAppleHosting is missing from Info.plist"
[[ "${uses_apple_hosting}" == "true" ]] \
  || fail "BAUsesAppleHosting must be true"

executable_name="$(plutil -extract CFBundleExecutable raw -o - "${info_plist}" 2>/dev/null)" \
  || fail "CFBundleExecutable is missing from Info.plist"
[[ -n "${executable_name}" ]] || fail "CFBundleExecutable is empty"

app_executable="${app_bundle}/${executable_name}"
preview_sqlite="${app_bundle}/nms-reference.sqlite"
preview_sidecar="${app_bundle}/pack-manifest.json"
privacy_manifest="${app_bundle}/PrivacyInfo.xcprivacy"
downloader_bundle="${app_bundle}/Extensions/AtlasDownloader.appex"
downloader_info_plist="${downloader_bundle}/Info.plist"

[[ -f "${app_executable}" && -x "${app_executable}" ]] \
  || fail "app executable is missing or not executable: ${app_executable}"
[[ -f "${privacy_manifest}" ]] \
  || fail "privacy manifest is missing: ${privacy_manifest}"
[[ -d "${downloader_bundle}" ]] \
  || fail "AtlasDownloader extension is not embedded: ${downloader_bundle}"
[[ -f "${downloader_info_plist}" ]] \
  || fail "AtlasDownloader Info.plist is missing: ${downloader_info_plist}"

plutil -lint "${privacy_manifest}" >/dev/null \
  || fail "privacy manifest is not a valid property list"

extension_point="$(plutil -extract EXAppExtensionAttributes.EXExtensionPointIdentifier raw -o - "${downloader_info_plist}" 2>/dev/null)" \
  || fail "AtlasDownloader extension point is missing"
[[ "${extension_point}" == "com.apple.background-asset-downloader-extension" ]] \
  || fail "AtlasDownloader extension point is incorrect: ${extension_point}"

downloader_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "${downloader_info_plist}" 2>/dev/null)" \
  || fail "AtlasDownloader bundle identifier is missing"
[[ "${downloader_bundle_id}" == "ai.atlas.nms.downloader" ]] \
  || fail "AtlasDownloader bundle identifier is incorrect: ${downloader_bundle_id}"

downloader_executable_name="$(plutil -extract CFBundleExecutable raw -o - "${downloader_info_plist}" 2>/dev/null)" \
  || fail "AtlasDownloader executable name is missing"
downloader_executable="${downloader_bundle}/${downloader_executable_name}"
[[ -f "${downloader_executable}" && -x "${downloader_executable}" ]] \
  || fail "AtlasDownloader executable is missing or not executable: ${downloader_executable}"

if [[ "${configuration}" == "Debug" ]]; then
  [[ -f "${preview_sqlite}" ]] \
    || fail "preview SQLite pack is missing: ${preview_sqlite}"
  [[ -f "${preview_sidecar}" ]] \
    || fail "preview pack sidecar is missing: ${preview_sidecar}"

  command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is not available"
  quick_check="$(sqlite3 "${preview_sqlite}" "pragma quick_check;")" \
    || fail "SQLite quick_check could not run"
  [[ "${quick_check}" == "ok" ]] \
    || fail "SQLite quick_check returned: ${quick_check}"

  sidecar_role="$(plutil -extract pack_role raw -o - "${preview_sidecar}" 2>/dev/null)" \
    || fail "pack_role is missing from preview sidecar"
  [[ "${sidecar_role}" == "preview" ]] \
    || fail "Debug pack_role must be preview (received: ${sidecar_role})"

  sidecar_sqlite_file="$(plutil -extract sqlite.file raw -o - "${preview_sidecar}" 2>/dev/null)" \
    || fail "sqlite.file is missing from preview sidecar"
  [[ "${sidecar_sqlite_file}" == "nms-reference.sqlite" ]] \
    || fail "preview sidecar names the wrong SQLite file: ${sidecar_sqlite_file}"

  command -v shasum >/dev/null 2>&1 || fail "shasum is not available"
  declared_sha256="$(plutil -extract sqlite.sha256 raw -o - "${preview_sidecar}" 2>/dev/null)" \
    || fail "sqlite.sha256 is missing from preview sidecar"
  actual_sha256="$(shasum -a 256 "${preview_sqlite}" | awk '{print $1}')" \
    || fail "could not hash preview SQLite pack"
  [[ "${actual_sha256}" == "${declared_sha256}" ]] \
    || fail "preview SQLite SHA-256 does not match pack-manifest.json"
else
  [[ ! -e "${preview_sqlite}" ]] \
    || fail "Release bundle must not contain the preview SQLite pack: ${preview_sqlite}"
  [[ ! -e "${preview_sidecar}" ]] \
    || fail "Release bundle must not contain the preview pack sidecar: ${preview_sidecar}"
fi

echo "Atlas iOS ${configuration} bundle verified"
echo "  bundle: ${app_bundle}"
echo "  executable: ${app_executable}"
echo "  downloader extension: ${downloader_bundle}"
if [[ "${configuration}" == "Debug" ]]; then
  echo "  preview pack: ${preview_sqlite}"
  echo "  preview sidecar: ${preview_sidecar}"
else
  echo "  preview pack: absent (required for Release)"
  echo "  preview sidecar: absent (required for Release)"
fi
echo "  privacy manifest: ${privacy_manifest}"
