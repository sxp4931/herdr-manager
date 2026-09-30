import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import path from "node:path";
import { parseHealth, type Health } from "@herdr/contracts";
import { authorityAllowed, originAllowed, SECURITY_HEADERS } from "./security.js";

export interface ServerOptions {
  host: string;
  port: number;
  webDist: string;
  mode: Health["mode"];
  dev?: boolean;
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

function writeJson(res: ServerResponse, status: number, body: unknown, extra?: Record<string, string>): void {
  const payload = JSON.stringify(body);
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
    createReadStream(file).pipe(res);
  } catch {
    writeError(res, 404, "not_found", "not found");
  }
}

export function createDashboardServer(options: ServerOptions): Server {
  const health = parseHealth({
    status: "ok",
    schemaVersion: 1,
    mode: options.mode,
    readOnly: true,
  });

  return createServer((req: IncomingMessage, res: ServerResponse) => {
    const port = options.port;
    if (!authorityAllowed(req.headers.host, port)) {
      writeError(res, 403, "forbidden_host", "host is not the bound loopback authority");
      return;
    }
    if (!originAllowed(req.headers.origin, port, options.dev === true)) {
      writeError(res, 403, "forbidden_origin", "origin is not allowed");
      return;
    }
    const method = req.method ?? "GET";
    const url = new URL(req.url ?? "/", `http://127.0.0.1:${port}`);
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
      writeError(res, 404, "not_found", "not found");
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
}
