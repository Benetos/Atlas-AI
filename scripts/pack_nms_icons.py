#!/usr/bin/env python3
"""Map fetched NMS PNGs into the pack-relative icons/ layout."""

from __future__ import annotations

import argparse
import csv
import shutil
from pathlib import Path


def pack_relative_path(source_path: str) -> str | None:
    path = source_path.replace("\\", "/").strip()
    while path.startswith("/"):
        path = path[1:]
    if not path:
        return None
    lower = path.lower()
    if lower.endswith(".dds"):
        path = path[:-4] + ".png"
    elif not lower.endswith(".png"):
        path += ".png"
    return "icons/" + path.lower()


def pack_icons(
    *,
    asset_manifest: Path,
    fetch_dir: Path,
    pack_dir: Path,
) -> dict[str, int]:
    if not asset_manifest.is_file():
        raise FileNotFoundError(f"Missing asset manifest: {asset_manifest}")
    pack_dir.mkdir(parents=True, exist_ok=True)
    icons_root = pack_dir / "icons"
    if icons_root.exists():
        shutil.rmtree(icons_root)
    icons_root.mkdir(parents=True)

    copied = 0
    missing = 0
    referenced = 0
    with asset_manifest.open("r", encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            if row.get("status") != "referenced":
                if row.get("status") == "missing":
                    missing += 1
                continue
            referenced += 1
            relative = pack_relative_path(row.get("source_path") or "")
            if relative is None:
                missing += 1
                continue
            source = fetch_dir / row["source_commit_sha"] / row["upstream_png_path"]
            destination = pack_dir / relative
            if not source.is_file():
                missing += 1
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
            copied += 1
    return {
        "referenced": referenced,
        "copied": copied,
        "missing": missing,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--asset-manifest",
        type=Path,
        default=Path("build/nms-import/assets.csv"),
    )
    parser.add_argument(
        "--fetch-dir",
        type=Path,
        default=Path("build/nms-assets"),
    )
    parser.add_argument(
        "--pack-dir",
        type=Path,
        default=Path("build/nms-sqlite"),
    )
    args = parser.parse_args()
    counts = pack_icons(
        asset_manifest=args.asset_manifest,
        fetch_dir=args.fetch_dir,
        pack_dir=args.pack_dir,
    )
    print(
        "Packed icons: "
        f"{counts['copied']} copied, {counts['referenced']} referenced, "
        f"{counts['missing']} missing/placeholder"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
