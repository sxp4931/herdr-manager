import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import path from "node:path";
import { parseHealth, type DashboardSnapshot, type Health } from "@herdr/contracts";
import { assertNoSentinel, redactOutbound } from "./services/redaction.js";
import type { SnapshotHub } from "./services/snapshot.js";
import { authorityAllowed, fetchSiteAllowed, originAllowed, SECURITY_HEADERS } from "./security.js";

export const SSE_HEARTBEAT_MS = 15_000;
export const SSE_BUFFER_LIMIT = 64 * 1024;

export interface ServerOptions {
  host: string;
  port: number;
  webDist: string;
  mode: Health["mode"];
  dev?: boolean;
  snapshots?: SnapshotHub;
  heartbeatMs?: number;
  bufferLimit?: number;
}

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
  ".woff2": "font/woff2",
  ".json": "application/json; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".ico": "image/x-icon",
};

function headerValue(value: string | string[] | undefined): string | undefined {
  if (Array.isArray(value)) return value[0];
  return value;
}

/**
 * Redact each string value, then serialize. Running the text patterns over
 * serialized JSON let a query-string or URL-credential match run past the
 * closing quote and corrupt the document.
 */
function redactedJson(body: unknown): string {
  const payload = JSON.stringify(redactOutbound(body));
  assertNoSentinel(payload);
  return payload;
}

function writeJson(res: ServerResponse, status: number, body: unknown, extra?: Record<string, string>): void {
  const payload = redactedJson(body);
  res.writeHead(status, {
    ...SECURITY_HEADERS,
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload),
    ...extra,
  });
  res.end(payload);
}

function writeError(res: ServerResponse, status: number, code: string, message: string, extra?: Record<string, string>): void {
  writeJson(res, status, { error: { code, message } }, extra);
}

export function formatSnapshotEvent(snapshot: DashboardSnapshot): string {
  const data = redactedJson(snapshot);
  return `id: ${snapshot.sequence}\nevent: snapshot\ndata: ${data}\n\n`;
}

export function bufferExceeded(queuedBytes: number, limit = SSE_BUFFER_LIMIT): boolean {
  return queuedBytes > limit;
}

export const SNAPSHOT_ROUTES: Record<string, (snapshot: DashboardSnapshot) => unknown> = {
  "/api/snapshot": (snapshot) => snapshot,
  "/api/providers": (snapshot) => ({ providers: snapshot.providers }),
  "/api/sessions": (snapshot) => ({ sessions: snapshot.sessions }),
  "/api/worktrees": (snapshot) => ({ worktrees: snapshot.worktrees }),
  "/api/alerts": (snapshot) => ({ alerts: snapshot.alerts }),
};

export const READ_ONLY_ROUTES = ["/api/health", "/api/events", ...Object.keys(SNAPSHOT_ROUTES)] as const;

function apiBody(pathname: string, snapshot: DashboardSnapshot): unknown | null {
  const read = SNAPSHOT_ROUTES[pathname];
  return read ? read(snapshot) : null;
}

function serveEvents(
  req: IncomingMessage,
  res: ServerResponse,
  hub: SnapshotHub,
  heartbeatMs: number,
  bufferLimit: number,
): void {
  let snapshot: DashboardSnapshot;
  try {
    snapshot = hub.current();
  } catch {
    writeError(res, 500, "snapshot_unavailable", "snapshot is unavailable");
    return;
  }
  res.writeHead(200, {
    ...SECURITY_HEADERS,
    "Content-Type": "text/event-stream; charset=utf-8",
    Connection: "keep-alive",
  });
  let closed = false;
  let lastSequence = -1;
  const writeFrame = (frame: string): void => {
    if (closed || res.writableEnded || res.destroyed) return;
    if (bufferExceeded(res.writableLength, bufferLimit)) {
      cleanup();
      res.end();
      return;
    }
    res.write(frame);
  };
  const emit = (next: DashboardSnapshot): void => {
    if (next.sequence <= lastSequence) return;
    lastSequence = next.sequence;
    writeFrame(formatSnapshotEvent(next));
  };
  const unsubscribe = hub.subscribe(emit);
  const heartbeat = setInterval(() => {
    writeFrame(": heartbeat\n\n");
  }, heartbeatMs);
  heartbeat.unref();
  const cleanup = (): void => {
    if (closed) return;
    closed = true;
    clearInterval(heartbeat);
    unsubscribe();
  };
  emit(snapshot);
  req.on("close", cleanup);
  res.on("close", cleanup);
  res.on("error", cleanup);
}

