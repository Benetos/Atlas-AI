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

echo "Full iOS Debug database ready"
echo "  SQLite: ${pack_dir}/nms-reference.sqlite"
echo "  sidecar: ${pack_dir}/pack-manifest.json"
