import { once } from "node:events";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { isolatedHome, startDashboardProcess, type RunningDashboardProcess } from "../helpers/server-process.js";

interface RawResponse {
  status: number;
  headers: http.IncomingHttpHeaders;
  body: string;
}

interface ListedAlert {
  kind: string;
  subjectId: string;
  evidence: { reasonCode?: string };
}

const CAPACITY_KINDS = new Set([
  "window_open_idle",
  "weekly_reset_underused",
  "banked_reset_unusable_before_expiry",
  "banked_reset_expiring",
]);

function assertDegradedAlerts(alerts: ListedAlert[]): void {
  expect(alerts.length).toBeGreaterThan(0);
  const subjects = new Set(alerts.map((alert) => alert.subjectId));
  expect(subjects.has("claude-quota")).toBe(true);
  expect(subjects.has("codex-quota")).toBe(true);
  expect(subjects.has("grok-quota")).toBe(true);
  for (const alert of alerts) {
    expect(alert.kind).toBe("source_problem");
    expect(CAPACITY_KINDS.has(alert.kind)).toBe(false);
    if (alert.subjectId.endsWith("-quota")) {
      expect(alert.evidence.reasonCode).toBe("probes_disabled");
    }
  }
}

function writeConfig(dir: string, patch: Record<string, unknown> = {}): string {
  const example = JSON.parse(readFileSync(path.resolve("config/dashboard.example.json"), "utf8")) as Record<string, unknown>;
  const file = path.join(dir, "dashboard.json");
  writeFileSync(
    file,
    JSON.stringify({
      ...example,
      herdrSocket: path.join(dir, "missing-herdr.sock"),
      tmuxSocket: path.join(dir, "missing-tmux.sock"),
      repositoryRoots: [],
      quotaProbesEnabled: false,
      mode: "passive",
      ...patch,
    }),
  );
  return file;
}

async function boot(options: { fixture?: boolean; env?: NodeJS.ProcessEnv; patch?: Record<string, unknown> } = {}): Promise<{
  dir: string;
  dashboard: RunningDashboardProcess;
}> {
  const dir = mkdtempSync(path.join(tmpdir(), "herdr-http-"));
  const home = isolatedHome();
  const dashboard = await startDashboardProcess({
    configPath: writeConfig(dir, options.patch),
    databasePath: path.join(dir, "dashboard.sqlite"),
    fixture: options.fixture === true,
    home,
    ...(options.env ? { env: options.env } : {}),
  });
  return { dir, dashboard };
}

function rawRequest(port: number, options: { path: string; method?: string; headers?: Record<string, string> }): Promise<RawResponse> {
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: "127.0.0.1",
        port,
        path: options.path,
        method: options.method ?? "GET",
        headers: { host: `127.0.0.1:${port}`, ...options.headers },
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk: Buffer) => chunks.push(chunk));
        res.on("end", () => {
          resolve({
            status: res.statusCode ?? 0,
            headers: res.headers,
            body: Buffer.concat(chunks).toString("utf8"),
          });
        });
      },
    );
    req.on("error", reject);
    req.end();
  });
}

interface SseEvent {
  id: number;
  event: string;
  data: string;
}

function parseSse(buffer: string): { events: SseEvent[]; rest: string } {
  const parts = buffer.split("\n\n");
  const rest = parts.pop() ?? "";
  const events: SseEvent[] = [];
  for (const part of parts) {
    if (part.trim() === "" || part.startsWith(":")) continue;
    let id = Number.NaN;
    let event = "";
    const data: string[] = [];
    for (const line of part.split("\n")) {
      if (line.startsWith("id:")) id = Number(line.slice(3).trim());
      else if (line.startsWith("event:")) event = line.slice(6).trim();
      else if (line.startsWith("data:")) data.push(line.slice(5).trim());
    }
    if (event === "snapshot" && Number.isInteger(id)) events.push({ id, event, data: data.join("\n") });
  }
  return { events, rest };
}

async function readSse(port: number, stop: (events: SseEvent[]) => boolean, timeoutMs: number): Promise<SseEvent[]> {
  const req = http.request({
    host: "127.0.0.1",
    port,
    path: "/api/events",
    method: "GET",
    headers: { host: `127.0.0.1:${port}`, accept: "text/event-stream" },
  });
  req.end();
  const response = await once(req, "response");
  const res = response[0] as http.IncomingMessage;
  const events: SseEvent[] = [];
  let pending = "";
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      req.destroy();
      resolve(events);
    }, timeoutMs);
    res.on("data", (chunk: Buffer) => {
      pending += chunk.toString("utf8");
      const parsed = parseSse(pending);
      pending = parsed.rest;
      events.push(...parsed.events);
      if (stop(events)) {
        clearTimeout(timer);
        req.destroy();
        resolve(events);
      }
    });
    res.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    req.on("error", (error) => {
      if ((error as NodeJS.ErrnoException).code === "ECONNRESET") return;
      clearTimeout(timer);
      reject(error);
    });
  });
}

