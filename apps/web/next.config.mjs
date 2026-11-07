/** @type {import('next').NextConfig} */
const nextConfig = {
  serverExternalPackages: ["@electric-sql/pglite", "pg"],
  // `/` is owned by app/route.ts (bundled SPA_HTML). Keep a rewrite as a
  // secondary path to the static shell for hosts that serve public/ directly.
  async rewrites() {
    return [{ source: "/spa", destination: "/spa.html" }];
  },
};

export default nextConfig;
