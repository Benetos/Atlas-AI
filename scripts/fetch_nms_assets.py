#!/usr/bin/env python3
"""Selectively fetch referenced NMS image blobs from a partial Git checkout."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def git_blob(source_repo: Path, commit_sha: str, upstream_path: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(source_repo), "show", f"{commit_sha}:{upstream_path}"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout


def safe_destination(root: Path, commit_sha: str, upstream_path: str) -> Path:
    relative = Path(upstream_path)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"Unsafe upstream path: {upstream_path}")
    destination = (root / commit_sha / relative).resolve()
    expected_root = (root / commit_sha).resolve()
    if expected_root not in destination.parents:
        raise ValueError(f"Asset path escapes output root: {upstream_path}")
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--asset-manifest",
        type=Path,
        default=Path("build/nms-import/assets.csv"),
    )
    parser.add_argument(
        "--source-repo",
        type=Path,
        default=Path(".cache/nms-handbook"),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("build/nms-assets"),
    )
    parser.add_argument(
        "--limit",
        type=int,
        help="Fetch at most this many assets for a test run",
    )
    parser.add_argument(
        "--approved",
        action="store_true",
        help="Required acknowledgement before downloading any game-derived assets",
    )
    args = parser.parse_args()

    if not args.asset_manifest.is_file():
        print(f"Missing asset manifest: {args.asset_manifest}", file=sys.stderr)
        return 2

    with args.asset_manifest.open("r", encoding="utf-8", newline="") as handle:
        rows = [
            row for row in csv.DictReader(handle)
            if row["status"] == "referenced" and row["upstream_png_path"]
        ]

    if args.limit is not None:
        if args.limit < 0:
            print("--limit must be non-negative", file=sys.stderr)
            return 2
        rows = rows[: args.limit]

    print(f"Referenced assets selected: {len(rows)}")
    if not args.approved:
        print("Dry run only. Pass --approved after the asset publication/download gate is approved.")
        return 0

    if not (args.source_repo / ".git").is_dir():
        print(f"Missing partial source checkout: {args.source_repo}", file=sys.stderr)
        return 2

    args.output_dir.mkdir(parents=True, exist_ok=True)
    fetched: list[dict[str, object]] = []

    for index, row in enumerate(rows, start=1):
        commit_sha = row["source_commit_sha"]
        upstream_path = row["upstream_png_path"]
        destination = safe_destination(args.output_dir, commit_sha, upstream_path)
        try:
            blob = git_blob(args.source_repo, commit_sha, upstream_path)
        except subprocess.CalledProcessError as error:
            message = error.stderr.decode("utf-8", errors="replace").strip()
            print(f"Unable to fetch {upstream_path}: {message}", file=sys.stderr)
            return 1
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(blob)
        fetched.append({
            "source_commit_sha": commit_sha,
            "source_path": row["source_path"],
            "upstream_png_path": upstream_path,
            "local_path": str(destination.relative_to(args.output_dir)),
            "content_sha256": hashlib.sha256(blob).hexdigest(),
            "byte_size": len(blob),
        })
        if index % 100 == 0:
            print(f"Fetched {index}/{len(rows)}")

    receipt_path = args.output_dir / "fetch-receipt.json"
    receipt_path.write_text(
        json.dumps({"assets": fetched}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Fetched assets: {len(fetched)}")
    print(f"Bytes: {sum(int(item['byte_size']) for item in fetched)}")
    print(f"Receipt: {receipt_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
