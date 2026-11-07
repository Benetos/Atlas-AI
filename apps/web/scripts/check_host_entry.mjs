/**
 * Hosting contract for Cursor publish-app (Vercel for Platforms):
 * `/` must be served as a static public HTML entry via rewrite — not a
 * Route Handler that fs.readFile's spa.html (those files are not in the
 * serverless function file trace, so authenticated `/` 404s/fails).
 */
import { readFile, access } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const errors = [];

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

const config = await readFile(path.join(root, "next.config.mjs"), "utf8");
if (!/source:\s*["']\/["']/.test(config) || !/destination:\s*["']\/spa\.html["']/.test(config)) {
  errors.push('next.config.mjs must rewrite "/" -> "/spa.html"');
}

try {
  const route = await readFile(path.join(root, "app", "route.ts"), "utf8");
  if (/readFile/.test(route) || /spa\.html/.test(route)) {
    errors.push(
      "app/route.ts must not fs.readFile spa.html (breaks Vercel serverless file tracing); remove it and use the rewrite",
    );
  }
} catch {
  // absent route.ts is fine — rewrite owns `/`
}

try {
  await access(path.join(root, "static"));
  errors.push(
    "remove top-level static/ (deprecated in Next.js); serve SPA from public/ so Cursor/Vercel packing is unambiguous",
  );
} catch {
  // good — no deprecated static/
}

if (errors.length) {
  console.error("check_host_entry FAILED:");
  for (const e of errors) console.error(" -", e);
  process.exit(1);
}
console.log("check_host_entry OK: / rewrites to /spa.html; static assets present");
