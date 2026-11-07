/**
 * Hosting contract for Cursor publish-app (Vercel for Platforms):
 * `/` must be a Route Handler that returns SPA_HTML from the serverless
 * bundle — never fs.readFile of public/spa.html (public files are not in
 * the function file trace). Seed gzips must not live under apps/web.
 */
import { readFile, access } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const errors = [];

const sync = spawnSync(process.execPath, [path.join(root, "scripts", "sync_spa_html.mjs")], {
  cwd: root,
  encoding: "utf8",
});
if (sync.status !== 0) {
  errors.push(`sync_spa_html failed: ${sync.stderr || sync.stdout}`);
}

const spaPath = path.join(root, "public", "spa.html");
try {
  await access(spaPath);
} catch {
  errors.push("missing public/spa.html");
}

const spa = await readFile(spaPath, "utf8").catch(() => "");
if (spa && !spa.includes('href="/static/styles.css"')) {
  errors.push("spa.html must reference /static/styles.css");
}
if (spa && !spa.includes('src="/static/app.js"')) {
  errors.push("spa.html must reference /static/app.js");
}

for (const asset of ["public/static/app.js", "public/static/styles.css"]) {
  try {
    await access(path.join(root, asset));
  } catch {
    errors.push(`missing ${asset}`);
  }
}

try {
  const spaMod = await readFile(path.join(root, "lib", "spa-html.ts"), "utf8");
  if (!spaMod.includes("export const SPA_HTML")) {
    errors.push("lib/spa-html.ts must export SPA_HTML");
  }
  if (spa && !spaMod.includes(JSON.stringify(spa))) {
    errors.push("lib/spa-html.ts is out of sync with public/spa.html — run sync_spa_html");
  }
} catch {
  errors.push("missing lib/spa-html.ts (run scripts/sync_spa_html.mjs)");
}

try {
  const route = await readFile(path.join(root, "app", "route.ts"), "utf8");
  // Ignore comments when scanning for disk reads.
  const code = route.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
  if (/\b(?:readFile|createReadStream)\b|\bfrom\s+["']node:fs/.test(code)) {
    errors.push(
      "app/route.ts must not read spa.html from disk (breaks Vercel serverless file tracing)",
    );
  }
  if (!/SPA_HTML/.test(route) || !/from\s+["']@\/lib\/spa-html["']/.test(route)) {
    errors.push('app/route.ts must return SPA_HTML imported from "@/lib/spa-html"');
  }
} catch {
  errors.push("missing app/route.ts (bundled SPA entry required for Cursor hosting)");
}

try {
  await access(path.join(root, "static"));
  errors.push(
    "remove top-level static/ (deprecated in Next.js); serve SPA from public/ so Cursor/Vercel packing is unambiguous",
  );
} catch {
  // good — no deprecated static/
}

for (const name of [
  "entities.jsonl.gz",
  "recipes.jsonl.gz",
  "recipe_ingredients.jsonl.gz",
  "content_records.jsonl.gz",
]) {
  try {
    await access(path.join(root, "seed", name));
    errors.push(
      `remove apps/web/seed/${name} — seed archives must live in pack/web-seed (outside publish project_dir) so Public privacy review is not tripped`,
    );
  } catch {
    // good — not packed into apps/web
  }
}

try {
  await access(path.join(root, "seed-source.json"));
} catch {
  errors.push("missing seed-source.json (hosted build fetch map for pack/web-seed)");
}

try {
  const vercel = JSON.parse(await readFile(path.join(root, "vercel.json"), "utf8"));
  if (vercel.framework !== "nextjs") {
    errors.push('vercel.json must set "framework": "nextjs" (prevents static-only public/ deploys)');
  }
} catch {
  errors.push('missing vercel.json with "framework": "nextjs"');
}

try {
  await access(path.join(root, "public", "index.html"));
} catch {
  errors.push("missing public/index.html (sync from spa.html — static fallback for /)");
}

if (errors.length) {
  console.error("check_host_entry FAILED:");
  for (const e of errors) console.error(" -", e);
  process.exit(1);
}
console.log(
  "check_host_entry OK: / serves bundled SPA_HTML; seed gzips outside apps/web",
);
