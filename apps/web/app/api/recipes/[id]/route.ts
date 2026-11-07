import { json } from "@/lib/http";
import { getRecipe } from "@/lib/store";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ id: string }> };

export async function GET(_request: Request, { params }: Params) {
  try {
    const { id } = await params;
    const recipeId = decodeURIComponent(id);
    if (!recipeId || recipeId.includes("/")) {
      return json({ error: "not found" }, 404);
    }
    const recipe = await getRecipe(recipeId);
    if (!recipe) return json({ error: "not in this snapshot." }, 404);
    return json({ recipe });
  } catch (error) {
    return json(
      { error: error instanceof Error ? error.message : String(error) },
      500,
    );
  }
}
