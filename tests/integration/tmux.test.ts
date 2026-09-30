import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomBytes } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import { systemClock, type CommandRunner } from "@herdr/contracts";
import { createCommandRunner } from "../../apps/server/src/adapters/command-runner.js";
import { createTmuxSource } from "../../apps/server/src/adapters/tmux-source.js";
import { inspectProcess } from "../../apps/server/src/services/process-info.js";

const sockets: string[] = [];
const directories: string[] = [];
const pids: number[] = [];

function tmuxBinary(): string {
  for (const segment of (process.env.PATH ?? "").split(path.delimiter)) {
    if (!segment) continue;
    const candidate = path.join(segment, "tmux");
    if (existsSync(candidate)) return candidate;
  }
  throw new Error("tmux is not installed");
}

function hashTree(directory: string): string {
  const hash = createHash("sha256");
  const walk = (current: string, prefix: string): void => {
    for (const entry of readdirSync(current, { withFileTypes: true }).sort((left, right) => left.name.localeCompare(right.name))) {
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) walk(full, relative);
      else if (entry.isFile()) {
        hash.update(relative);
        hash.update(readFileSync(full));
      }
    }
  };
  walk(directory, "");
  return hash.digest("hex");
}

afterEach(() => {
  const tmux = existsSync("/usr/bin/tmux") ? "/usr/bin/tmux" : "tmux";
  for (const socket of sockets.splice(0)) {
    spawnSync(tmux, ["-L", socket, "kill-server"], { encoding: "utf8" });
  }
  for (const pid of pids.splice(0)) {
    try {
      process.kill(pid, "SIGKILL");
    } catch {
      // The private pane has already exited.
    }
  }
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

describe("private tmux server", () => {
  it("observes synthetic agents and does not write the worktree", async () => {
    const tmux = tmuxBinary();
    const socket = `chhaya-dashboard-test-${randomBytes(4).toString("hex")}`;
    sockets.push(socket);
    const directory = mkdtempSync(path.join(tmpdir(), "herdr-tmuxfix-"));
    directories.push(directory);
    const bin = path.join(directory, "bin");
    mkdirSync(bin);
    for (const name of ["claude", "codex", "grok"]) {
      writeFileSync(path.join(bin, name), "setInterval(() => {}, 1000);\n");
    }
    const calls: string[][] = [];
    const inner = createCommandRunner();
    const runner: CommandRunner = {
      async run(request, signal) {
        calls.push([...request.args]);
        return inner.run(request, signal);
      },
    };
    const source = createTmuxSource({
      runner,
      clock: systemClock(),
      socketName: socket,
      worktrees: [directory],
      tmuxExecutable: tmux,
    });
    const signal = new AbortController().signal;
    const missing = await source.collect(signal);
    expect(missing.health).toMatchObject({ status: "missing", reasonCode: "tmux_server_missing" });
    expect(missing.sessions).toEqual([]);

    const start = (args: string[]): void => {
      const result = spawnSync(tmux, ["-f", "/dev/null", "-L", socket, ...args], { encoding: "utf8" });
      expect(result.status, result.stderr).toBe(0);
    };
    start(["new-session", "-d", "-s", "agents", "-n", "claude", "-c", directory, "--", process.execPath, path.join(bin, "claude")]);
    start(["new-window", "-d", "-t", "agents", "-n", "codex", "-c", directory, "--", process.execPath, path.join(bin, "codex")]);
    start(["new-window", "-d", "-t", "agents", "-n", "grok", "-c", directory, "--", process.execPath, path.join(bin, "grok")]);
    start(["new-window", "-d", "-t", "agents", "-n", "shell", "-c", directory, "--", "bash", "-c", "sleep 60"]);

    const observed = await source.collect(signal);
    expect(observed.health.status).toBe("ok");
    expect(observed.sessions.map((session) => session.provider).sort()).toEqual(["claude", "codex", "grok"]);
    expect(observed.sessions.every((session) => session.status === "unknown" && session.loop === null)).toBe(true);
    expect(observed.sessions.some((session) => session.label === "shell")).toBe(false);
    for (const session of observed.sessions) {
      if (session.pid) pids.push(session.pid);
    }

    const claude = observed.sessions.find((session) => session.provider === "claude");
    expect(claude?.pid).toBeTruthy();
    const info = inspectProcess(claude?.pid ?? 0);
    expect(info).toBeTruthy();
    const manifest = {
      schemaVersion: 1,
      sessionIdentity: "synthetic-goal",
      provider: "claude",
      pid: claude?.pid,
      processStartTicks: info?.startTicks,
      kind: "goal",
      state: "running",
      iteration: 1,
      objective: "Refresh the dashboard fixture",
      updatedAt: new Date().toISOString(),
    };
    mkdirSync(path.join(directory, ".herdr-dashboard"));
    const manifestPath = path.join(directory, ".herdr-dashboard", "run.json");
    writeFileSync(manifestPath, JSON.stringify(manifest));
    const before = hashTree(directory);
    const running = await source.collect(signal);
    expect(hashTree(directory)).toBe(before);
    expect(running.sessions.find((session) => session.provider === "claude")?.loop).toMatchObject({
      kind: "goal",
      state: "running",
      source: "manifest",
    });

    writeFileSync(manifestPath, JSON.stringify({ ...manifest, updatedAt: new Date(Date.now() - 31_000).toISOString() }));
    const stale = await source.collect(signal);
    expect(stale.sessions.find((session) => session.provider === "claude")?.loop).toBeNull();

    writeFileSync(manifestPath, JSON.stringify({
      ...manifest,
      updatedAt: new Date().toISOString(),
      processStartTicks: (info?.startTicks ?? 0) + 1,
    }));
    const reused = await source.collect(signal);
    expect(reused.sessions.find((session) => session.provider === "claude")?.loop).toBeNull();

    for (const args of calls) {
      expect(args).not.toContain("send-keys");
      expect(args).not.toContain("capture-pane");
      expect(args).not.toContain("kill-session");
      expect(args).not.toContain("kill-server");
      expect(args).not.toContain("new-session");
    }
    expect(calls.some((args) => args[0] === "-L" && args[1] === socket && args.includes("list-panes"))).toBe(true);
  });
});
