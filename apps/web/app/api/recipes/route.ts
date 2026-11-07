import { RECIPE_KINDS, intParam, json } from "@/lib/http";
import { listRecipes } from "@/lib/store";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  try {
    const url = new URL(request.url);
    const kindRaw = url.searchParams.get("kind")?.trim() || null;
    if (kindRaw != null && !RECIPE_KINDS.has(kindRaw)) {
      return json(
        { error: "kind must be crafting, refining, or cooking" },
        400,
      );
    }
    const limit = intParam(url.searchParams.get("limit"), 100, 1, 200);
    const offset = intParam(url.searchParams.get("offset"), 0, 0, 100_000);
    const rows = await listRecipes(kindRaw, limit, offset);
    return json({ kind: kindRaw, items: rows });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message.includes("integer") ? 400 : 500;
    return json({ error: message }, status);
  }
}
