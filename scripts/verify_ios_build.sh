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
  if [[ "${configuration}" == "Debug" ]]; then
    generated_pack_dir="${repo_root}/build/nms-sqlite"
    [[ -f "${generated_pack_dir}/nms-reference.sqlite" ]] \
      || fail "full Debug database is missing; run ./scripts/prepare_ios_debug_pack.sh"
    [[ -f "${generated_pack_dir}/pack-manifest.json" ]] \
      || fail "full Debug database sidecar is missing; run ./scripts/prepare_ios_debug_pack.sh"
  fi
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
bundled_sqlite="${app_bundle}/nms-reference.sqlite"
bundled_sidecar="${app_bundle}/pack-manifest.json"
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
  [[ -f "${bundled_sqlite}" ]] \
    || fail "full Debug SQLite pack is missing: ${bundled_sqlite}"
  [[ -f "${bundled_sidecar}" ]] \
    || fail "full Debug pack sidecar is missing: ${bundled_sidecar}"

  command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is not available"
  quick_check="$(sqlite3 "${bundled_sqlite}" "pragma quick_check;")" \
    || fail "SQLite quick_check could not run"
  [[ "${quick_check}" == "ok" ]] \
    || fail "SQLite quick_check returned: ${quick_check}"
  foreign_key_errors="$(sqlite3 "${bundled_sqlite}" "pragma foreign_key_check;")" \
    || fail "SQLite foreign_key_check could not run"
  [[ -z "${foreign_key_errors}" ]] \
    || fail "full Debug database contains invalid foreign keys"

  sidecar_role="$(plutil -extract pack_role raw -o - "${bundled_sidecar}" 2>/dev/null)" \
    || fail "pack_role is missing from full Debug sidecar"
  [[ "${sidecar_role}" == "production" ]] \
    || fail "Debug pack_role must be production (received: ${sidecar_role})"

  sidecar_sqlite_file="$(plutil -extract sqlite.file raw -o - "${bundled_sidecar}" 2>/dev/null)" \
    || fail "sqlite.file is missing from full Debug sidecar"
  [[ "${sidecar_sqlite_file}" == "nms-reference.sqlite" ]] \
    || fail "full Debug sidecar names the wrong SQLite file: ${sidecar_sqlite_file}"

  for count_spec in \
    "entities:2597" \
    "localizations_preferred:79731" \
    "recipes:2181" \
    "recipe_ingredients:4003" \
    "content_records:4752"; do
    count_key="${count_spec%%:*}"
    expected_count="${count_spec##*:}"
    actual_count="$(plutil -extract "counts.${count_key}" raw -o - "${bundled_sidecar}" 2>/dev/null)" \
      || fail "counts.${count_key} is missing from full Debug sidecar"
    [[ "${actual_count}" == "${expected_count}" ]] \
      || fail "full Debug ${count_key} count must be ${expected_count} (received: ${actual_count})"
  done

  entity_fts_count="$(sqlite3 "${bundled_sqlite}" "select count(*) from nms_entities_fts;")" \
    || fail "could not count the entity search index"
  content_fts_count="$(sqlite3 "${bundled_sqlite}" "select count(*) from nms_content_fts;")" \
    || fail "could not count the feature search index"
  [[ "${entity_fts_count}" == "2597" ]] \
    || fail "entity search index is incomplete (received: ${entity_fts_count})"
  [[ "${content_fts_count}" == "4752" ]] \
    || fail "feature search index is incomplete (received: ${content_fts_count})"

  command -v shasum >/dev/null 2>&1 || fail "shasum is not available"
  declared_sha256="$(plutil -extract sqlite.sha256 raw -o - "${bundled_sidecar}" 2>/dev/null)" \
    || fail "sqlite.sha256 is missing from full Debug sidecar"
  actual_sha256="$(shasum -a 256 "${bundled_sqlite}" | awk '{print $1}')" \
    || fail "could not hash full Debug SQLite pack"
  [[ "${actual_sha256}" == "${declared_sha256}" ]] \
    || fail "full Debug SQLite SHA-256 does not match pack-manifest.json"
else
  [[ ! -e "${bundled_sqlite}" ]] \
    || fail "Release bundle must not contain a bundled SQLite pack: ${bundled_sqlite}"
  [[ ! -e "${bundled_sidecar}" ]] \
    || fail "Release bundle must not contain a bundled pack sidecar: ${bundled_sidecar}"
fi

echo "Atlas iOS ${configuration} bundle verified"
echo "  bundle: ${app_bundle}"
echo "  executable: ${app_executable}"
echo "  downloader extension: ${downloader_bundle}"
if [[ "${configuration}" == "Debug" ]]; then
  echo "  full Debug pack: ${bundled_sqlite}"
  echo "  full Debug sidecar: ${bundled_sidecar}"
else
  echo "  bundled pack: absent (required for Release)"
  echo "  bundled sidecar: absent (required for Release)"
fi
echo "  privacy manifest: ${privacy_manifest}"
