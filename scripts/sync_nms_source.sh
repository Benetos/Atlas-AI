#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
source_dir="${NMS_SOURCE_DIR:-${repo_root}/.cache/nms-handbook}"
source_ref="${NMS_SOURCE_REF:-142d9ffd8078944722243398202f22cbef47cd02}"
source_url="https://github.com/ApexFatality93/NMS-Handbook.git"

if [[ -e "${source_dir}" && ! -d "${source_dir}/.git" ]]; then
  echo "Refusing to use non-Git path: ${source_dir}" >&2
  exit 1
fi

if [[ ! -d "${source_dir}/.git" ]]; then
  mkdir -p "$(dirname "${source_dir}")"
  git clone --filter=blob:none --no-checkout --sparse "${source_url}" "${source_dir}"
fi

git -C "${source_dir}" sparse-checkout init --cone
git -C "${source_dir}" sparse-checkout set JSON_Files "Python Files"
git -C "${source_dir}" fetch --depth 1 origin "${source_ref}"
git -C "${source_dir}" checkout --detach FETCH_HEAD

resolved_sha="$(git -C "${source_dir}" rev-parse HEAD)"
checked_out_bytes="$(du -sk "${source_dir}" | awk '{print $1 * 1024}')"

echo "NMS source ready"
echo "  path: ${source_dir}"
echo "  requested ref: ${source_ref}"
echo "  resolved commit: ${resolved_sha}"
echo "  checked-out bytes (including Git metadata): ${checked_out_bytes}"
