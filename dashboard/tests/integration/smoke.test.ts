import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { isolatedChildEnv, isolatedHome, reservePort } from "../helpers/server-process.js";

const dirs: string[] = [];
const children: Array<{ kill: (signal?: NodeJS.Signals) => boolean }> = [];

function tempDir(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "herdr-smoke-"));
  dirs.push(dir);
  return dir;
}

afterEach(() => {
  for (const child of children.splice(0)) {
    try {
      child.kill("SIGTERM");
    } catch {
      // The fixture server may already have exited.
    }
  }
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("fixture smoke", () => {
  it("refuses fixture mode unless network is explicitly disabled", async () => {
    const home = isolatedHome();
    const dir = tempDir();
    const child = spawn(process.execPath, [
      "apps/server/dist/main.js",
      "--fixture",
      "--host",
      "127.0.0.1",
      "--port",
      "4317",
      "--database",
      path.join(dir, "dashboard.sqlite"),
    ], {
      env: isolatedChildEnv(home, { HERDR_FIXTURE: "1" }),
      stdio: ["ignore", "pipe", "pipe"],
    });
    children.push(child);
    let stderr = "";
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk: string) => {
      stderr += chunk;
    });
    const [code] = await once(child, "exit");
    expect(code).not.toBe(0);
    expect(stderr).toContain("HERDR_ALLOW_NETWORK");
  });

  it("checks the running fixture server and writes evidence", async () => {
    const home = isolatedHome();
    const dir = tempDir();
    const port = await reservePort();
    const child = spawn(process.execPath, [
      "apps/server/dist/main.js",
      "--fixture",
      "--host",
      "127.0.0.1",
      "--port",
      String(port),
      "--database",
      path.join(dir, "dashboard.sqlite"),
    ], {
      env: isolatedChildEnv(home, { HERDR_FIXTURE: "1", HERDR_ALLOW_NETWORK: "0", HERDR_STATE_DIR: dir }),
      stdio: ["ignore", "pipe", "pipe"],
    });
    children.push(child);
    const evidence = path.join(dir, "smoke.json");
    const result = spawnSync(process.execPath, [
      "scripts/smoke.mjs",
      "--base-url",
      `http://127.0.0.1:${port}`,
      "--wait-ms",
      "15000",
      "--evidence",
      evidence,
    ], {
      encoding: "utf8",
      env: { ...process.env, HERDR_SMOKE_PID: String(child.pid), HERDR_STATE_DIR: dir },
      timeout: 30_000,
    });
    expect(result.status, result.stderr).toBe(0);
    const report = JSON.parse(readFileSync(evidence, "utf8")) as { ok: boolean; skippedTests: number; checks: Array<{ status: string }> };
    expect(report.ok).toBe(true);
    expect(report.skippedTests).toBe(0);
    expect(report.checks.every((item) => item.status === "passed")).toBe(true);
    expect(readFileSync(evidence, "utf8")).not.toContain("SYNTHETIC_SECRET_SENTINEL");
  }, 40_000);
});