async function serveStatic(res: ServerResponse, webDist: string, urlPath: string): Promise<void> {
  const relative = urlPath === "/" ? "index.html" : urlPath.replace(/^\/+/, "");
  const resolved = path.resolve(webDist, relative);
  const root = path.resolve(webDist);
  if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) {
    writeError(res, 404, "not_found", "not found");
    return;
  }
  let file = resolved;
  try {
    const info = await stat(file);
    if (info.isDirectory()) {
      file = path.join(file, "index.html");
    }
  } catch {
    if (urlPath.startsWith("/api/")) {
      writeError(res, 404, "not_found", "not found");
      return;
    }
    file = path.join(root, "index.html");
  }
  try {
    const info = await stat(file);
    if (!info.isFile()) {
      writeError(res, 404, "not_found", "not found");
      return;
    }
    const ext = path.extname(file).toLowerCase();
    res.writeHead(200, {
      ...SECURITY_HEADERS,
      "Content-Type": MIME[ext] ?? "application/octet-stream",
      "Content-Length": info.size,
    });
    const stream = createReadStream(file);
    stream.on("error", () => res.destroy());
    stream.pipe(res);
  } catch {
    writeError(res, 404, "not_found", "not found");
  }
}

/** A malformed absolute-form target must not throw inside the request listener. */
function requestUrl(target: string | undefined, port: number): URL | null {
  try {
    return new URL(target ?? "/", `http://127.0.0.1:${port}`);
  } catch {
    return null;
  }
}

export function createDashboardServer(options: ServerOptions): Server {
  const health = parseHealth({
    status: "ok",
    schemaVersion: 1,
    mode: options.mode,
    readOnly: true,
  });
  const heartbeatMs = options.heartbeatMs ?? SSE_HEARTBEAT_MS;
  const bufferLimit = options.bufferLimit ?? SSE_BUFFER_LIMIT;

  const server: Server = createServer((req: IncomingMessage, res: ServerResponse) => {
    const address = server.address();
    const port = typeof address === "object" && address ? address.port : options.port;
    if (!authorityAllowed(headerValue(req.headers.host), port)) {
      writeError(res, 403, "forbidden_host", "host is not the bound loopback authority");
      return;
    }
    if (!originAllowed(headerValue(req.headers.origin), port, options.dev === true)) {
      writeError(res, 403, "forbidden_origin", "origin is not allowed");
      return;
    }
    if (!fetchSiteAllowed(headerValue(req.headers["sec-fetch-site"]))) {
      writeError(res, 403, "forbidden_fetch_site", "cross-site fetch is not allowed");
      return;
    }
    const method = req.method ?? "GET";
    const url = requestUrl(req.url, port);
    if (!url) {
      writeError(res, 400, "bad_request", "request target is not a valid path");
      return;
    }
    if (url.pathname.startsWith("/api/")) {
      if (method !== "GET" && method !== "HEAD") {
        writeError(res, 405, "method_not_allowed", "this dashboard is read-only", { Allow: "GET" });
        return;
      }
      if (url.pathname === "/api/health") {
        if (method === "HEAD") {
          res.writeHead(200, {
            ...SECURITY_HEADERS,
            "Content-Type": "application/json; charset=utf-8",
          });
          res.end();
          return;
        }
        writeJson(res, 200, health);
        return;
      }
      const hub = options.snapshots;
      if (!hub) {
        writeError(res, 404, "not_found", "not found");
        return;
      }
      if (url.pathname === "/api/events") {
        if (method === "HEAD") {
          res.writeHead(200, {
            ...SECURITY_HEADERS,
            "Content-Type": "text/event-stream; charset=utf-8",
          });
          res.end();
          return;
        }
        serveEvents(req, res, hub, heartbeatMs, bufferLimit);
        return;
      }
      let body: unknown;
      try {
        const snapshot = hub.current();
        body = apiBody(url.pathname, snapshot);
      } catch {
        writeError(res, 500, "snapshot_unavailable", "snapshot is unavailable");
        return;
      }
      if (body === null) {
        writeError(res, 404, "not_found", "not found");
        return;
      }
      if (method === "HEAD") {
        res.writeHead(200, {
          ...SECURITY_HEADERS,
          "Content-Type": "application/json; charset=utf-8",
        });
        res.end();
        return;
      }
      writeJson(res, 200, body);
      return;
    }
    if (method !== "GET" && method !== "HEAD") {
      writeError(res, 405, "method_not_allowed", "this dashboard is read-only", { Allow: "GET" });
      return;
    }
    if (method === "HEAD") {
      res.writeHead(200, SECURITY_HEADERS);
      res.end();
      return;
    }
    void serveStatic(res, options.webDist, url.pathname);
  });
  return server;
}
