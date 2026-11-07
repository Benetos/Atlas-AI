import { json } from "@/lib/http";
import { getManifest } from "@/lib/store";

export const dynamic = "force-dynamic";

export async function GET() {
  try {
    return json(await getManifest());
  } catch (error) {
    return json(
      { error: error instanceof Error ? error.message : String(error) },
      503,
    );
  }
}
