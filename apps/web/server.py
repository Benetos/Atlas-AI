#!/usr/bin/env python3
"""Local private Atlas web companion server (stdlib only)."""

from __future__ import annotations

import argparse
import json
import mimetypes
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse

from query_plan import QueryPlan, entity_title, plan_query
from store import NMSStore, PackError

ROOT = Path(__file__).resolve().parent
REPO_ROOT = ROOT.parent.parent
DEFAULT_PACK = REPO_ROOT / "build" / "nms-sqlite" / "nms-reference.sqlite"
# Prefer the same public/ tree Next/Cursor publish-app serves (avoid a
# deprecated top-level static/ that Next.js also tries to mount).
PUBLIC_DIR = ROOT / "public"
STATIC_DIR = PUBLIC_DIR / "static"
SPA_HTML = PUBLIC_DIR / "spa.html"

ENTITY_TYPES = frozenset({"product", "substance", "technology"})
RECIPE_KINDS = frozenset({"crafting", "refining", "cooking"})


class AppState:
    def __init__(self, store: NMSStore):
        self.store = store
        self.lock = threading.RLock()


STATE: AppState | None = None


def unique_by_id(items: list[dict[str, Any]], key: str) -> list[dict[str, Any]]:
    seen: set[str] = set()
    result: list[dict[str, Any]] = []
    for item in items:
        value = item[key]
        if value in seen:
            continue
        seen.add(value)
        result.append(item)
    return result


def gather_local(store: NMSStore, plan: QueryPlan) -> dict[str, Any]:
    entities: list[dict[str, Any]] = []
    if plan.should_browse_entities and plan.entity_type:
        entities = store.entities(plan.entity_type, limit=8, offset=0)
    elif not plan.should_browse_recipes:
        for query in plan.local_search_queries:
            entities.extend(store.search_entities(query, plan.entity_type, limit=8))
            entities = _unique_entities(entities)
            if len(entities) >= 8:
                break

    recipes: list[dict[str, Any]] = []
    content: list[dict[str, Any]] = []

    if plan.should_search_recipes and plan.goal != "uses":
        for query in plan.local_search_queries:
            recipes.extend(store.search_recipes(query, plan.recipe_kind, limit=8))
            recipes = _unique_recipes(recipes)
            if len(recipes) >= 8:
                break

    if entities:
        exact = [entity for entity in entities if plan.exactly_matches(entity)]
        if exact:
            entities = _unique_entities(exact + entities)
        first = entities[0]
        if plan.goal == "uses":
            using = store.recipes_using(first["entity_type"], first["game_id"], limit=8)
            recipes.extend(
                recipe
                for recipe in using
                if plan.matches_intended_kind(recipe["recipe_kind"])
            )
        elif plan.goal == "recipe":
            producing = store.recipes_producing(
                first["entity_type"], first["game_id"], limit=8
            )
            recipes.extend(
                recipe
                for recipe in producing
                if plan.matches_intended_kind(recipe["recipe_kind"])
            )
            if plan.operation is not None:
                using = store.recipes_using(
                    first["entity_type"], first["game_id"], limit=8
                )
                recipes.extend(
                    recipe
                    for recipe in using
                    if plan.matches_intended_kind(recipe["recipe_kind"])
                )

    recipes = _unique_recipes(recipes)
    if not recipes and plan.should_browse_recipes:
        recipes = store.recipes(plan.recipe_kind, limit=8, offset=0)

    if not plan.should_browse_recipes:
        for query in plan.local_search_queries:
            content.extend(store.search_content(query, None, limit=5))
            content = _unique_content(content)
            if len(content) >= 5:
                break

    entities = entities[:8]
    recipes = recipes[:6]
    content = content[:5]

    text = _summary_text(plan, entities, recipes, content)
    return {
        "prompt": plan.original_prompt,
        "goal": plan.goal,
        "operation": plan.operation,
        "query": plan.local_query,
        "summary": text,
        "entities": entities,
        "recipes": recipes,
        "content": content,
        "miss": not entities and not recipes and not content,
    }


