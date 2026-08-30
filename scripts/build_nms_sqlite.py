#!/usr/bin/env python3
"""Build a pinned offline SQLite snapshot from Atlas transform CSVs."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


PACK_SCHEMA_VERSION = 1
REQUIRED_INPUTS = (
    "entities.csv",
    "localizations.csv",
    "recipes.csv",
    "recipe_ingredients.csv",
    "content_records.csv",
)
JSON_FIELDS = {"payload", "attributes"}
INTEGER_FIELDS = {"source_ordinal", "position"}
BOOLEAN_FIELDS = {"is_preferred"}
NUMERIC_FIELDS = {
    "base_value",
    "color_r",
    "color_g",
    "color_b",
    "color_a",
    "output_amount",
    "time_seconds",
    "amount",
}
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9_]+")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def decode_csv_value(field: str, value: str) -> Any:
    if value == "":
        return None
    if field in JSON_FIELDS:
        return json.dumps(
            json.loads(value),
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    if field in INTEGER_FIELDS:
        return int(value)
    if field in BOOLEAN_FIELDS:
        normalized = value.casefold()
        if normalized not in {"true", "false"}:
            raise ValueError(f"Invalid boolean for {field}: {value!r}")
        return 1 if normalized == "true" else 0
    if field in NUMERIC_FIELDS:
        return value
    return value


def verify_transform_manifest(import_dir: Path) -> dict[str, Any]:
    manifest_path = import_dir / "manifest.json"
    if not manifest_path.is_file():
        raise ValueError(f"Missing transform manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not manifest.get("validation", {}).get("passed", False):
        raise ValueError("Refusing to pack a transform that failed validation")
    outputs = manifest.get("outputs") or {}
    for filename in REQUIRED_INPUTS:
        path = import_dir / filename
        if not path.is_file():
            raise ValueError(f"Missing transform output: {path}")
        recorded = (outputs.get(filename) or {}).get("sha256")
        actual = sha256_file(path)
        if recorded != actual:
            raise ValueError(
                f"Hash mismatch for {filename}: manifest {recorded} != {actual}"
            )
    commit = (manifest.get("source") or {}).get("commit_sha")
    if not isinstance(commit, str) or len(commit) != 40:
        raise ValueError("Transform manifest is missing a 40-character source commit")
    return manifest


def iter_csv_rows(path: Path) -> Iterable[dict[str, Any]]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            raise ValueError(f"CSV has no header: {path}")
        for row in reader:
            yield {
                field: decode_csv_value(field, value)
                for field, value in row.items()
            }


def fts_match_query(text: str) -> str:
    tokens = TOKEN_PATTERN.findall(text.casefold())
    if not tokens:
        return '""'
    return " AND ".join(f'"{token}"' for token in tokens)


def create_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        pragma journal_mode = off;
        pragma synchronous = off;
        pragma foreign_keys = on;

        create table pack_manifest (
          pack_schema_version integer not null,
          contract_version integer not null,
          source_repository text not null,
          source_commit_sha text not null,
          source_committed_at text,
          generated_at text not null,
          counts_json text not null,
          input_manifest_sha256 text not null
        );

        create table nms_entities (
          entity_type text not null
            check (entity_type in ('product', 'substance', 'technology')),
          game_id text not null,
          name_id text,
          name_lower_id text,
          subtitle_id text,
          description_id text,
          name text,
          display_name text,
          subtitle text,
          description text,
          category text,
          subcategory text,
          rarity text,
          legality text,
          base_value text,
          icon_source_path text,
          icon_storage_path text,
          color_r text,
          color_g text,
          color_b text,
          color_a text,
          attributes text not null default '{}',
          source_dataset text not null,
          source_commit_sha text not null,
          primary key (entity_type, game_id)
        );

        create virtual table nms_entities_fts using fts5(
          display_name,
          name,
          subtitle,
          description,
          entity_type unindexed,
          game_id unindexed,
          tokenize = 'porter unicode61'
        );

        create table nms_localizations (
          localization_id text not null,
          locale text not null,
          source_ordinal integer not null,
          value text not null,
          is_preferred integer not null check (is_preferred = 1),
          source_commit_sha text not null,
          primary key (localization_id, locale)
        );

        create table nms_recipes (
          recipe_id text primary key,
          recipe_kind text not null
            check (recipe_kind in ('crafting', 'refining', 'cooking')),
          output_entity_type text not null,
          output_game_id text not null,
          output_amount text,
          time_seconds text,
          recipe_type text,
          recipe_name text,
          source_ordinal integer not null,
          attributes text not null default '{}',
          source_commit_sha text not null,
          foreign key (output_entity_type, output_game_id)
            references nms_entities (entity_type, game_id)
        );

        create index nms_recipes_output_idx
          on nms_recipes (output_entity_type, output_game_id);
        create index nms_recipes_kind_idx
          on nms_recipes (recipe_kind);

        create table nms_recipe_ingredients (
          recipe_id text not null
            references nms_recipes (recipe_id),
          position integer not null,
          ingredient_entity_type text not null,
          ingredient_game_id text not null,
          amount text,
          attributes text not null default '{}',
          source_commit_sha text not null,
          primary key (recipe_id, position),
          foreign key (ingredient_entity_type, ingredient_game_id)
            references nms_entities (entity_type, game_id)
        );

        create index nms_recipe_ingredients_entity_idx
          on nms_recipe_ingredients (ingredient_entity_type, ingredient_game_id);

        create table nms_content_records (
          dataset text not null,
          external_id text not null,
          source_ordinal integer not null,
          display_name text,
          icon_source_path text,
          payload text not null,
          source_commit_sha text not null,
          primary key (dataset, external_id, source_ordinal)
        );

        create virtual table nms_content_fts using fts5(
          display_name,
          dataset unindexed,
          external_id unindexed,
          source_ordinal unindexed,
          payload,
          tokenize = 'porter unicode61'
        );
        """
    )