describe.sequential("loopback server", () => {
  it("binds 127.0.0.1, serves read-only health, and exits on SIGTERM", async () => {
    const started = await boot();
    try {
      const response = await fetch(`http://127.0.0.1:${started.dashboard.port}/api/health`);
      const body = (await response.json()) as { status: string; readOnly: boolean; schemaVersion: number };
      expect(response.status).toBe(200);
      expect(body.status).toBe("ok");
      expect(body.readOnly).toBe(true);
      expect(body.schemaVersion).toBe(1);
      expect(response.headers.get("cache-control")).toBe("no-store");

      const tcp = readFileSync(`/proc/${started.dashboard.pid}/net/tcp`, "utf8");
      const portHex = started.dashboard.port.toString(16).toUpperCase().padStart(4, "0");
      const listenRows = tcp
        .trim()
        .split("\n")
        .slice(1)
        .filter((line) => {
          const local = line.trim().split(/\s+/)[1] ?? "";
          return local.endsWith(`:${portHex}`);
        });
      expect(listenRows.length).toBeGreaterThan(0);
      for (const row of listenRows) {
        const local = row.trim().split(/\s+/)[1] ?? "";
        expect(local.startsWith("0100007F:")).toBe(true);
        expect(local.startsWith("00000000:")).toBe(false);
      }
    } finally {
      const stopped = await started.dashboard.stop();
      rmSync(started.dir, { recursive: true, force: true });
      rmSync(started.dashboard.home, { recursive: true, force: true });
      expect(stopped.code).toBe(0);
      expect(stopped.stderr).not.toContain("SYNTHETIC_SECRET_SENTINEL");
    }
  });

  it("rejects foreign host, origin, and mutating calls while broken providers stay optional", async () => {
    const started = await boot();
    const port = started.dashboard.port;
    try {
      const began = Date.now();
      const health = await rawRequest(port, { path: "/api/health" });
      expect(Date.now() - began).toBeLessThan(1_000);
      expect(health.status).toBe(200);
      expect(JSON.parse(health.body)).toMatchObject({ status: "ok", readOnly: true, schemaVersion: 1 });

      const snapshot = await rawRequest(port, { path: "/api/snapshot" });
      const body = JSON.parse(snapshot.body) as {
        providers: { provider: string; health: { status: string; reasonCode: string } }[];
        alerts: ListedAlert[];
      };
      expect(snapshot.status).toBe(200);
      expect(snapshot.headers["cache-control"]).toBe("no-store");
      expect(snapshot.headers["content-type"]).toContain("application/json");
      expect(body.providers.map((provider) => provider.provider)).toEqual(["claude", "codex", "grok"]);
      assertDegradedAlerts(body.alerts);
      for (const provider of body.providers) {
        expect(provider.health.status).toBe("disabled");
        expect(provider.health.reasonCode).toBe("probes_disabled");
      }

      const deadline = Date.now() + 3_000;
      let herdr = "";
      while (Date.now() < deadline && herdr === "") {
        const current = JSON.parse((await rawRequest(port, { path: "/api/snapshot" })).body) as {
          sources: { sourceId: string; status: string }[];
        };
        herdr = current.sources.find((source) => source.sourceId === "herdr")?.status ?? "";
        if (herdr === "") await new Promise((resolve) => setTimeout(resolve, 50));
      }
      expect(["missing", "timeout", "unsupported"]).toContain(herdr);

      const providers = await rawRequest(port, { path: "/api/providers" });
      expect(JSON.parse(providers.body).providers).toHaveLength(3);
      const sessions = await rawRequest(port, { path: "/api/sessions" });
      expect(JSON.parse(sessions.body)).toHaveProperty("sessions");
      const worktrees = await rawRequest(port, { path: "/api/worktrees" });
      expect(JSON.parse(worktrees.body)).toHaveProperty("worktrees");
      const alerts = await rawRequest(port, { path: "/api/alerts" });
      const listed = JSON.parse(alerts.body) as { alerts: ListedAlert[] };
      assertDegradedAlerts(listed.alerts);
      expect(listed.alerts.some((alert) => alert.subjectId === "herdr")).toBe(true);

      const missing = await rawRequest(port, { path: "/api/not-a-route" });
      expect(missing.status).toBe(404);
      expect(JSON.parse(missing.body)).toEqual({ error: { code: "not_found", message: "not found" } });
      const posted = await rawRequest(port, { path: "/api/snapshot", method: "POST" });
      expect(posted.status).toBe(405);
      expect(posted.headers.allow).toBe("GET");
      const foreignHost = await rawRequest(port, { path: "/api/health", headers: { host: "evil.example" } });
      expect(foreignHost.status).toBe(403);
      expect(JSON.parse(foreignHost.body).error.code).toBe("forbidden_host");
      const foreignOrigin = await rawRequest(port, {
        path: "/api/health",
        headers: { origin: "http://evil.example" },
      });
      expect(foreignOrigin.status).toBe(403);
      expect(JSON.parse(foreignOrigin.body).error.code).toBe("forbidden_origin");
      const crossSite = await rawRequest(port, {
        path: "/api/health",
        headers: { "sec-fetch-site": "cross-site" },
      });
      expect(crossSite.status).toBe(403);
      expect(JSON.parse(crossSite.body).error.code).toBe("forbidden_fetch_site");
    } finally {
      await started.dashboard.stop();
      rmSync(started.dir, { recursive: true, force: true });
      rmSync(started.dashboard.home, { recursive: true, force: true });
    }
  });

  it("grows the SSE sequence and reconnects at the latest snapshot", async () => {
    const started = await boot();
    try {
      const first = await readSse(started.dashboard.port, (events) => events.length >= 2 && events[1]!.id > events[0]!.id, 12_000);
      expect(first.length).toBeGreaterThanOrEqual(2);
      const previous = first[first.length - 1]!;
      expect(previous.id).toBeGreaterThan(first[0]!.id);
      const firstBody = JSON.parse(previous.data) as { sequence: number; schemaVersion: number };
      expect(firstBody.schemaVersion).toBe(1);
      expect(firstBody.sequence).toBe(previous.id);

      const reconnect = await readSse(started.dashboard.port, (events) => events.length >= 1, 1_000);
      expect(reconnect.length).toBeGreaterThanOrEqual(1);
      expect(reconnect[0]!.id).toBeGreaterThanOrEqual(previous.id);
      expect(reconnect[0]!.event).toBe("snapshot");
      expect(reconnect.every((event) => event.id >= reconnect[0]!.id)).toBe(true);
      expect(reconnect[0]!.id).not.toBe(1);
      const latest = JSON.parse(reconnect[0]!.data) as { sequence: number };
      expect(latest.sequence).toBe(reconnect[0]!.id);
    } finally {
      await started.dashboard.stop();
      rmSync(started.dir, { recursive: true, force: true });
      rmSync(started.dashboard.home, { recursive: true, force: true });
    }
  }, 20_000);

  it("serves the synthetic catalog in fixture mode without host binaries", async () => {
    const emptyPath = mkdtempSync(path.join(tmpdir(), "herdr-empty-path-"));
    const started = await boot({
      fixture: true,
      env: { HERDR_FIXTURE: "1", HERDR_ALLOW_NETWORK: "0", PATH: emptyPath },
    });
    try {
      const deadline = Date.now() + 3_000;
      let used: number | null = null;
      let snapshot: {
        mode?: string;
        providers?: {
          provider: string;
          windows: { kind: string; availability: string; usedPercent: number | null }[];
          bankedResets: unknown[] | null;
          bankedStatus: string;
          health: { provenance: string };
        }[];
        worktrees?: { path: string }[];
        sources?: { provenance: string }[];
      } = {};
      while (Date.now() < deadline && used !== 10) {
        const response = await rawRequest(started.dashboard.port, { path: "/api/snapshot" });
        snapshot = JSON.parse(response.body) as typeof snapshot;
        used = snapshot.providers?.[0]?.windows.find((window) => window.kind === "five_hour")?.usedPercent ?? null;
        if (used !== 10) await new Promise((resolve) => setTimeout(resolve, 30));
      }
      expect(snapshot.mode).toBe("fixture");
      expect(snapshot.providers?.map((provider) => provider.provider)).toEqual(["claude", "codex", "grok"]);
      expect(used).toBe(10);
      expect(snapshot.providers?.[1]?.bankedStatus).toBe("known");
      expect(snapshot.providers?.[1]?.bankedResets).toHaveLength(2);
      expect(snapshot.providers?.[2]?.windows.find((window) => window.kind === "five_hour")?.availability).toBe("not_applicable");
      expect(snapshot.worktrees?.[0]?.path).toBe("/work/demo");
      expect(snapshot.sources?.every((source) => source.provenance === "fixture")).toBe(true);
      const health = await rawRequest(started.dashboard.port, { path: "/api/health" });
      expect(JSON.parse(health.body)).toMatchObject({ status: "ok", mode: "fixture", readOnly: true });
    } finally {
      await started.dashboard.stop();
      rmSync(started.dir, { recursive: true, force: true });
      rmSync(started.dashboard.home, { recursive: true, force: true });
      rmSync(emptyPath, { recursive: true, force: true });
    }
  });
});
