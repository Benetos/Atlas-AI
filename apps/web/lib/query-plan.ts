export type Goal =
  | "lookup"
  | "recipe"
  | "uses"
  | "browse_entities"
  | "browse_recipes";
export type Operation = "crafting" | "refining" | "cooking";

const TOKEN_RE = /[A-Za-z0-9_-]+/g;

const OPERATION_TERMS: Array<[Operation, Set<string>]> = [
  ["crafting", new Set(["craft", "crafted", "crafting"])],
  ["refining", new Set(["refine", "refined", "refiner", "refining"])],
  ["cooking", new Set(["cook", "cooked", "cooking"])],
];

const RECIPE_TERMS = new Set([
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
]);

const BROAD_RECIPE_TERMS = new Set([
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
]);

const ENTITY_TYPE_TERMS: Record<string, Set<string>> = {
  product: new Set(["product", "products"]),
  substance: new Set(["substance", "substances"]),
  technology: new Set(["tech", "technologies", "technology"]),
};

const LOCAL_GLUE = new Set([
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
]);

export type QueryPlan = {
  original_prompt: string;
  operation: Operation | null;
  goal: Goal;
  entity_type: string | null;
  local_query: string | null;
};

export function planQuery(prompt: string): QueryPlan {
  const normalized = collapseWhitespace(prompt);
  const lowerPrompt = normalized.toLowerCase();
  const promptTokens = tokens(normalized);
  const lowerTokens = promptTokens.map((t) => t.toLowerCase());

  const operation = operationFor(lowerTokens);
  const withoutGame = removingGameName(normalized);
  const candidateTokens = tokens(withoutGame);
  const resolvedEntityType = entityTypeFor(
    candidateTokens.map((t) => t.toLowerCase()),
  );
  const searchableTokens = candidateTokens.filter((token) => {
    const lower = token.toLowerCase();
    if (LOCAL_GLUE.has(lower)) return false;
    if (
      resolvedEntityType &&
      ENTITY_TYPE_TERMS[resolvedEntityType]?.has(lower)
    ) {
      return false;
    }
    return true;
  });
  const searchableLower = searchableTokens.map((t) => t.toLowerCase());
  const localQuery =
    searchableTokens.length > 0 ? searchableTokens.join(" ") : null;

  const recipeLanguage = lowerTokens.some((t) => RECIPE_TERMS.has(t));
  const usesLanguage =
    lowerPrompt.includes("used in") ||
    lowerPrompt.includes("use this") ||
    lowerPrompt.includes("uses this") ||
    (lowerTokens[0] === "what" && lowerTokens.at(-1) === "for") ||
    lowerTokens.includes("uses");
  const broadRecipeQuery =
    recipeLanguage &&
    (searchableLower.length === 0 ||
      searchableLower.every((t) => BROAD_RECIPE_TERMS.has(t)));
  const broadEntityQuery =
    resolvedEntityType != null && searchableLower.length === 0;

  let goal: Goal;
  if (broadRecipeQuery) goal = "browse_recipes";
  else if (usesLanguage) goal = "uses";
  else if (operation != null || recipeLanguage) goal = "recipe";
  else if (broadEntityQuery) goal = "browse_entities";
  else goal = "lookup";

  return {
    original_prompt: normalized,
    operation,
    goal,
    entity_type: resolvedEntityType,
    local_query: localQuery,
  };
}

export function recipeKind(plan: QueryPlan): Operation | null {
  return plan.operation;
}

export function shouldSearchRecipes(plan: QueryPlan): boolean {
  return (
    plan.operation != null ||
    plan.goal === "recipe" ||
    plan.goal === "uses" ||
    plan.goal === "browse_recipes"
  );
}

export function shouldBrowseRecipes(plan: QueryPlan): boolean {
  return plan.goal === "browse_recipes";
}

export function shouldBrowseEntities(plan: QueryPlan): boolean {
  return plan.goal === "browse_entities";
}

export function localSearchQueries(plan: QueryPlan): string[] {
  if (!plan.local_query) return [];
  const singular = tokens(plan.local_query)
    .map((token) => singularize(token))
    .join(" ");
  if (singular === plan.local_query.toLowerCase()) return [plan.local_query];
  return [plan.local_query, singular];
}

export function exactlyMatches(
  plan: QueryPlan,
  entity: Record<string, unknown>,
): boolean {
  const titles = [
    normalizeName(entityTitle(entity)),
    normalizeName(String(entity.game_id ?? "")),
  ];
  return localSearchQueries(plan).some((query) =>
    titles.includes(normalizeName(query)),
  );
}

export function matchesIntendedKind(
  plan: QueryPlan,
  recipeKindValue: string,
): boolean {
  return plan.operation == null || plan.operation === recipeKindValue;
}

export function entityTitle(entity: Record<string, unknown>): string {
  for (const key of ["display_name", "name", "game_id"] as const) {
    const value = entity[key];
    if (value) return String(value);
  }
  return "";
}

export function normalizeName(value: string): string {
  return tokens(value)
    .map((t) => t.toLowerCase())
    .join(" ");
}

export function singularize(token: string): string {
  const value = token.toLowerCase();
  if (value.length <= 3) return value;
  if (value.endsWith("ies") && value.length > 4) return `${value.slice(0, -3)}y`;
  if (value.endsWith("ches") || value.endsWith("shes") || value.endsWith("xes")) {
    return value.slice(0, -2);
  }
  if (
    value.endsWith("s") &&
    !value.endsWith("ss") &&
    !value.endsWith("us") &&
    !value.endsWith("is")
  ) {
    return value.slice(0, -1);
  }
  return value;
}

export function tokens(value: string): string[] {
  return value.match(TOKEN_RE) ?? [];
}

function collapseWhitespace(value: string): string {
  return value.split(/\s+/).filter(Boolean).join(" ");
}

function removingGameName(prompt: string): string {
  let result = prompt;
  for (const phrase of ["No Man's Sky", "No Man’s Sky"]) {
    while (true) {
      const index = result.toLowerCase().indexOf(phrase.toLowerCase());
      if (index < 0) break;
      result = result.slice(0, index) + result.slice(index + phrase.length);
    }
  }
  return collapseWhitespace(result);
}

function operationFor(tokenList: string[]): Operation | null {
  let best: [number, Operation] | null = null;
  for (const [operation, terms] of OPERATION_TERMS) {
    for (let index = 0; index < tokenList.length; index += 1) {
      if (terms.has(tokenList[index]!) && (best == null || index < best[0])) {
        best = [index, operation];
        break;
      }
    }
  }
  return best?.[1] ?? null;
}

function entityTypeFor(tokenList: string[]): string | null {
  const meaningful = tokenList.filter((token) => !LOCAL_GLUE.has(token));
  for (const [entityType, terms] of Object.entries(ENTITY_TYPE_TERMS)) {
    const matched = meaningful.find((token) => terms.has(token));
    if (!matched) continue;
    if (
      matched.endsWith("s") ||
      matched === "tech" ||
      (meaningful.length === 1 && meaningful[0] === matched)
    ) {
      return entityType;
    }
  }
  return null;
}
