#!/bin/bash

set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)"

import_dir="${repo_root}/build/nms-import"
sqlite_output_dir="${repo_root}/build/nms-sqlite"
archive_path="${repo_root}/build/nms-reference.aar"
packaging_manifest="${repo_root}/apps/ios/Packs/nms-reference/Manifest.json"

usage() {
    printf '%s\n' \
        "Usage: scripts/package_nms_asset_pack.sh [options]" \
        "" \
        "Build and validate the pinned production SQLite snapshot, then package" \
        "it as an Apple-hosted Managed Background Assets archive." \
        "" \
        "Options:" \
        "  --import-dir DIR          Transform CSV directory (default: build/nms-import)" \
        "  --sqlite-output-dir DIR   SQLite/sidecar output (default: build/nms-sqlite)" \
        "  --output PATH             Asset archive (default: build/nms-reference.aar)" \
        "  -h, --help                Show this help"
}

require_option_value() {
    if [[ $# -lt 2 || -z "${2}" ]]; then
        printf 'Missing value for %s\n' "${1}" >&2
        usage >&2
        exit 2
    fi
}

absolute_path() {
    case "${1}" in
        /*) printf '%s\n' "${1}" ;;
        *) printf '%s/%s\n' "${PWD}" "${1}" ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --import-dir)
            require_option_value "$@"
            import_dir="$(absolute_path "${2}")"
            shift 2
            ;;
        --sqlite-output-dir)
            require_option_value "$@"
            sqlite_output_dir="$(absolute_path "${2}")"
            shift 2
            ;;
        --output)
            require_option_value "$@"
            archive_path="$(absolute_path "${2}")"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "${1}" >&2
            usage >&2
            exit 2
            ;;
    esac
done

python_bin="$(command -v python3 || true)"
xcrun_bin="$(command -v xcrun || true)"
if [[ -z "${python_bin}" ]]; then
    printf 'python3 is required.\n' >&2
    exit 1
fi
if [[ -z "${xcrun_bin}" ]]; then
    printf 'xcrun is required. Install Xcode 26 or newer.\n' >&2
    exit 1
fi
if [[ ! -d "${import_dir}" ]]; then
    printf 'Production import directory is missing: %s\n' "${import_dir}" >&2
    exit 1
fi
if [[ ! -f "${packaging_manifest}" ]]; then
    printf 'Asset-pack manifest is missing: %s\n' "${packaging_manifest}" >&2
    exit 1
fi

"${xcrun_bin}" --find ba-package >/dev/null

"${python_bin}" - "${repo_root}" "${import_dir}" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path


repo_root = Path(sys.argv[1])
import_dir = Path(sys.argv[2])
sys.path.insert(0, str(repo_root / "scripts"))

import build_nms_sqlite


expected_counts = {
    "source_records": 88_009,
    "entities": 2_597,
    "localizations": 79_756,
    "recipes": 2_181,
    "recipe_ingredients": 4_003,
    "content_records": 4_752,
    "referenced_assets": 3_232,
    "missing_assets": 16,
    "localization_conflicts": 23,
}
manifest = build_nms_sqlite.verify_transform_manifest(import_dir)
source = manifest["source"]
if source["repository"] != "https://github.com/ApexFatality93/NMS-Handbook":
    raise SystemExit("Production import preflight failed: unexpected source repository")
if source["commit_sha"] != "142d9ffd8078944722243398202f22cbef47cd02":
    raise SystemExit("Production import preflight failed: unexpected source commit")
for key, expected in expected_counts.items():
    actual = manifest["counts"].get(key)
    if type(actual) is not int or actual != expected:
        raise SystemExit(
            f"Production import preflight failed: {key} expected {expected}, found {actual!r}"
        )
print("Production import hashes and pinned count profile verified.")
PY

"${python_bin}" "${repo_root}/scripts/build_nms_sqlite.py" \
    --import-dir "${import_dir}" \
    --output-dir "${sqlite_output_dir}" \
    --pack-role production

sqlite_path="${sqlite_output_dir}/nms-reference.sqlite"
sidecar_path="${sqlite_output_dir}/pack-manifest.json"
if [[ ! -f "${sqlite_path}" || ! -f "${sidecar_path}" ]]; then
    printf 'SQLite builder did not produce both required outputs in %s.\n' \
        "${sqlite_output_dir}" >&2
    exit 1
fi

archive_dir="$(dirname -- "${archive_path}")"
mkdir -p "${archive_dir}"
stage_dir="$(mktemp -d "${archive_dir}/.nms-asset-pack.XXXXXX")"

cleanup() {
    if [[ -n "${stage_dir:-}" && -d "${stage_dir}" ]]; then
        case "${stage_dir}" in
            "${archive_dir}"/.nms-asset-pack.*) rm -rf "${stage_dir}" ;;
            *) printf 'Refusing to remove unexpected staging path: %s\n' "${stage_dir}" >&2 ;;
        esac
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

install -m 0644 "${sqlite_path}" "${stage_dir}/nms-reference.sqlite"
install -m 0644 "${sidecar_path}" "${stage_dir}/pack-manifest.json"
install -m 0644 "${packaging_manifest}" "${stage_dir}/Manifest.json"

"${python_bin}" - \
    "${import_dir}/manifest.json" \
    "${stage_dir}/nms-reference.sqlite" \
    "${stage_dir}/pack-manifest.json" \
    "${stage_dir}/Manifest.json" <<'PY'
from __future__ import annotations

import hashlib
import json
import sqlite3
import sys
from pathlib import Path
from urllib.parse import quote


PINNED_REPOSITORY = "https://github.com/ApexFatality93/NMS-Handbook"
PINNED_SOURCE_COMMIT = "142d9ffd8078944722243398202f22cbef47cd02"
EXPECTED_IMPORT_COUNTS = {
    "source_records": 88_009,
    "entities": 2_597,
    "localizations": 79_756,
    "recipes": 2_181,
    "recipe_ingredients": 4_003,
    "content_records": 4_752,
    "referenced_assets": 3_232,
    "missing_assets": 16,
    "localization_conflicts": 23,
}
EXPECTED_SQLITE_COUNTS = {
    "entities": 2_597,
    "localizations_preferred": 79_731,
    "recipes": 2_181,
    "recipe_ingredients": 4_003,
    "content_records": 4_752,
}
TABLES = {
    "entities": "nms_entities",
    "localizations_preferred": "nms_localizations",
    "recipes": "nms_recipes",
    "recipe_ingredients": "nms_recipe_ingredients",
    "content_records": "nms_content_records",
}
FTS_TABLES = {
    "nms_entities_fts": "nms_entities",
    "nms_content_fts": "nms_content_records",
}


def fail(message: str) -> None:
    raise SystemExit(f"Production asset-pack validation failed: {message}")


def load_object(path: Path, label: str) -> dict[str, object]:
    if not path.is_file():
        fail(f"missing {label}: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid {label} at {path}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require_equal(actual: object, expected: object, label: str) -> None:
    if isinstance(expected, bool):
        matches = actual is expected
    elif isinstance(expected, int):
        matches = type(actual) is int and actual == expected
    else:
        matches = actual == expected
    if not matches:
        fail(f"{label}: expected {expected!r}, found {actual!r}")


def require_count_map(
    actual: object, expected: dict[str, int], label: str
) -> None:
    if not isinstance(actual, dict):
        fail(f"{label} must be an object")
    require_equal(set(actual), set(expected), f"{label} keys")
    for key, count in expected.items():
        require_equal(actual.get(key), count, f"{label} {key}")


import_manifest_path, sqlite_path, sidecar_path, packaging_manifest_path = map(
    Path, sys.argv[1:5]
)
import_manifest = load_object(import_manifest_path, "transform manifest")
sidecar = load_object(sidecar_path, "pack sidecar")
packaging_manifest = load_object(packaging_manifest_path, "asset-pack manifest")

source = import_manifest.get("source")
if not isinstance(source, dict):
    fail("transform manifest source must be an object")
require_equal(source.get("repository"), PINNED_REPOSITORY, "source repository")
require_equal(source.get("commit_sha"), PINNED_SOURCE_COMMIT, "source commit")
require_equal(import_manifest.get("contract_version"), 1, "transform contract version")
validation = import_manifest.get("validation")
if not isinstance(validation, dict):
    fail("transform validation must be an object")
require_equal(validation.get("passed"), True, "transform validation status")
require_equal(validation.get("errors"), [], "transform validation errors")
import_counts = import_manifest.get("counts")
if not isinstance(import_counts, dict):
    fail("transform counts must be an object")
for key, expected in EXPECTED_IMPORT_COUNTS.items():
    require_equal(import_counts.get(key), expected, f"transform count {key}")

require_equal(sidecar.get("asset_pack_id"), "nms-reference", "sidecar asset-pack ID")
require_equal(sidecar.get("pack_role"), "production", "sidecar pack role")
require_equal(sidecar.get("pack_schema_version"), 1, "sidecar pack schema")
require_equal(sidecar.get("contract_version"), 1, "sidecar contract version")
require_equal(sidecar.get("source_repository"), PINNED_REPOSITORY, "sidecar repository")
require_equal(sidecar.get("source_commit_sha"), PINNED_SOURCE_COMMIT, "sidecar source commit")
require_equal(
    sidecar.get("source_committed_at"), source.get("committed_at"), "sidecar source timestamp"
)
require_count_map(sidecar.get("counts"), EXPECTED_SQLITE_COUNTS, "sidecar counts")
sidecar_validation = sidecar.get("validation")
if not isinstance(sidecar_validation, dict):
    fail("sidecar validation must be an object")
require_equal(sidecar_validation.get("passed"), True, "sidecar validation status")
require_equal(sidecar_validation.get("errors"), [], "sidecar validation errors")
sqlite_metadata = sidecar.get("sqlite")
if not isinstance(sqlite_metadata, dict):
    fail("sidecar sqlite metadata must be an object")
require_equal(sqlite_metadata.get("file"), sqlite_path.name, "sidecar SQLite filename")
require_equal(sqlite_metadata.get("bytes"), sqlite_path.stat().st_size, "sidecar SQLite size")
require_equal(sqlite_metadata.get("sha256"), sha256_file(sqlite_path), "sidecar SQLite SHA-256")

require_equal(packaging_manifest.get("assetPackID"), "nms-reference", "manifest asset-pack ID")
selectors = packaging_manifest.get("fileSelectors")
if not isinstance(selectors, list) or not all(isinstance(item, dict) for item in selectors):
    fail("asset-pack fileSelectors must be an array of objects")
selector_files = [item.get("file") for item in selectors]
if not all(isinstance(item, str) for item in selector_files):
    fail("every asset-pack file selector must name a file")
require_equal(
    sorted(selector_files),
    ["nms-reference.sqlite", "pack-manifest.json"],
    "asset-pack file selectors",
)
platforms = packaging_manifest.get("platforms")
if not isinstance(platforms, list) or "iOS" not in platforms:
    fail("asset-pack platforms must include iOS")
download_policy = packaging_manifest.get("downloadPolicy")
if not isinstance(download_policy, dict):
    fail("asset-pack downloadPolicy must be an object")
essential = download_policy.get("essential")
if not isinstance(essential, dict):
    fail("asset-pack download policy must be essential")
require_equal(
    essential.get("installationEventTypes"),
    ["firstInstallation"],
    "essential installation events",
)

database_uri = f"file:{quote(str(sqlite_path.resolve()))}?mode=ro"
connection = sqlite3.connect(database_uri, uri=True)
try:
    connection.execute("pragma query_only = on")
    quick_check = [row[0] for row in connection.execute("pragma quick_check")]
    require_equal(quick_check, ["ok"], "SQLite quick_check")
    foreign_key_errors = connection.execute("pragma foreign_key_check").fetchall()
    require_equal(foreign_key_errors, [], "SQLite foreign-key check")

    manifest_rows = connection.execute("select count(*) from pack_manifest").fetchone()[0]
    require_equal(manifest_rows, 1, "SQLite pack_manifest row count")
    row = connection.execute(
        """
        select pack_schema_version, contract_version, source_repository,
               source_commit_sha, source_committed_at, generated_at,
               counts_json, input_manifest_sha256
          from pack_manifest
        """
    ).fetchone()
    require_equal(row[0], 1, "SQLite pack schema")
    require_equal(row[1], 1, "SQLite contract version")
    require_equal(row[2], PINNED_REPOSITORY, "SQLite source repository")
    require_equal(row[3], PINNED_SOURCE_COMMIT, "SQLite source commit")
    require_equal(row[4], source.get("committed_at"), "SQLite source timestamp")
    require_equal(row[5], sidecar.get("generated_at"), "SQLite generation timestamp")
    try:
        sqlite_manifest_counts = json.loads(row[6])
    except json.JSONDecodeError as error:
        fail(f"SQLite counts_json is invalid: {error}")
    require_count_map(
        sqlite_manifest_counts, EXPECTED_SQLITE_COUNTS, "SQLite manifest counts"
    )
    require_equal(
        row[7], sha256_file(import_manifest_path), "SQLite input-manifest SHA-256"
    )

    for key, table in TABLES.items():
        actual = connection.execute(f"select count(*) from {table}").fetchone()[0]
        require_equal(actual, EXPECTED_SQLITE_COUNTS[key], f"SQLite table count {table}")
    for fts_table, canonical_table in FTS_TABLES.items():
        present = connection.execute(
            "select 1 from sqlite_master where type = 'table' and name = ?", (fts_table,)
        ).fetchone()
        if present is None:
            fail(f"SQLite is missing required FTS table {fts_table}")
        canonical_count = connection.execute(
            f"select count(*) from {canonical_table}"
        ).fetchone()[0]
        fts_count = connection.execute(
            f"select count(*) from {fts_table}"
        ).fetchone()[0]
        require_equal(
            fts_count,
            canonical_count,
            f"SQLite FTS row count {fts_table} matching {canonical_table}",
        )
finally:
    connection.close()

print(
    "Validated production pack "
    f"{PINNED_SOURCE_COMMIT[:12]} with {EXPECTED_SQLITE_COUNTS['entities']:,} entities."
)
PY

stage_archive="${stage_dir}/nms-reference.aar"
(
    cd "${stage_dir}"
    "${xcrun_bin}" ba-package package Manifest.json \
        --output-path "${stage_archive}"
)

if [[ ! -s "${stage_archive}" ]]; then
    printf 'ba-package did not produce a nonempty archive.\n' >&2
    exit 1
fi

mv -f "${stage_archive}" "${archive_path}"
printf 'Asset archive: %s\n' "${archive_path}"
