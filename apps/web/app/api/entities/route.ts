import { ENTITY_TYPES, intParam, json } from "@/lib/http";
import { listEntities } from "@/lib/store";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  try {
    const url = new URL(request.url);
    const entityType = url.searchParams.get("type")?.trim() ?? "";
    if (!ENTITY_TYPES.has(entityType)) {
      return json(
        { error: "type must be product, substance, or technology" },
        400,
      );
    }
    const limit = intParam(url.searchParams.get("limit"), 100, 1, 200);
    const offset = intParam(url.searchParams.get("offset"), 0, 0, 100_000);
    const rows = await listEntities(entityType, limit, offset);
    return json({ type: entityType, items: rows });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message.includes("integer") ? 400 : 500;
    return json({ error: message }, status);
  }
}
