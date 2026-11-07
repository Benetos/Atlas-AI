"""Deterministic prompt planner mirroring AtlasQueryPlan (local-only)."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Literal

Goal = Literal["lookup", "recipe", "uses", "browse_entities", "browse_recipes"]
Operation = Literal["crafting", "refining", "cooking"]

_TOKEN_RE = re.compile(r"[A-Za-z0-9_-]+")

_OPERATION_TERMS: list[tuple[Operation, frozenset[str]]] = [
    ("crafting", frozenset({"craft", "crafted", "crafting"})),
    ("refining", frozenset({"refine", "refined", "refiner", "refining"})),
    ("cooking", frozenset({"cook", "cooked", "cooking"})),
]

_RECIPE_TERMS = frozenset(
    {
        "craft",
        "crafted",
        "crafting",
        "ingredient",
        "ingredients",
        "make",
        "made",
        "making",
        "recipe",
        "recipes",
        "refine",
        "refined",
        "refiner",
        "refining",
        "cook",
        "cooked",
        "cooking",
    }
)

_BROAD_RECIPE_TERMS = frozenset(
    {
        "all",
        "any",
        "everything",
        "food",
        "foods",
        "item",
        "items",
        "something",
        "stuff",
        "thing",
        "things",
    }
)

_ENTITY_TYPE_TERMS: dict[str, frozenset[str]] = {
    "product": frozenset({"product", "products"}),
    "substance": frozenset({"substance", "substances"}),
    "technology": frozenset({"tech", "technologies", "technology"}),
}

_LOCAL_GLUE = frozenset(
    {
        "a",
        "about",
        "all",
        "an",
        "and",
        "any",
        "are",
        "atlas",
        "can",
        "could",
        "build",
        "built",
        "create",
        "created",
        "craft",
        "crafted",
        "crafting",
        "do",
        "does",
        "everything",
        "find",
        "for",
        "from",
        "get",
        "give",
        "how",
        "i",
        "in",
        "ingredient",
        "ingredients",
        "internet",
        "into",
        "is",
        "locate",
        "latest",
        "live",
        "look",
        "lookup",
        "made",
        "make",
        "making",
        "me",
        "my",
        "need",
        "newest",
        "now",
        "obtain",
        "of",
        "on",
        "online",
        "please",
        "produce",
        "produced",
        "recent",
        "plan",
        "want",
        "recipe",
        "recipes",
        "refine",
        "refined",
        "refiner",
        "refining",
        "search",
        "show",
        "tell",
        "the",
        "this",
        "to",
        "today",
        "up",
        "use",
        "used",
        "uses",
        "using",
        "web",
        "what",
        "where",
        "which",
        "wiki",
        "with",
        "would",
        "you",
        "cook",
        "cooked",
        "cooking",
        "current",
    }
)


@dataclass(frozen=True)
class QueryPlan:
    original_prompt: str
    operation: Operation | None
    goal: Goal
    entity_type: str | None
    local_query: str | None

    @property
    def recipe_kind(self) -> str | None:
        return self.operation

    @property
    def should_search_recipes(self) -> bool:
        return (
            self.operation is not None
            or self.goal in {"recipe", "uses", "browse_recipes"}
        )

    @property
    def should_browse_recipes(self) -> bool:
        return self.goal == "browse_recipes"

    @property
    def should_browse_entities(self) -> bool:
        return self.goal == "browse_entities"

    @property
    def local_search_queries(self) -> list[str]:
        if not self.local_query:
            return []
        singular = " ".join(singularize(token) for token in tokens(self.local_query))
        if singular == self.local_query.lower():
            return [self.local_query]
        return [self.local_query, singular]

    def exactly_matches(self, entity: dict) -> bool:
        titles = [
            normalize_name(entity_title(entity)),
            normalize_name(entity.get("game_id") or ""),
        ]
        return any(normalize_name(query) in titles for query in self.local_search_queries)

    def matches_intended_kind(self, recipe_kind: str) -> bool:
        return self.operation is None or self.operation == recipe_kind


def plan_query(prompt: str) -> QueryPlan:
    normalized = collapse_whitespace(prompt)
    lower_prompt = normalized.lower()
    prompt_tokens = tokens(normalized)
    lower_tokens = [token.lower() for token in prompt_tokens]

    operation = _operation_for(lower_tokens)
    without_game = removing_game_name(normalized)
    candidate_tokens = tokens(without_game)
    resolved_entity_type = _entity_type_for([token.lower() for token in candidate_tokens])
    searchable_tokens = [
        token
        for token in candidate_tokens
        if token.lower() not in _LOCAL_GLUE
        and not (
            resolved_entity_type
            and token.lower() in _ENTITY_TYPE_TERMS.get(resolved_entity_type, frozenset())
        )
    ]
    searchable_lower = [token.lower() for token in searchable_tokens]
    local_query = " ".join(searchable_tokens) if searchable_tokens else None

    recipe_language = bool(set(lower_tokens) & _RECIPE_TERMS)
    uses_language = (
        "used in" in lower_prompt
        or "use this" in lower_prompt
        or "uses this" in lower_prompt
        or (lower_tokens[:1] == ["what"] and lower_tokens[-1:] == ["for"])
        or "uses" in lower_tokens
    )
    broad_recipe_query = recipe_language and (
        not searchable_lower or set(searchable_lower).issubset(_BROAD_RECIPE_TERMS)
    )
    broad_entity_query = resolved_entity_type is not None and not searchable_lower

    if broad_recipe_query:
        goal: Goal = "browse_recipes"
    elif uses_language:
        goal = "uses"
    elif operation is not None or recipe_language:
        goal = "recipe"
    elif broad_entity_query:
        goal = "browse_entities"
    else:
        goal = "lookup"

    return QueryPlan(
        original_prompt=normalized,
        operation=operation,
        goal=goal,
        entity_type=resolved_entity_type,
        local_query=local_query,
    )


def entity_title(entity: dict) -> str:
    for key in ("display_name", "name", "game_id"):
        value = entity.get(key)
        if value:
            return str(value)
    return ""


def normalize_name(value: str) -> str:
    return " ".join(token.lower() for token in tokens(value))


def singularize(token: str) -> str:
    value = token.lower()
    if len(value) <= 3:
        return value
    if value.endswith("ies") and len(value) > 4:
        return value[:-3] + "y"
    if value.endswith(("ches", "shes", "xes")):
        return value[:-2]
    if (
        value.endswith("s")
        and not value.endswith("ss")
        and not value.endswith("us")
        and not value.endswith("is")
    ):
        return value[:-1]
    return value


def tokens(value: str) -> list[str]:
    return _TOKEN_RE.findall(value)


def collapse_whitespace(value: str) -> str:
    return " ".join(value.split())


def removing_game_name(prompt: str) -> str:
    result = prompt
    for phrase in ("No Man's Sky", "No Man’s Sky"):
        while True:
            index = result.lower().find(phrase.lower())
            if index < 0:
                break
            result = result[:index] + result[index + len(phrase) :]
    return collapse_whitespace(result)


def _operation_for(token_list: list[str]) -> Operation | None:
    best: tuple[int, Operation] | None = None
    for operation, terms in _OPERATION_TERMS:
        for index, token in enumerate(token_list):
            if token in terms and (best is None or index < best[0]):
                best = (index, operation)
                break
    return None if best is None else best[1]


def _entity_type_for(token_list: list[str]) -> str | None:
    meaningful = [token for token in token_list if token not in _LOCAL_GLUE]
    for entity_type, terms in _ENTITY_TYPE_TERMS.items():
        matched = next((token for token in meaningful if token in terms), None)
        if matched is None:
            continue
        if matched.endswith("s") or matched == "tech" or meaningful == [matched]:
            return entity_type
    return None
