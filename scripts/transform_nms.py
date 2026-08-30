#!/usr/bin/env python3
"""Transform a pinned NMS-Handbook JSON snapshot into Atlas import files."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterable


CONTRACT_VERSION = 1
DEFAULT_SOURCE_REPOSITORY = "https://github.com/ApexFatality93/NMS-Handbook"
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
ASSET_PATTERN = re.compile(r"^TEXTURES[\\/].*\.(?:DDS|PNG)$", re.IGNORECASE)

DATASETS = {
    "All_Lang_Data.json": "localizations",
    "Bait_Table.json": "bait",
    "Building_Parts_Table.json": "building_parts",
    "Cooking_Table.json": "cooking",
    "Corvette_Parts_Table.json": "corvette_parts",
    "Crafting_Table.json": "crafting",
    "Expedition_Table.json": "expeditions",
    "Fish_Table.json": "fish",
    "Fossil_Table.json": "fossils",
    "Legacy_Item_Table.json": "legacy_items",
    "Product_Table.json": "products",
    "Purchaseable_Building_Blueprints.json": "purchaseable_building_blueprints",
    "Refining_Table.json": "refining",
    "Ship_Part_Table.json": "ship_parts",
    "Special_Purchase_Table.json": "special_purchases",
    "Special_Rewards_Table.json": "special_rewards",
    "Story_Table.json": "stories",
    "Substance_Table.json": "substances",
    "Technology_Table.json": "technology",
}

ENTITY_SOURCES = {
    "Product_Table.json": "product",
    "Substance_Table.json": "substance",
    "Technology_Table.json": "technology",
}

FEATURE_SOURCES = {
    filename for filename in DATASETS
    if filename not in ENTITY_SOURCES
    and filename not in {
        "All_Lang_Data.json",
        "Crafting_Table.json",
        "Refining_Table.json",
        "Cooking_Table.json",
    }
}


def compact_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def null_text(value: Any) -> str:
    if value is None or value == "":
        return ""
    return str(value)


def numeric_text(value: Any, field: str, errors: list[str]) -> str:
    if value is None or value == "":
        return ""
    try:
        number = Decimal(str(value))
    except InvalidOperation:
        errors.append(f"Invalid numeric value for {field}: {value!r}")
        return ""
    return format(number, "f")


def normalize_entity_type(value: Any) -> str:
    normalized = str(value or "").strip().lower()
    aliases = {
        "product": "product",
        "substance": "substance",
        "technology": "technology",
    }
    return aliases.get(normalized, normalized)


def source_records(data: Any) -> Iterable[tuple[str, int, Any]]:
    if isinstance(data, dict):
        for ordinal, (external_id, payload) in enumerate(data.items()):
            yield str(external_id), ordinal, payload
        return
    if isinstance(data, list):
        for ordinal, payload in enumerate(data):
            if isinstance(payload, dict):
                external_id = (
                    payload.get("Id")
                    or payload.get("ID")
                    or payload.get("ProductId")
                    or payload.get("ProductID")
                    or f"row-{ordinal}"
                )
            else:
                external_id = f"row-{ordinal}"
            yield str(external_id), ordinal, payload
        return
    raise TypeError(f"Unsupported top-level JSON type: {type(data).__name__}")


def iter_asset_strings(value: Any) -> Iterable[str]:
    if isinstance(value, dict):
        for nested in value.values():
            yield from iter_asset_strings(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from iter_asset_strings(nested)
    elif isinstance(value, str) and ASSET_PATTERN.match(value):
        yield value.replace("\\", "/")


def run_git(source_repo: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(source_repo), *arguments],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


def resolve_source_metadata(
    source_repo: Path | None,
    commit_override: str | None,
) -> tuple[str, str, str | None, dict[str, str]]:
    if commit_override:
        commit_sha = commit_override.lower()
    elif source_repo:
        commit_sha = run_git(source_repo, "rev-parse", "HEAD").lower()
    else:
        raise ValueError("Provide --source-repo or --source-commit")

    if not COMMIT_PATTERN.fullmatch(commit_sha):
        raise ValueError(f"Invalid source commit SHA: {commit_sha!r}")

    source_repository = DEFAULT_SOURCE_REPOSITORY
    committed_at: str | None = None
    tree_paths: dict[str, str] = {}

    if source_repo:
        try:
            remote = run_git(source_repo, "remote", "get-url", "origin")
            source_repository = remote.removesuffix(".git")
        except subprocess.CalledProcessError:
            pass
        try:
            committed_at = run_git(source_repo, "show", "-s", "--format=%cI", "HEAD")
        except subprocess.CalledProcessError:
            pass
        try:
            paths = run_git(
                source_repo,
                "ls-tree",
                "-r",
                "--name-only",
                "HEAD",
                "--",
                "TEXTURES",
            ).splitlines()
            tree_paths = {
                path.casefold(): path
                for path in paths
                if path.lower().endswith(".png")
            }
        except subprocess.CalledProcessError:
            pass

    return source_repository, commit_sha, committed_at, tree_paths


def write_csv(path: Path, fieldnames: list[str], rows: list[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def transform(args: argparse.Namespace) -> int:
    source_dir = args.source_dir.resolve()
    source_repo = args.source_repo.resolve() if args.source_repo else None
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    errors: list[str] = []
    warnings: list[str] = []

    try:
        source_repository, commit_sha, committed_at, tree_paths = resolve_source_metadata(
            source_repo,
            args.source_commit,
        )
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"Source metadata error: {error}", file=sys.stderr)
        return 2

    loaded: dict[str, Any] = {}
    input_manifest: dict[str, Any] = {}

    for filename, dataset in DATASETS.items():
        path = source_dir / filename
        if not path.is_file():
            errors.append(f"Missing required source file: {filename}")
            continue
        try:
            with path.open("r", encoding="utf-8") as handle:
                value = json.load(handle)
        except (OSError, json.JSONDecodeError) as error:
            errors.append(f"Unable to parse {filename}: {error}")
            continue
        if filename == "All_Lang_Data.json" and not isinstance(value, list):
            errors.append(f"{filename} must be an array")
        elif filename != "All_Lang_Data.json" and not isinstance(value, dict):
            errors.append(f"{filename} must be an ID-keyed object")
        loaded[filename] = value
        input_manifest[filename] = {
            "dataset": dataset,
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
            "shape": "array" if isinstance(value, list) else "object",
            "records": len(value) if isinstance(value, (list, dict)) else None,
        }

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1

    raw_rows: list[dict[str, Any]] = []
    entity_rows: list[dict[str, Any]] = []
    localization_rows: list[dict[str, Any]] = []
    recipe_rows: list[dict[str, Any]] = []
    ingredient_rows: list[dict[str, Any]] = []
    content_rows: list[dict[str, Any]] = []
    asset_usage: dict[str, set[str]] = defaultdict(set)

    for filename, data in loaded.items():
        dataset = DATASETS[filename]
        for external_id, ordinal, payload in source_records(data):
            encoded = compact_json(payload)
            raw_rows.append({
                "dataset": dataset,
                "external_id": external_id,
                "source_ordinal": ordinal,
                "payload": encoded,
                "payload_sha256": sha256_bytes(encoded.encode("utf-8")),
            })
        for asset_path in iter_asset_strings(data):
            asset_usage[asset_path].add(dataset)

    entity_identities: set[tuple[str, str]] = set()
    for filename, entity_type in ENTITY_SOURCES.items():
        dataset = DATASETS[filename]
        records = loaded[filename]
        for game_id, payload in records.items():
            identity = (entity_type, str(game_id))
            if identity in entity_identities:
                errors.append(f"Duplicate entity identity: {identity}")
            entity_identities.add(identity)
            entity_rows.append({
                "entity_type": entity_type,
                "game_id": game_id,
                "name_id": null_text(payload.get("Name")),
                "name_lower_id": null_text(payload.get("NameLower")),
                "subtitle_id": null_text(payload.get("Subtitle")),
                "description_id": null_text(payload.get("Description")),
                "name": null_text(payload.get("Name_Text")),
                "display_name": null_text(
                    payload.get("NameLower_Text") or payload.get("Name_Text")
                ),
                "subtitle": null_text(payload.get("Subtitle_Text")),
                "description": null_text(payload.get("Description_Text")),
                "category": null_text(payload.get("Category")),
                "subcategory": null_text(payload.get("Type")),
                "rarity": null_text(payload.get("Rarity")),
                "legality": null_text(payload.get("Legality")),
                "base_value": numeric_text(
                    payload.get("BaseValue") or payload.get("Value"),
                    f"{dataset}.{game_id}.base_value",
                    errors,
                ),
                "icon_source_path": null_text(payload.get("Icon_Filename")),
                "icon_storage_path": "",
                "color_r": numeric_text(payload.get("Colour_R"), "color_r", errors),
                "color_g": numeric_text(payload.get("Colour_G"), "color_g", errors),
                "color_b": numeric_text(payload.get("Colour_B"), "color_b", errors),
                "color_a": numeric_text(payload.get("Colour_A"), "color_a", errors),
                "attributes": compact_json(payload),
                "source_dataset": dataset,
                "source_commit_sha": commit_sha,
            })

    localization_data = loaded["All_Lang_Data.json"]
    last_localization_index: dict[str, int] = {}
    localization_values: dict[str, set[str]] = defaultdict(set)
    for ordinal, payload in enumerate(localization_data):
        localization_id = str(payload.get("Id") or f"row-{ordinal}")
        last_localization_index[localization_id] = ordinal
        localization_values[localization_id].add(str(payload.get("English") or ""))
    for ordinal, payload in enumerate(localization_data):
        localization_id = str(payload.get("Id") or f"row-{ordinal}")
        localization_rows.append({
            "localization_id": localization_id,
            "locale": "en",
            "source_ordinal": ordinal,
            "value": null_text(payload.get("English")),
            "is_preferred": "true" if last_localization_index[localization_id] == ordinal else "false",
            "source_commit_sha": commit_sha,
        })
    localization_conflicts = {
        key: sorted(values)
        for key, values in localization_values.items()
        if len(values) > 1
    }
    if localization_conflicts:
        warnings.append(
            f"{len(localization_conflicts)} localization IDs have conflicting values"
        )

    def add_recipe(
        kind: str,
        output_type: str,
        output_id: str,
        ordinal: int,
        recipe: dict[str, Any],
        ingredients: list[dict[str, Any]],
        fallback_name: str = "",
    ) -> None:
        output_type = normalize_entity_type(output_type)
        recipe_id = f"{kind}:{output_type}:{output_id}:{ordinal}"
        if output_type not in {"product", "substance", "technology"}:
            errors.append(f"Unknown recipe output type {output_type!r} in {recipe_id}")
        if (output_type, output_id) not in entity_identities:
            errors.append(f"Missing recipe output entity {output_type}:{output_id}")
        recipe_rows.append({
            "recipe_id": recipe_id,
            "recipe_kind": kind,
            "output_entity_type": output_type,
            "output_game_id": output_id,
            "output_amount": numeric_text(
                recipe.get("Amount") or "1",
                f"{recipe_id}.output_amount",
                errors,
            ),
            "time_seconds": numeric_text(
                recipe.get("TimeToMake"),
                f"{recipe_id}.time_seconds",
                errors,
            ),
            "recipe_type": null_text(recipe.get("RecipeType") or kind.title()),
            "recipe_name": null_text(recipe.get("RecipeName") or fallback_name),
            "source_ordinal": ordinal,
            "attributes": compact_json({
                key: value for key, value in recipe.items() if key != "Ingredients"
            }),
            "source_commit_sha": commit_sha,
        })
        for position, ingredient in enumerate(ingredients):
            ingredient_type = normalize_entity_type(ingredient.get("Type"))
            ingredient_id = str(ingredient.get("Id") or "")
            if ingredient_type not in {"product", "substance", "technology"}:
                errors.append(
                    f"Unknown ingredient type {ingredient_type!r} in {recipe_id}"
                )
            if not ingredient_id:
                errors.append(f"Missing ingredient ID in {recipe_id} position {position}")
            elif (ingredient_type, ingredient_id) not in entity_identities:
                errors.append(
                    f"Missing ingredient entity {ingredient_type}:{ingredient_id} "
                    f"in {recipe_id}"
                )
            ingredient_rows.append({
                "recipe_id": recipe_id,
                "position": position,
                "ingredient_entity_type": ingredient_type,
                "ingredient_game_id": ingredient_id,
                "amount": numeric_text(
                    ingredient.get("Amount"),
                    f"{recipe_id}.ingredient[{position}].amount",
                    errors,
                ),
                "attributes": compact_json(ingredient),
                "source_commit_sha": commit_sha,
            })

    for output_id, payload in loaded["Crafting_Table.json"].items():
        add_recipe(
            "crafting",
            "product",
            str(output_id),
            0,
            payload,
            list(payload.get("Ingredients") or []),
            str(payload.get("NameLower_Text") or payload.get("Name_Text") or output_id),
        )

    for filename, kind in (
        ("Refining_Table.json", "refining"),
        ("Cooking_Table.json", "cooking"),
    ):
        for output_id, payload in loaded[filename].items():
            output_type = payload.get("Type") if kind == "refining" else "product"
            for ordinal, recipe in enumerate(payload.get("Recipes") or []):
                add_recipe(
                    kind,
                    str(output_type),
                    str(output_id),
                    ordinal,
                    recipe,
                    list(recipe.get("Ingredients") or []),
                    str(payload.get("NameLower_Text") or payload.get("Name_Text") or output_id),
                )

    recipe_ids = [row["recipe_id"] for row in recipe_rows]
    duplicate_recipes = [item for item, count in Counter(recipe_ids).items() if count > 1]
    if duplicate_recipes:
        errors.append(f"Duplicate recipe IDs: {duplicate_recipes[:10]}")

    ingredient_keys = [(row["recipe_id"], row["position"]) for row in ingredient_rows]
    if len(ingredient_keys) != len(set(ingredient_keys)):
        errors.append("Duplicate recipe ingredient positions found")

    for filename in sorted(FEATURE_SOURCES):
        dataset = DATASETS[filename]
        for external_id, ordinal, payload in source_records(loaded[filename]):
            if not isinstance(payload, dict):
                errors.append(f"Feature payload must be an object: {dataset}:{external_id}")
                continue
            content_rows.append({
                "dataset": dataset,
                "external_id": external_id,
                "source_ordinal": ordinal,
                "display_name": null_text(
                    payload.get("NameLower_Text")
                    or payload.get("Name_Text")
                    or payload.get("SeasonName")
                    or payload.get("RewardName")
                    or payload.get("CategoryText")
                ),
                "icon_source_path": null_text(
                    payload.get("Icon_Filename")
                    or payload.get("PageIcon")
                    or payload.get("IconOn")
                ),
                "payload": compact_json(payload),
                "source_commit_sha": commit_sha,
            })

    asset_rows: list[dict[str, Any]] = []
    for source_path in sorted(asset_usage, key=str.casefold):
        normalized = source_path.replace("\\", "/")
        expected_png = re.sub(r"\.DDS$", ".png", normalized, flags=re.IGNORECASE)
        upstream_path = tree_paths.get(expected_png.casefold(), "")
        exists = bool(upstream_path)
        if tree_paths and not exists:
            warnings.append(f"No upstream PNG found for {source_path}")
        storage_path = (
            f"{commit_sha}/{upstream_path.lower()}" if upstream_path else ""
        )
        asset_rows.append({
            "source_commit_sha": commit_sha,
            "source_path": source_path,
            "upstream_png_path": upstream_path,
            "storage_bucket": "nms-assets" if exists else "",
            "storage_path": storage_path,
            "mime_type": "image/png",
            "content_sha256": "",
            "byte_size": "",
            "status": "referenced" if exists else "missing",
            "referenced_by": compact_json(sorted(asset_usage[source_path])),
        })

    outputs = {
        "source_records.csv": (
            ["dataset", "external_id", "source_ordinal", "payload", "payload_sha256"],
            raw_rows,
        ),
        "entities.csv": (
            [
                "entity_type", "game_id", "name_id", "name_lower_id",
                "subtitle_id", "description_id", "name", "display_name",
                "subtitle", "description", "category", "subcategory", "rarity",
                "legality", "base_value", "icon_source_path", "icon_storage_path",
                "color_r", "color_g", "color_b", "color_a", "attributes",
                "source_dataset", "source_commit_sha",
            ],
            entity_rows,
        ),
        "localizations.csv": (
            [
                "localization_id", "locale", "source_ordinal", "value",
                "is_preferred", "source_commit_sha",
            ],
            localization_rows,
        ),
        "recipes.csv": (
            [
                "recipe_id", "recipe_kind", "output_entity_type", "output_game_id",
                "output_amount", "time_seconds", "recipe_type", "recipe_name",
                "source_ordinal", "attributes", "source_commit_sha",
            ],
            recipe_rows,
        ),
        "recipe_ingredients.csv": (
            [
                "recipe_id", "position", "ingredient_entity_type",
                "ingredient_game_id", "amount", "attributes", "source_commit_sha",
            ],
            ingredient_rows,
        ),
        "content_records.csv": (
            [
                "dataset", "external_id", "source_ordinal", "display_name",
                "icon_source_path", "payload", "source_commit_sha",
            ],
            content_rows,
        ),
        "assets.csv": (
            [
                "source_commit_sha", "source_path", "upstream_png_path",
                "storage_bucket", "storage_path", "mime_type", "content_sha256",
                "byte_size", "status", "referenced_by",
            ],
            asset_rows,
        ),
    }

    output_manifest: dict[str, Any] = {}
    for filename, (fields, rows) in outputs.items():
        path = output_dir / filename
        write_csv(path, fields, rows)
        output_manifest[filename] = {
            "rows": len(rows),
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        }

    manifest = {
        "contract_version": CONTRACT_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": {
            "repository": source_repository,
            "commit_sha": commit_sha,
            "committed_at": committed_at,
        },
        "inputs": input_manifest,
        "outputs": output_manifest,
        "counts": {
            "source_records": len(raw_rows),
            "entities": len(entity_rows),
            "localizations": len(localization_rows),
            "localization_conflicts": len(localization_conflicts),
            "recipes": len(recipe_rows),
            "recipe_ingredients": len(ingredient_rows),
            "content_records": len(content_rows),
            "referenced_assets": len(asset_rows),
            "missing_assets": sum(row["status"] == "missing" for row in asset_rows),
        },
        "validation": {
            "passed": not errors,
            "errors": errors,
            "warnings": warnings,
            "localization_conflicts": localization_conflicts,
        },
    }

    manifest_path = output_dir / "manifest.json"
    with manifest_path.open("w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, ensure_ascii=False, sort_keys=True)
        handle.write("\n")

    print(f"Source commit: {commit_sha}")
    print(f"Output directory: {output_dir}")
    for filename, details in output_manifest.items():
        print(f"  {filename}: {details['rows']} rows")
    print(f"Validation errors: {len(errors)}")
    print(f"Validation warnings: {len(warnings)}")
    print(f"Manifest: {manifest_path}")

    return 1 if errors else 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=Path(".cache/nms-handbook/JSON_Files"),
        help="Directory containing the upstream JSON files",
    )
    parser.add_argument(
        "--source-repo",
        type=Path,
        default=Path(".cache/nms-handbook"),
        help="Partial upstream Git checkout used for provenance and asset paths",
    )
    parser.add_argument(
        "--source-commit",
        help="Explicit source SHA when --source-repo is unavailable",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("build/nms-import"),
        help="Generated import directory",
    )
    return parser.parse_args()


if __name__ == "__main__":
    raise SystemExit(transform(parse_args()))
