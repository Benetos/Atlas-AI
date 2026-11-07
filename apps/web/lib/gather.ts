import {
  exactlyMatches,
  entityTitle,
  localSearchQueries,
  matchesIntendedKind,
  shouldBrowseEntities,
  shouldBrowseRecipes,
  shouldSearchRecipes,
  type QueryPlan,
} from "./query-plan";
import {
  listEntities,
  listRecipes,
  searchContent,
  searchEntities,
  searchRecipes,
  recipesProducing,
  recipesUsing,
  type ContentRecord,
  type Entity,
  type Recipe,
} from "./store";

function uniqueEntities(items: Entity[]): Entity[] {
  const seen = new Set<string>();
  const result: Entity[] = [];
  for (const item of items) {
    const key = `${item.entity_type}:${item.game_id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(item);
  }
  return result;
}

function uniqueRecipes(items: Recipe[]): Recipe[] {
  const seen = new Set<string>();
  const result: Recipe[] = [];
  for (const item of items) {
    if (seen.has(item.recipe_id)) continue;
    seen.add(item.recipe_id);
    result.push(item);
  }
  return result;
}

function uniqueContent(items: ContentRecord[]): ContentRecord[] {
  const seen = new Set<string>();
  const result: ContentRecord[] = [];
  for (const item of items) {
    const key = `${item.dataset}:${item.external_id}:${item.source_ordinal}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(item);
  }
  return result;
}

function summaryText(
  plan: QueryPlan,
  entities: Entity[],
  recipes: Recipe[],
  content: ContentRecord[],
): string {
  if (!entities.length && !recipes.length && !content.length) {
    return "not in this snapshot.";
  }
  if (shouldBrowseRecipes(plan)) {
    if (plan.operation) {
      return `Found ${recipes.length} ${plan.operation} recipes in this snapshot.`;
    }
    return `Found ${recipes.length} recipes in this snapshot.`;
  }
  if (shouldBrowseEntities(plan) && plan.entity_type) {
    return `Found ${entities.length} ${plan.entity_type} records in this snapshot.`;
  }
  if (entities.length) {
    const entity = entities[0]!;
    const title = entityTitle(entity);
    const used = recipes.filter((recipe) =>
      recipe.ingredients.some(
        (ingredient) =>
          ingredient.entity_type === entity.entity_type &&
          ingredient.game_id === entity.game_id,
      ),
    ).length;
    const produced = recipes.filter(
      (recipe) =>
        recipe.output_entity_type === entity.entity_type &&
        recipe.output_game_id === entity.game_id,
    ).length;
    if (plan.goal === "uses") {
      return `Found ${used} packed recipes that use ${title}.`;
    }
    if (plan.goal === "recipe") {
      if (plan.operation) {
        return `Found ${recipes.length} ${plan.operation} recipes related to ${title}.`;
      }
      return `Found ${produced} packed recipes that make ${title}.`;
    }
    if (entity.subtitle) return `${title} — ${entity.subtitle}`;
    return `${title} from the pinned Atlas snapshot.`;
  }
  return `Found ${entities.length + recipes.length + content.length} local result(s).`;
}

export async function gatherLocal(plan: QueryPlan) {
  let entities: Entity[] = [];
  if (shouldBrowseEntities(plan) && plan.entity_type) {
    entities = await listEntities(plan.entity_type, 8, 0);
  } else if (!shouldBrowseRecipes(plan)) {
    for (const query of localSearchQueries(plan)) {
      entities = uniqueEntities([
        ...entities,
        ...(await searchEntities(query, plan.entity_type, 8)),
      ]);
      if (entities.length >= 8) break;
    }
  }

  let recipes: Recipe[] = [];
  let content: ContentRecord[] = [];

  if (shouldSearchRecipes(plan) && plan.goal !== "uses") {
    for (const query of localSearchQueries(plan)) {
      recipes = uniqueRecipes([
        ...recipes,
        ...(await searchRecipes(query, plan.operation, 8)),
      ]);
      if (recipes.length >= 8) break;
    }
  }

  if (entities.length) {
    const exact = entities.filter((entity) => exactlyMatches(plan, entity));
    if (exact.length) entities = uniqueEntities([...exact, ...entities]);
    const first = entities[0]!;
    if (plan.goal === "uses") {
      const using = await recipesUsing(first.entity_type, first.game_id, 8);
      recipes.push(
        ...using.filter((recipe) =>
          matchesIntendedKind(plan, recipe.recipe_kind),
        ),
      );
    } else if (plan.goal === "recipe") {
      const producing = await recipesProducing(
        first.entity_type,
        first.game_id,
        8,
      );
      recipes.push(
        ...producing.filter((recipe) =>
          matchesIntendedKind(plan, recipe.recipe_kind),
        ),
      );
      if (plan.operation != null) {
        const using = await recipesUsing(first.entity_type, first.game_id, 8);
        recipes.push(
          ...using.filter((recipe) =>
            matchesIntendedKind(plan, recipe.recipe_kind),
          ),
        );
      }
    }
  }

  recipes = uniqueRecipes(recipes);
  if (!recipes.length && shouldBrowseRecipes(plan)) {
    recipes = await listRecipes(plan.operation, 8, 0);
  }

  if (!shouldBrowseRecipes(plan)) {
    for (const query of localSearchQueries(plan)) {
      content = uniqueContent([
        ...content,
        ...(await searchContent(query, null, 5)),
      ]);
      if (content.length >= 5) break;
    }
  }

  entities = entities.slice(0, 8);
  recipes = recipes.slice(0, 6);
  content = content.slice(0, 5);

  return {
    prompt: plan.original_prompt,
    goal: plan.goal,
    operation: plan.operation,
    query: plan.local_query,
    summary: summaryText(plan, entities, recipes, content),
    entities,
    recipes,
    content,
    miss: !entities.length && !recipes.length && !content.length,
  };
}