def _unique_entities(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[str] = set()
    result: list[dict[str, Any]] = []
    for item in items:
        key = f"{item['entity_type']}:{item['game_id']}"
        if key in seen:
            continue
        seen.add(key)
        result.append(item)
    return result


def _unique_recipes(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return unique_by_id(items, "recipe_id")


def _unique_content(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[str] = set()
    result: list[dict[str, Any]] = []
    for item in items:
        key = f"{item['dataset']}:{item['external_id']}:{item['source_ordinal']}"
        if key in seen:
            continue
        seen.add(key)
        result.append(item)
    return result


def _summary_text(
    plan: QueryPlan,
    entities: list[dict[str, Any]],
    recipes: list[dict[str, Any]],
    content: list[dict[str, Any]],
) -> str:
    if not entities and not recipes and not content:
        return "not in this snapshot."
    if plan.should_browse_recipes:
        if plan.recipe_kind:
            return (
                f"Found {len(recipes)} {plan.recipe_kind} recipes in this snapshot."
            )
        return f"Found {len(recipes)} recipes in this snapshot."
    if plan.should_browse_entities and plan.entity_type:
        return f"Found {len(entities)} {plan.entity_type} records in this snapshot."
    if entities:
        entity = entities[0]
        title = entity_title(entity)
        used = sum(
            1
            for recipe in recipes
            if any(
                ingredient["entity_type"] == entity["entity_type"]
                and ingredient["game_id"] == entity["game_id"]
                for ingredient in recipe.get("ingredients", [])
            )
        )
        produced = sum(
            1
            for recipe in recipes
            if recipe["output_entity_type"] == entity["entity_type"]
            and recipe["output_game_id"] == entity["game_id"]
        )
        if plan.goal == "uses":
            return f"Found {used} packed recipes that use {title}."
        if plan.goal == "recipe":
            if plan.operation:
                return (
                    f"Found {len(recipes)} {plan.operation} recipes related to {title}."
                )
            return f"Found {produced} packed recipes that make {title}."
        subtitle = entity.get("subtitle")
        if subtitle:
            return f"{title} — {subtitle}"
        return f"{title} from the pinned Atlas snapshot."
    return f"Found {len(entities) + len(recipes) + len(content)} local result(s)."


class CompanionHandler(BaseHTTPRequestHandler):
    server_version = "AtlasWebCompanion/1.0"

    def log_message(self, format: str, *args: Any) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))

    def do_GET(self) -> None:  # noqa: N802
        assert STATE is not None
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        query = parse_qs(parsed.query)

        try:
            if path == "/api/health":
                self._json({"ok": True})
                return
            if path == "/api/manifest":
                with STATE.lock:
                    self._json(STATE.store.manifest)
                return
            if path == "/api/ask":
                prompt = (query.get("q") or [""])[0].strip()
                if not prompt:
                    self._json({"error": "Missing q"}, status=HTTPStatus.BAD_REQUEST)
                    return
                plan = plan_query(prompt)
                with STATE.lock:
                    payload = gather_local(STATE.store, plan)
                self._json(payload)
                return
            if path == "/api/entities":
                entity_type = (query.get("type") or [""])[0].strip()
                if entity_type not in ENTITY_TYPES:
                    self._json(
                        {"error": "type must be product, substance, or technology"},
                        status=HTTPStatus.BAD_REQUEST,
                    )
                    return
                limit = _int_param(query, "limit", 100, 1, 200)
                offset = _int_param(query, "offset", 0, 0, 100_000)
                with STATE.lock:
                    rows = STATE.store.entities(entity_type, limit=limit, offset=offset)
                self._json({"type": entity_type, "items": rows})
                return
            if path.startswith("/api/entities/"):
                parts = path.strip("/").split("/")
                # /api/entities/{type}/{id}[/producing|/using]
                if len(parts) < 4:
                    self._not_found()
                    return
                entity_type, game_id = parts[2], parts[3]
                if entity_type not in ENTITY_TYPES:
                    self._json({"error": "Unknown entity type"}, status=HTTPStatus.BAD_REQUEST)
                    return
                with STATE.lock:
                    if len(parts) == 4:
                        entity = STATE.store.entity(entity_type, game_id)
                        if entity is None:
                            self._json(
                                {"error": "not in this snapshot."},
                                status=HTTPStatus.NOT_FOUND,
                            )
                            return
                        producing = STATE.store.recipes_producing(entity_type, game_id)
                        using = STATE.store.recipes_using(entity_type, game_id)
                        self._json(
                            {
                                "entity": entity,
                                "producing": producing,
                                "using": using,
                            }
                        )
                        return
                    if len(parts) == 5 and parts[4] == "producing":
                        self._json(
                            {
                                "items": STATE.store.recipes_producing(
                                    entity_type, game_id
                                )
                            }
                        )
                        return
                    if len(parts) == 5 and parts[4] == "using":
                        self._json(
                            {"items": STATE.store.recipes_using(entity_type, game_id)}
                        )
                        return
                self._not_found()
                return
            if path == "/api/recipes":
                kind = (query.get("kind") or [""])[0].strip() or None
                if kind is not None and kind not in RECIPE_KINDS:
                    self._json(
                        {"error": "kind must be crafting, refining, or cooking"},
                        status=HTTPStatus.BAD_REQUEST,
                    )
                    return
                limit = _int_param(query, "limit", 100, 1, 200)
                offset = _int_param(query, "offset", 0, 0, 100_000)
                with STATE.lock:
                    rows = STATE.store.recipes(kind, limit=limit, offset=offset)
                self._json({"kind": kind, "items": rows})
                return
            if path.startswith("/api/recipes/"):
                recipe_id = path[len("/api/recipes/") :]
                if not recipe_id or "/" in recipe_id:
                    self._not_found()
                    return
                with STATE.lock:
                    recipe = STATE.store.recipe(recipe_id)
                if recipe is None:
                    self._json(
                        {"error": "not in this snapshot."},
                        status=HTTPStatus.NOT_FOUND,
                    )
                    return
                self._json({"recipe": recipe})
                return
            if path == "/" or path == "/index.html" or path == "/spa.html":
                self._file(SPA_HTML if SPA_HTML.is_file() else STATIC_DIR / "index.html")
                return
            if path.startswith("/static/"):
                relative = path[len("/static/") :]
                target = (STATIC_DIR / relative).resolve()
                if not str(target).startswith(str(STATIC_DIR.resolve())):
                    self._not_found()
                    return
                self._file(target)
                return
            # SPA deep links fall through to spa.html
            if path.startswith(("/ask", "/library", "/saved", "/info", "/item/", "/recipe/")):
                self._file(SPA_HTML if SPA_HTML.is_file() else STATIC_DIR / "index.html")
                return
            self._not_found()
        except PackError as exc:
            self._json({"error": str(exc)}, status=HTTPStatus.SERVICE_UNAVAILABLE)
        except ValueError as exc:
            self._json({"error": str(exc)}, status=HTTPStatus.BAD_REQUEST)
        except Exception as exc:  # noqa: BLE001
            self._json(
                {"error": f"Server error: {exc}"},
                status=HTTPStatus.INTERNAL_SERVER_ERROR,
            )

    def _json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _file(self, path: Path) -> None:
        if not path.is_file():
            self._not_found()
            return
        data = path.read_bytes()
        content_type, _ = mimetypes.guess_type(str(path))
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type or "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _not_found(self) -> None:
        self._json({"error": "not found"}, status=HTTPStatus.NOT_FOUND)


def _int_param(
    query: dict[str, list[str]], name: str, default: int, minimum: int, maximum: int
) -> int:
    raw = (query.get(name) or [str(default)])[0]
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc
    return max(minimum, min(maximum, value))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Atlas private web companion")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument(
        "--pack",
        type=Path,
        default=DEFAULT_PACK,
        help="Path to nms-reference.sqlite (default: build/nms-sqlite/nms-reference.sqlite)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    global STATE
    args = build_parser().parse_args(argv)
    try:
        store = NMSStore(args.pack)
    except PackError as exc:
        print(exc, file=sys.stderr)
        return 1
    STATE = AppState(store)
    server = ThreadingHTTPServer((args.host, args.port), CompanionHandler)
    manifest = store.manifest
    counts = manifest["counts"]
    print("Atlas private web companion")
    print(f"  pack: {args.pack}")
    print(f"  source commit: {manifest['source_commit_sha']}")
    print(
        f"  counts: entities={counts.get('entities')} recipes={counts.get('recipes')}"
    )
    print(f"  listen: http://{args.host}:{args.port}/")
    print("  private local use only — do not publish")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down")
    finally:
        server.server_close()
        store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
