import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

/** Defense in depth: never serve build-seed paths even if a file leaks into the deploy. */
export function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;
  if (
    pathname === "/seed" ||
    pathname.startsWith("/seed/") ||
    pathname === "/pack" ||
    pathname.startsWith("/pack/") ||
    pathname === "/build-seed" ||
    pathname.startsWith("/build-seed/")
  ) {
    return new NextResponse("Not Found", { status: 404 });
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/seed/:path*", "/pack/:path*", "/build-seed/:path*"],
};
