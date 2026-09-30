import net from "node:net";
import type { AddressInfo } from "node:net";
import type { Server } from "node:http";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { scenarios, type DashboardSnapshot } from "@herdr/contracts";
import { createDashboardServer } from "../../apps/server/src/http.js";

const servers: Server[] = [];
const dirs: string[] = [];

afterEach(async () => {
  for (const server of servers.splice(0)) {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

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

describe("http hardening", () => {
  it("answers a malformed absolute-form target with 400 and keeps serving", async () => {
    const port = await listen(scenarios.daily);
    expect(await rawTarget(port, "http://[")).toMatch(/^HTTP\/1\.1 400/);
    expect(await rawTarget(port, "http://a:b@[")).toMatch(/^HTTP\/1\.1 400/);
    const health = await fetch(`http://127.0.0.1:${port}/api/health`);
    expect(health.status).toBe(200);
  });
});
