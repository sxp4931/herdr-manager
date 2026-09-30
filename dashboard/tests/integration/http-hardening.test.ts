import net from "node:net";
import type { AddressInfo } from "node:net";
import type { Server } from "node:http";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { scenarios, type DashboardSnapshot } from "@herdr/contracts";
import { createDashboardServer, formatSnapshotEvent } from "../../apps/server/src/http.js";

const servers: Server[] = [];
const dirs: string[] = [];

afterEach(async () => {
  for (const server of servers.splice(0)) {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function snapshotWithLabel(label: string): DashboardSnapshot {
  const base = structuredClone(scenarios.daily);
  const first = base.sessions[0];
  if (!first) throw new Error("daily fixture has no sessions");
  base.sessions = [{ ...first, label, cwd: "/work/demo?key=abc123" }, ...base.sessions.slice(1)];
  return base;
}

async function listen(snapshot: DashboardSnapshot): Promise<number> {
  const webDist = mkdtempSync(path.join(tmpdir(), "herdr-web-"));
  dirs.push(webDist);
  writeFileSync(path.join(webDist, "index.html"), "<!doctype html><title>t</title>");
  const server = createDashboardServer({
    host: "127.0.0.1",
    port: 0,
    webDist,
    mode: "fixture",
    snapshots: { current: () => snapshot, subscribe: () => () => undefined },
  });
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return (server.address() as AddressInfo).port;
}

function rawTarget(port: number, target: string): Promise<string> {
  return new Promise((resolve) => {
    const socket = net.connect(port, "127.0.0.1", () => {
      socket.write(`GET ${target} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: close\r\n\r\n`);
    });
    let data = "";
    socket.on("data", (chunk: Buffer) => {
      data += chunk.toString("utf8");
    });
    socket.on("close", () => resolve(data.split("\r\n")[0] ?? ""));
    socket.on("error", () => resolve(""));
  });
}

async function getJson(port: number, pathname: string): Promise<unknown> {
  const response = await fetch(`http://127.0.0.1:${port}${pathname}`);
  return JSON.parse(await response.text()) as unknown;
}

describe("http hardening", () => {
  it("answers a malformed absolute-form target with 400 and keeps serving", async () => {
    const port = await listen(scenarios.daily);
    expect(await rawTarget(port, "http://[")).toMatch(/^HTTP\/1\.1 400/);
    expect(await rawTarget(port, "http://a:b@[")).toMatch(/^HTTP\/1\.1 400/);
    const health = await fetch(`http://127.0.0.1:${port}/api/health`);
    expect(health.status).toBe(200);
  });

  it("redacts secret-looking values without corrupting the JSON body", async () => {
    const label = "fix callback?token=abc123 then https://user:pw@example.test/x";
    const port = await listen(snapshotWithLabel(label));
    for (const pathname of ["/api/snapshot", "/api/sessions"]) {
      const body = (await getJson(port, pathname)) as { sessions: { label: string; cwd: string | null }[] };
      expect(body.sessions).toHaveLength(scenarios.daily.sessions.length);
      expect(body.sessions[0]?.label).toBe("fix callback?token=[redacted] then https://[redacted]@example.test/x");
      expect(body.sessions[0]?.cwd).toBe("/work/demo?key=[redacted]");
    }
  });

  it("keeps an SSE frame parseable when a value looks like a secret", () => {
    const frame = formatSnapshotEvent(snapshotWithLabel("a?sig=xyz"));
    const data = frame.split("\n").find((line) => line.startsWith("data: "))?.slice("data: ".length) ?? "";
    const parsed = JSON.parse(data) as DashboardSnapshot;
    expect(parsed.sessions[0]?.label).toBe("a?sig=[redacted]");
    expect(parsed.sessions).toHaveLength(scenarios.daily.sessions.length);
  });
});