def insert_entities(connection: sqlite3.Connection, rows: Iterable[dict[str, Any]]) -> int:
    count = 0
    for row in rows:
        connection.execute(
            """
            insert into nms_entities (
              entity_type, game_id, name_id, name_lower_id, subtitle_id,
              description_id, name, display_name, subtitle, description,
              category, subcategory, rarity, legality, base_value,
              icon_source_path, icon_storage_path, color_r, color_g, color_b,
              color_a, attributes, source_dataset, source_commit_sha
            ) values (
              :entity_type, :game_id, :name_id, :name_lower_id, :subtitle_id,
              :description_id, :name, :display_name, :subtitle, :description,
              :category, :subcategory, :rarity, :legality, :base_value,
              :icon_source_path, :icon_storage_path, :color_r, :color_g, :color_b,
              :color_a, :attributes, :source_dataset, :source_commit_sha
            )
            """,
            row,
        )
        connection.execute(
            """
            insert into nms_entities_fts (
              display_name, name, subtitle, description, entity_type, game_id
            ) values (?, ?, ?, ?, ?, ?)
            """,
            (
                row.get("display_name") or "",
                row.get("name") or "",
                row.get("subtitle") or "",
                row.get("description") or "",
                row["entity_type"],
                row["game_id"],
            ),
        )
        count += 1
    return count


def insert_localizations(
    connection: sqlite3.Connection, rows: Iterable[dict[str, Any]]
) -> int:
    count = 0
    for row in rows:
        if not row.get("is_preferred"):
            continue
        connection.execute(
            """
            insert into nms_localizations (
              localization_id, locale, source_ordinal, value, is_preferred,
              source_commit_sha
            ) values (
              :localization_id, :locale, :source_ordinal, :value, :is_preferred,
              :source_commit_sha
            )
            """,
            row,
        )
        count += 1
    return count


def insert_recipes(connection: sqlite3.Connection, rows: Iterable[dict[str, Any]]) -> int:
    count = 0
    for row in rows:
        connection.execute(
            """
            insert into nms_recipes (
              recipe_id, recipe_kind, output_entity_type, output_game_id,
              output_amount, time_seconds, recipe_type, recipe_name,
              source_ordinal, attributes, source_commit_sha
            ) values (
              :recipe_id, :recipe_kind, :output_entity_type, :output_game_id,
              :output_amount, :time_seconds, :recipe_type, :recipe_name,
              :source_ordinal, :attributes, :source_commit_sha
            )
            """,
            row,
        )
        count += 1
    return count


