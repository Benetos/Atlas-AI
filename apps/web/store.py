"""Read-only SQLite access for the Atlas web companion pack."""

from __future__ import annotations

import json
import re
import sqlite3
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

SOURCE_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
PUBLIC_SOURCE_REPO = "https://github.com/ApexFatality93/NMS-Handbook"
TOKEN_RE = re.compile(r"[A-Za-z0-9_]+")
RECIPE_SEARCH_GLUE = frozenset(
    {
        "cook",
        "cooked",
        "cooking",
        "craft",
        "crafted",
        "crafting",
        "make",
        "making",
        "recipe",
        "recipes",
        "refine",
        "refined",
        "refiner",
        "refining",
    }
)


class PackError(RuntimeError):
    pass


class NMSStore:
    def __init__(self, sqlite_path: Path):
        if not sqlite_path.is_file():
            raise PackError(
                f"Missing SQLite pack at {sqlite_path}. "
                "Run ./scripts/prepare_ios_debug_pack.sh from the repo root."
            )
        self.sqlite_path = sqlite_path
        self._connection = sqlite3.connect(
            f"file:{sqlite_path.resolve()}?mode=ro",
            uri=True,
            check_same_thread=False,
        )
        self._connection.row_factory = sqlite3.Row
        self._connection.execute("pragma query_only = on")
        self._manifest = self._load_manifest()

    def close(self) -> None:
        self._connection.close()

    @property
    def manifest(self) -> dict[str, Any]:
        return dict(self._manifest)

    def entity(self, entity_type: str, game_id: str) -> dict[str, Any] | None:
        row = self._connection.execute(
            """
            select entity_type, game_id, name, display_name, subtitle, description,
                   category, subcategory, rarity, legality, base_value,
                   color_r, color_g, color_b, source_dataset, source_commit_sha
              from nms_entities
             where entity_type = ? and game_id = ?
            """,
            (entity_type, game_id),
        ).fetchone()
        return map_entity(row) if row else None

    def search_entities(
        self, query: str, entity_type: str | None = None, limit: int = 20
    ) -> list[dict[str, Any]]:
        token_list = search_tokens(query)
        match = fts_query(query)
        if not match or not token_list or limit <= 0:
            return []

        metadata_sql = """
            select e.entity_type, e.game_id, e.name, e.display_name, e.subtitle, e.description,
                   e.category, e.subcategory, e.rarity, e.legality, e.base_value,
                   e.color_r, e.color_g, e.color_b, e.source_dataset, e.source_commit_sha
              from nms_entities e
             where 1 = 1
        """
        params: list[Any] = []
        if entity_type:
            metadata_sql += " and e.entity_type = ?"
            params.append(entity_type)
        columns = [
            "e.entity_type",
            "e.game_id",
            "e.name",
            "e.display_name",
            "e.subtitle",
            "e.description",
            "e.category",
            "e.subcategory",
            "e.rarity",
            "e.legality",
            "e.source_dataset",
        ]
        metadata_sql, params = append_token_predicates(token_list, columns, metadata_sql, params)
        metadata_sql += """
             order by case
                        when lower(coalesce(e.display_name, e.name, e.game_id)) = ? then 0
                        when lower(e.game_id) = ? then 1
                        when lower(e.entity_type) = ? then 2
                        else 3
                      end,
                      lower(coalesce(e.display_name, e.name, e.game_id))
             limit ?
        """
        normalized = query.strip().lower()
        params.extend([normalized, normalized, normalized, limit])
        metadata = [map_entity(row) for row in self._connection.execute(metadata_sql, params)]

        fts_sql = """
            select e.entity_type, e.game_id, e.name, e.display_name, e.subtitle, e.description,
                   e.category, e.subcategory, e.rarity, e.legality, e.base_value,
                   e.color_r, e.color_g, e.color_b, e.source_dataset, e.source_commit_sha
              from nms_entities_fts
              join nms_entities e
                on e.entity_type = nms_entities_fts.entity_type
               and e.game_id = nms_entities_fts.game_id
             where nms_entities_fts match ?
        """
        fts_params: list[Any] = [match]
        if entity_type:
            fts_sql += " and e.entity_type = ?"
            fts_params.append(entity_type)
        fts_sql += " order by bm25(nms_entities_fts, 10.0, 10.0, 3.0, 1.0) limit ?"
        fts_params.append(limit)
        indexed = [map_entity(row) for row in self._connection.execute(fts_sql, fts_params)]
        return unique_prefix(metadata + indexed, limit, entity_key)

    def entities(
        self, entity_type: str, limit: int = 100, offset: int = 0
    ) -> list[dict[str, Any]]:
        rows = self._connection.execute(
            """
            select entity_type, game_id, name, display_name, subtitle, description,
                   category, subcategory, rarity, legality, base_value,
                   color_r, color_g, color_b, source_dataset, source_commit_sha
              from nms_entities
             where entity_type = ?
             order by lower(coalesce(display_name, name, game_id))
             limit ? offset ?
            """,
            (entity_type, limit, offset),
        )
        return [map_entity(row) for row in rows]

    def recipes(
        self, kind: str | None = None, limit: int = 100, offset: int = 0
    ) -> list[dict[str, Any]]:
        sql = """
            select r.recipe_id, r.recipe_kind, r.output_entity_type, r.output_game_id,
                   r.output_amount, r.time_seconds, r.recipe_type, r.recipe_name,
                   r.source_ordinal, r.source_commit_sha,
                   coalesce(e.display_name, e.name, r.output_game_id) as output_title
              from nms_recipes r
              left join nms_entities e
                on e.entity_type = r.output_entity_type
               and e.game_id = r.output_game_id
        """
        params: list[Any] = []
        if kind:
            sql += " where r.recipe_kind = ?"
            params.append(kind)
        sql += " order by lower(coalesce(r.recipe_name, e.display_name, r.recipe_id)) limit ? offset ?"
        params.extend([limit, offset])
        return [self._hydrate_recipe(map_recipe(row)) for row in self._connection.execute(sql, params)]

    def search_recipes(
        self, query: str, kind: str | None = None, limit: int = 20
    ) -> list[dict[str, Any]]:
        raw_tokens = search_tokens(query)
        resolved_kind = kind or recipe_kind_from_tokens(raw_tokens)
        token_list = [token for token in raw_tokens if token not in RECIPE_SEARCH_GLUE]
        if (not token_list and resolved_kind is None) or limit <= 0:
            return []

        sql = """
            select r.recipe_id, r.recipe_kind, r.output_entity_type, r.output_game_id,
                   r.output_amount, r.time_seconds, r.recipe_type, r.recipe_name,
                   r.source_ordinal, r.source_commit_sha,
                   coalesce(e.display_name, e.name, r.output_game_id) as output_title
              from nms_recipes r
              left join nms_entities e
                on e.entity_type = r.output_entity_type
               and e.game_id = r.output_game_id
             where 1 = 1
        """
        params: list[Any] = []
        if resolved_kind:
            sql += " and r.recipe_kind = ?"
            params.append(resolved_kind)
        for token in token_list:
            sql += """
                 and lower(
                       coalesce(r.recipe_name, '') || ' ' ||
                       coalesce(e.display_name, e.name, '') || ' ' ||
                       r.output_game_id
                     ) like ? escape '\\'
            """
            params.append(f"%{escape_like(token)}%")
        sql += " order by lower(coalesce(r.recipe_name, e.display_name, r.recipe_id)) limit ?"
        params.append(limit)
        return [self._hydrate_recipe(map_recipe(row)) for row in self._connection.execute(sql, params)]

    def recipe(self, recipe_id: str) -> dict[str, Any] | None:
        row = self._connection.execute(
            """
            select r.recipe_id, r.recipe_kind, r.output_entity_type, r.output_game_id,
                   r.output_amount, r.time_seconds, r.recipe_type, r.recipe_name,
                   r.source_ordinal, r.source_commit_sha,
                   coalesce(e.display_name, e.name, r.output_game_id) as output_title
              from nms_recipes r
              left join nms_entities e
                on e.entity_type = r.output_entity_type
               and e.game_id = r.output_game_id
             where r.recipe_id = ?
            """,
            (recipe_id,),
        ).fetchone()
        if row is None:
            return None
        return self._hydrate_recipe(map_recipe(row))

    def recipes_producing(
        self, entity_type: str, game_id: str, limit: int = 10_000
    ) -> list[dict[str, Any]]:
        if limit <= 0:
            return []
        rows = self._connection.execute(
            """
            select r.recipe_id, r.recipe_kind, r.output_entity_type, r.output_game_id,
                   r.output_amount, r.time_seconds, r.recipe_type, r.recipe_name,
                   r.source_ordinal, r.source_commit_sha,
                   coalesce(e.display_name, e.name, r.output_game_id) as output_title
              from nms_recipes r
              left join nms_entities e
                on e.entity_type = r.output_entity_type
               and e.game_id = r.output_game_id
             where r.output_entity_type = ? and r.output_game_id = ?
             order by r.recipe_kind, r.recipe_id
             limit ?
            """,
            (entity_type, game_id, limit),
        )
        return [self._hydrate_recipe(map_recipe(row)) for row in rows]

    def recipes_using(
        self, entity_type: str, game_id: str, limit: int = 10_000
    ) -> list[dict[str, Any]]:
        if limit <= 0:
            return []
        rows = self._connection.execute(
            """
            select r.recipe_id, r.recipe_kind, r.output_entity_type, r.output_game_id,
                   r.output_amount, r.time_seconds, r.recipe_type, r.recipe_name,
                   r.source_ordinal, r.source_commit_sha,
                   coalesce(e.display_name, e.name, r.output_game_id) as output_title
              from nms_recipe_ingredients i
              join nms_recipes r on r.recipe_id = i.recipe_id
              left join nms_entities e
                on e.entity_type = r.output_entity_type
               and e.game_id = r.output_game_id
             where i.ingredient_entity_type = ? and i.ingredient_game_id = ?
             order by r.recipe_kind, r.recipe_id
             limit ?
            """,
            (entity_type, game_id, limit),
        )
        return [self._hydrate_recipe(map_recipe(row)) for row in rows]

    def search_content(
        self, query: str, dataset: str | None = None, limit: int = 5
    ) -> list[dict[str, Any]]:
        token_list = search_tokens(query)
        match = fts_query(query)
        if not match or not token_list or limit <= 0:
            return []

        metadata_sql = """
            select dataset, external_id, source_ordinal, display_name, payload, source_commit_sha
              from nms_content_records
             where 1 = 1
        """
        params: list[Any] = []
        if dataset:
            metadata_sql += " and dataset = ?"
            params.append(dataset)
        metadata_sql, params = append_token_predicates(
            token_list,
            ["dataset", "external_id", "display_name", "payload"],
            metadata_sql,
            params,
        )
        metadata_sql += " order by lower(coalesce(display_name, external_id)) limit ?"
        params.append(limit)
        metadata = [map_content(row) for row in self._connection.execute(metadata_sql, params)]

        fts_sql = """
            select c.dataset, c.external_id, c.source_ordinal, c.display_name,
                   c.payload, c.source_commit_sha
              from nms_content_fts
              join nms_content_records c
                on c.dataset = nms_content_fts.dataset
               and c.external_id = nms_content_fts.external_id
               and c.source_ordinal = nms_content_fts.source_ordinal
             where nms_content_fts match ?
        """
        fts_params: list[Any] = [match]
        if dataset:
            fts_sql += " and c.dataset = ?"
            fts_params.append(dataset)
        fts_sql += " order by bm25(nms_content_fts, 5.0, 1.0) limit ?"
        fts_params.append(limit)
        indexed = [map_content(row) for row in self._connection.execute(fts_sql, fts_params)]
        return unique_prefix(metadata + indexed, limit, content_key)

    def _hydrate_recipe(self, recipe: dict[str, Any]) -> dict[str, Any]:
        recipe["ingredients"] = self._ingredients(recipe["recipe_id"])
        return recipe

    def _ingredients(self, recipe_id: str) -> list[dict[str, Any]]:
        rows = self._connection.execute(
            """
            select i.recipe_id, i.position, i.ingredient_entity_type, i.ingredient_game_id,
                   i.amount, coalesce(e.display_name, e.name, i.ingredient_game_id) as title
              from nms_recipe_ingredients i
              left join nms_entities e
                on e.entity_type = i.ingredient_entity_type
               and e.game_id = i.ingredient_game_id
             where i.recipe_id = ?
             order by i.position
            """,
            (recipe_id,),
        )
        return [
            {
                "recipe_id": row["recipe_id"],
                "position": int(row["position"]),
                "entity_type": row["ingredient_entity_type"],
                "game_id": row["ingredient_game_id"],
                "amount": row["amount"],
                "title": row["title"],
            }
            for row in rows
        ]

    def _load_manifest(self) -> dict[str, Any]:
        rows = self._connection.execute(
            """
            select pack_schema_version, contract_version, source_repository,
                   source_commit_sha, source_committed_at, generated_at, counts_json,
                   input_manifest_sha256
              from pack_manifest
            """
        ).fetchall()
        if len(rows) != 1:
            raise PackError(
                f"Atlas pack must contain exactly one manifest row; found {len(rows)}."
            )
        row = rows[0]
        if int(row["pack_schema_version"]) != 1:
            raise PackError(
                f"Unsupported pack schema version {row['pack_schema_version']}."
            )
        if int(row["contract_version"]) != 1:
            raise PackError(
                f"Unsupported contract version {row['contract_version']}."
            )
        commit = row["source_commit_sha"]
        if not isinstance(commit, str) or not SOURCE_COMMIT_RE.fullmatch(commit):
            raise PackError("Invalid source commit SHA in pack_manifest.")
        counts = json.loads(row["counts_json"])
        if not isinstance(counts, dict):
            raise PackError("pack_manifest.counts_json must be an object.")
        return {
            "pack_schema_version": int(row["pack_schema_version"]),
            "contract_version": int(row["contract_version"]),
            "source_repository": public_repository_url(row["source_repository"]),
            "source_commit_sha": commit,
            "source_committed_at": row["source_committed_at"],
            "generated_at": row["generated_at"],
            "counts": {key: int(value) for key, value in counts.items()},
            "input_manifest_sha256": row["input_manifest_sha256"],
            "attribution": "Structured data transformed from ApexFatality93/NMS-Handbook (GPL-3.0).",
            "private_notice": (
                "Private Atlas companion for local use. Licensing posture remains internal."
            ),
        }


