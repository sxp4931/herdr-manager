const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost"]);

export function isLoopbackHost(host: string): boolean {
  return LOOPBACK_HOSTS.has(host);
}

export function authorityAllowed(hostHeader: string | undefined, port: number): boolean {
  if (!hostHeader) {
    return false;
  }
  const expected = new Set([`127.0.0.1:${port}`, `localhost:${port}`]);
  return expected.has(hostHeader.trim().toLowerCase());
}

export function originAllowed(origin: string | undefined, port: number, dev = false): boolean {
  if (!origin) {
    return true;
  }
  const allowed = new Set([
    `http://127.0.0.1:${port}`,
    `http://localhost:${port}`,
  ]);
  if (dev) {
    allowed.add("http://127.0.0.1:4318");
    allowed.add("http://localhost:4318");
  }
  return allowed.has(origin);
}

export const SECURITY_HEADERS: Record<string, string> = {
  "Content-Security-Policy":
    "default-src 'self'; script-src 'self'; style-src 'self'; font-src 'self'; img-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "X-Frame-Options": "DENY",
  "Cache-Control": "no-store",
};