def insert_ingredients(
    connection: sqlite3.Connection, rows: Iterable[dict[str, Any]]
) -> int:
    count = 0
    for row in rows:
        connection.execute(
            """
            insert into nms_recipe_ingredients (
              recipe_id, position, ingredient_entity_type, ingredient_game_id,
              amount, attributes, source_commit_sha
            ) values (
              :recipe_id, :position, :ingredient_entity_type, :ingredient_game_id,
              :amount, :attributes, :source_commit_sha
            )
            """,
            row,
        )
        count += 1
    return count


def insert_content(connection: sqlite3.Connection, rows: Iterable[dict[str, Any]]) -> int:
    count = 0
    for row in rows:
        connection.execute(
            """
            insert into nms_content_records (
              dataset, external_id, source_ordinal, display_name,
              icon_source_path, payload, source_commit_sha
            ) values (
              :dataset, :external_id, :source_ordinal, :display_name,
              :icon_source_path, :payload, :source_commit_sha
            )
            """,
            row,
        )
        connection.execute(
            """
            insert into nms_content_fts (
              display_name, dataset, external_id, source_ordinal, payload
            ) values (?, ?, ?, ?, ?)
            """,
            (
                row.get("display_name") or "",
                row["dataset"],
                row["external_id"],
                row["source_ordinal"],
                row.get("payload") or "",
            ),
        )
        count += 1
    return count


def build_pack(import_dir: Path, output_dir: Path) -> int:
    import_dir = import_dir.resolve()
    output_dir = output_dir.resolve()
    manifest = verify_transform_manifest(import_dir)
    source = manifest["source"]
    output_dir.mkdir(parents=True, exist_ok=True)
    sqlite_path = output_dir / "nms-reference.sqlite"
    sidecar_path = output_dir / "pack-manifest.json"
    if sqlite_path.exists():
        sqlite_path.unlink()

    connection = sqlite3.connect(sqlite_path)
    try:
        create_schema(connection)
        entity_count = insert_entities(
            connection, iter_csv_rows(import_dir / "entities.csv")
        )
        localization_count = insert_localizations(
            connection, iter_csv_rows(import_dir / "localizations.csv")
        )
        recipe_count = insert_recipes(
            connection, iter_csv_rows(import_dir / "recipes.csv")
        )
        ingredient_count = insert_ingredients(
            connection, iter_csv_rows(import_dir / "recipe_ingredients.csv")
        )
        content_count = insert_content(
            connection, iter_csv_rows(import_dir / "content_records.csv")
        )
        counts = {
            "entities": entity_count,
            "localizations_preferred": localization_count,
            "recipes": recipe_count,
            "recipe_ingredients": ingredient_count,
            "content_records": content_count,
        }
        connection.execute(
            """
            insert into pack_manifest (
              pack_schema_version, contract_version, source_repository,
              source_commit_sha, source_committed_at, generated_at,
              counts_json, input_manifest_sha256
            ) values (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                PACK_SCHEMA_VERSION,
                int(manifest.get("contract_version") or 1),
                source["repository"],
                source["commit_sha"],
                source.get("committed_at"),
                datetime.now(timezone.utc).isoformat(),
                json.dumps(counts, separators=(",", ":"), sort_keys=True),
                sha256_file(import_dir / "manifest.json"),
            ),
        )
        connection.execute("analyze")
        connection.commit()
    finally:
        connection.close()

    sidecar = {
        "pack_schema_version": PACK_SCHEMA_VERSION,
        "contract_version": int(manifest.get("contract_version") or 1),
        "asset_pack_id": "nms-reference",
        "source_repository": source["repository"],
        "source_commit_sha": source["commit_sha"],
        "source_committed_at": source.get("committed_at"),
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "counts": counts,
        "sqlite": {
            "file": sqlite_path.name,
            "bytes": sqlite_path.stat().st_size,
            "sha256": sha256_file(sqlite_path),
        },
        "validation": {
            "passed": True,
            "errors": [],
        },
    }
    sidecar_path.write_text(
        json.dumps(sidecar, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"SQLite pack: {sqlite_path}")
    print(f"Source commit: {source['commit_sha']}")
    for key, value in counts.items():
        print(f"  {key}: {value}")
    print(f"Manifest: {sidecar_path}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--import-dir",
        type=Path,
        default=Path("build/nms-import"),
        help="Directory containing transform CSVs and manifest.json",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("build/nms-sqlite"),
        help="Directory for nms-reference.sqlite and pack-manifest.json",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    return build_pack(args.import_dir, args.output_dir)


if __name__ == "__main__":
    raise SystemExit(main())
