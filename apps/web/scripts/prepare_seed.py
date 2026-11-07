#!/usr/bin/env python3
"""Export apps/web/seed JSONL from the built SQLite pack (same transform pipeline)."""

from __future__ import annotations

import argparse
import gzip
import json
import sqlite3
import sys
from pathlib import Path

PUBLIC_SOURCE_REPO = "https://github.com/ApexFatality93/NMS-Handbook"

TABLES = {
    "entities": (
        "nms_entities",
        [
            "entity_type",
            "game_id",
            "name_id",
            "name_lower_id",
            "subtitle_id",
            "description_id",
            "name",
            "display_name",
            "subtitle",
            "description",
            "category",
            "subcategory",
            "rarity",
            "legality",
            "base_value",
            "icon_source_path",
            "icon_storage_path",
            "color_r",
            "color_g",
            "color_b",
            "color_a",
            "attributes",
            "source_dataset",
            "source_commit_sha",
        ],
    ),
    "recipes": (
        "nms_recipes",
        [
            "recipe_id",
            "recipe_kind",
            "output_entity_type",
            "output_game_id",
            "output_amount",
            "time_seconds",
            "recipe_type",
            "recipe_name",
            "source_ordinal",
            "attributes",
            "source_commit_sha",
        ],
    ),
    "recipe_ingredients": (
        "nms_recipe_ingredients",
        [
            "recipe_id",
            "position",
            "ingredient_entity_type",
            "ingredient_game_id",
            "amount",
            "attributes",
            "source_commit_sha",
        ],
    ),
    "content_records": (
        "nms_content_records",
        [
            "dataset",
            "external_id",
            "source_ordinal",
            "display_name",
            "icon_source_path",
            "payload",
            "source_commit_sha",
        ],
    ),
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sqlite",
        type=Path,
        default=Path(__file__).resolve().parents[3]
        / "build"
        / "nms-sqlite"
        / "nms-reference.sqlite",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "seed",
    )
    args = parser.parse_args()
    if not args.sqlite.is_file():
        print(
            f"Missing SQLite pack at {args.sqlite}. "
            "Run ./scripts/prepare_ios_debug_pack.sh first.",
            file=sys.stderr,
        )
        return 1

    args.out_dir.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(args.sqlite)
    conn.row_factory = sqlite3.Row
    row = dict(conn.execute("select * from pack_manifest").fetchone())
    counts = json.loads(row["counts_json"])
    manifest = {
        "pack_schema_version": int(row["pack_schema_version"]),
        "contract_version": int(row["contract_version"]),
        "source_repository": PUBLIC_SOURCE_REPO,
        "source_commit_sha": row["source_commit_sha"],
        "source_committed_at": row["source_committed_at"],
        "generated_at": row["generated_at"],
        "counts": {key: int(value) for key, value in counts.items()},
        "input_manifest_sha256": row["input_manifest_sha256"],
    }
    (args.out_dir / "pack_manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    print("pack_manifest", manifest["counts"])

    for stale in args.out_dir.glob("*.csv.gz"):
        stale.unlink()

    for name, (table, cols) in TABLES.items():
        path = args.out_dir / f"{name}.jsonl.gz"
        rows = conn.execute(f"select {', '.join(cols)} from {table}").fetchall()
        with gzip.open(path, "wt", encoding="utf-8") as handle:
            for item in rows:
                handle.write(
                    json.dumps(
                        {col: item[col] for col in cols},
                        ensure_ascii=False,
                        separators=(",", ":"),
                    )
                    + "\n"
                )
        print(f"{name}: {len(rows)} -> {path}")

    conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
