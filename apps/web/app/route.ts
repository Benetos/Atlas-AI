import { SPA_HTML } from "@/lib/spa-html";

/**
 * Hosted entry for Cursor publish-app (Vercel for Platforms).
 * SPA_HTML is bundled into this function — do not fs.readFile public/spa.html
 * (public assets are not in the serverless file trace).
 */
export const dynamic = "force-static";

export function GET() {
  return new Response(SPA_HTML, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=0, must-revalidate",
    },
  });
}