def public_repository_url(raw: str | None) -> str:
    if not raw:
        return PUBLIC_SOURCE_REPO
    try:
        parsed = urlparse(raw)
    except ValueError:
        return PUBLIC_SOURCE_REPO
    host = (parsed.hostname or "").lower()
    path = (parsed.path or "").rstrip("/")
    if host in {"github.com", "www.github.com"} and path:
        return f"https://github.com{path}"
    if "ApexFatality93/NMS-Handbook" in raw:
        return PUBLIC_SOURCE_REPO
    return PUBLIC_SOURCE_REPO


def map_entity(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "entity_type": row["entity_type"],
        "game_id": row["game_id"],
        "name": row["name"],
        "display_name": row["display_name"],
        "subtitle": row["subtitle"],
        "description": row["description"],
        "category": row["category"],
        "subcategory": row["subcategory"],
        "rarity": row["rarity"],
        "legality": row["legality"],
        "base_value": row["base_value"],
        "color_r": row["color_r"],
        "color_g": row["color_g"],
        "color_b": row["color_b"],
        "source_dataset": row["source_dataset"],
        "source_commit_sha": row["source_commit_sha"],
        "title": row["display_name"] or row["name"] or row["game_id"],
    }


def map_recipe(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "recipe_id": row["recipe_id"],
        "recipe_kind": row["recipe_kind"],
        "output_entity_type": row["output_entity_type"],
        "output_game_id": row["output_game_id"],
        "output_amount": row["output_amount"],
        "time_seconds": row["time_seconds"],
        "recipe_type": row["recipe_type"],
        "recipe_name": row["recipe_name"],
        "source_ordinal": int(row["source_ordinal"]),
        "source_commit_sha": row["source_commit_sha"],
        "output_title": row["output_title"],
        "ingredients": [],
    }


