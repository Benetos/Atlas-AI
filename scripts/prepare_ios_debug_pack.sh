#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
source_repo="${repo_root}/.cache/nms-handbook"
import_dir="${repo_root}/build/nms-import"
pack_dir="${repo_root}/build/nms-sqlite"

"${script_dir}/sync_nms_source.sh"
python3 "${script_dir}/transform_nms.py" \
  --source-dir "${source_repo}/JSON_Files" \
  --source-repo "${source_repo}" \
  --output-dir "${import_dir}"
python3 "${script_dir}/build_nms_sqlite.py" \
  --import-dir "${import_dir}" \
  --output-dir "${pack_dir}" \
  --pack-role production
python3 "${script_dir}/fetch_nms_assets.py" --approved \
  --asset-manifest "${import_dir}/assets.csv" \
  --source-repo "${source_repo}" \
  --output-dir "${repo_root}/build/nms-assets"
python3 "${script_dir}/pack_nms_icons.py" \
  --asset-manifest "${import_dir}/assets.csv" \
  --fetch-dir "${repo_root}/build/nms-assets" \
  --pack-dir "${pack_dir}"

python3 - "${script_dir}" "${pack_dir}/nms-reference.sqlite" "${pack_dir}/icons" <<'PY'
from __future__ import annotations

import sqlite3
import sys
from pathlib import Path
from urllib.parse import quote

scripts_dir = Path(sys.argv[1])
sqlite_path = Path(sys.argv[2])
icons_dir = Path(sys.argv[3])
sys.path.insert(0, str(scripts_dir))
import build_nms_sqlite

if not sqlite_path.is_file():
    raise SystemExit(f"Debug pack sqlite is missing: {sqlite_path}")
if not icons_dir.is_dir():
    raise SystemExit(f"Packed icons directory is missing: {icons_dir}")
packed_icons = sum(1 for path in icons_dir.rglob("*.png") if path.is_file())
if packed_icons <= 0:
    raise SystemExit("Debug pack icons directory does not contain any PNG files")

database_uri = f"file:{quote(str(sqlite_path.resolve()))}?mode=ro"
connection = sqlite3.connect(database_uri, uri=True)
try:
    connection.execute("pragma query_only = on")
    build_nms_sqlite.validate_production_feature_inventory(connection)
finally:
    connection.close()
print(f"Debug pack feature inventory verified with {packed_icons} packed icons.")
PY

echo "Full iOS Debug database ready"
echo "  SQLite: ${pack_dir}/nms-reference.sqlite"
echo "  sidecar: ${pack_dir}/pack-manifest.json"
echo "  icons: ${pack_dir}/icons"
