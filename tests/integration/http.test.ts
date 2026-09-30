import { spawn } from "node:child_process";
import { once } from "node:events";
import { readFile } from "node:fs/promises";
import { createServer } from "node:net";
import { describe, expect, it } from "vitest";

function reservePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close(() => resolve(port));
    });
  });
}

async function waitForHealth(port: number): Promise<Response> {
  const deadline = Date.now() + 8_000;
  let last = "not started";
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/health`);
      if (response.status === 200) return response;
      last = `status ${response.status}`;
    } catch (error) {
      last = error instanceof Error ? error.message : "fetch failed";
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`health did not become ready: ${last}`);
}

describe("loopback server", () => {
  it("binds 127.0.0.1, serves read-only health, and exits on SIGTERM", async () => {
    const port = await reservePort();
    const child = spawn(
      process.execPath,
      ["apps/server/dist/main.js", "--host", "127.0.0.1", "--port", String(port)],
      { stdio: ["ignore", "pipe", "pipe"] },
    );
    let stderr = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
    });
    try {
      const response = await waitForHealth(port);
      const body = (await response.json()) as { status: string; readOnly: boolean; schemaVersion: number };
      expect(response.status).toBe(200);
      expect(body.status).toBe("ok");
      expect(body.readOnly).toBe(true);
      expect(body.schemaVersion).toBe(1);
      expect(response.headers.get("cache-control")).toBe("no-store");

      const tcp = await readFile(`/proc/${child.pid}/net/tcp`, "utf8");
      const portHex = port.toString(16).toUpperCase().padStart(4, "0");
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
      child.kill("SIGTERM");
    }
    const [code] = (await once(child, "exit")) as [number | null, NodeJS.Signals | null];
    expect(code).toBe(0);
    expect(stderr).not.toContain("SYNTHETIC_SECRET_SENTINEL");
  });
});