def map_content(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "dataset": row["dataset"],
        "external_id": row["external_id"],
        "source_ordinal": int(row["source_ordinal"]),
        "display_name": row["display_name"],
        "payload": row["payload"],
        "source_commit_sha": row["source_commit_sha"],
        "title": row["display_name"] or row["external_id"],
    }


def search_tokens(raw: str) -> list[str]:
    return [token.lower() for token in TOKEN_RE.findall(raw.lower())]


def fts_query(raw: str) -> str | None:
    token_list = search_tokens(raw)
    if not token_list:
        return None
    return " AND ".join(f'"{token}"*' for token in token_list)


def escape_like(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def append_token_predicates(
    token_list: list[str],
    columns: list[str],
    sql: str,
    params: list[Any],
) -> tuple[str, list[Any]]:
    for token in token_list:
        predicates = " or ".join(
            f"lower(coalesce({column}, '')) like ? escape '\\'" for column in columns
        )
        sql += f" and ({predicates})"
        params.extend([f"%{escape_like(token)}%"] * len(columns))
    return sql, params


def unique_prefix(
    values: list[dict[str, Any]], limit: int, key_fn
) -> list[dict[str, Any]]:
    seen: set[str] = set()
    result: list[dict[str, Any]] = []
    for value in values:
        key = key_fn(value)
        if key in seen:
            continue
        seen.add(key)
        result.append(value)
        if len(result) >= limit:
            break
    return result


def entity_key(entity: dict[str, Any]) -> str:
    return f"{entity['entity_type']}:{entity['game_id']}"


def content_key(record: dict[str, Any]) -> str:
    return f"{record['dataset']}:{record['external_id']}:{record['source_ordinal']}"


def recipe_kind_from_tokens(token_list: list[str]) -> str | None:
    if any(token in {"cook", "cooked", "cooking"} for token in token_list):
        return "cooking"
    if any(token in {"refine", "refined", "refiner", "refining"} for token in token_list):
        return "refining"
    if any(token in {"craft", "crafted", "crafting"} for token in token_list):
        return "crafting"
    return None
