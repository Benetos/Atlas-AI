import { ENTITY_TYPES, json } from "@/lib/http";
import { recipesUsing } from "@/lib/store";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ type: string; id: string }> };

export async function GET(_request: Request, { params }: Params) {
  try {
    const { type, id } = await params;
    const entityType = decodeURIComponent(type);
    const gameId = decodeURIComponent(id);
    if (!ENTITY_TYPES.has(entityType)) {
      return json({ error: "Unknown entity type" }, 400);
    }
    return json({
      items: await recipesUsing(entityType, gameId),
    });
  } catch (error) {
    return json(
      { error: error instanceof Error ? error.message : String(error) },
      500,
    );
  }
}
