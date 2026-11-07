export function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "private, no-store",
    },
  });
}

export function intParam(
  value: string | null,
  fallback: number,
  min: number,
  max: number,
): number {
  if (value == null || value === "") return fallback;
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed)) {
    throw new Error("must be an integer");
  }
  return Math.max(min, Math.min(max, parsed));
}

export const ENTITY_TYPES = new Set(["product", "substance", "technology"]);
export const RECIPE_KINDS = new Set(["crafting", "refining", "cooking"]);
