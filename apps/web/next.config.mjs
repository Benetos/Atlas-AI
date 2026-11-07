/** @type {import('next').NextConfig} */
const nextConfig = {
  serverExternalPackages: ["@electric-sql/pglite", "pg"],
  // Cursor publish-app hosts on Vercel for Platforms. Serve the SPA as a
  // traced public asset — do not fs.readFile spa.html from a Route Handler
  // (public files are not in the serverless function file trace).
  async rewrites() {
    return [{ source: "/", destination: "/spa.html" }];
  },
};

export default nextConfig;
