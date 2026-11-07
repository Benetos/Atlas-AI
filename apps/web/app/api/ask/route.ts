import { gatherLocal } from "@/lib/gather";
import { json } from "@/lib/http";
import { planQuery } from "@/lib/query-plan";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  try {
    const prompt = new URL(request.url).searchParams.get("q")?.trim() ?? "";
    if (!prompt) return json({ error: "Missing q" }, 400);
    const plan = planQuery(prompt);
    return json(await gatherLocal(plan));
  } catch (error) {
    return json(
      { error: error instanceof Error ? error.message : String(error) },
      500,
    );
  }
}
