import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { frozenClock, type CommandRunner } from "@herdr/contracts";
import { createCommandRunner } from "../../apps/server/src/adapters/command-runner.js";
import { createGitSource } from "../../apps/server/src/adapters/git-source.js";
import { createHerdrSource } from "../../apps/server/src/adapters/herdr-source.js";
import { runQuotaProbe } from "../../apps/server/src/adapters/quota-probe.js";
import { createTmuxSource } from "../../apps/server/src/adapters/tmux-source.js";
import { READ_ONLY_ROUTES } from "../../apps/server/src/http.js";
import { openStore } from "../../apps/server/src/storage/repository.js";
import { startFakeHerdr } from "../helpers/fake-herdr.js";
import { isolatedHome, startDashboardProcess } from "../helpers/server-process.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const SENTINEL = "SYNTHETIC_SECRET_SENTINEL";
const HOSTILE_SUBJECT = `${SENTINEL} https://user:secretpass@example.test/x <script>alert(1)</script> ../../etc/passwd \u0007bell`;
const READ_METHODS = new Set(["agent.list", "session.snapshot"]);
const MUTATORS = [
  "commit",
  "push",
  "reset",
  "checkout",
  "rebase",
  "merge",
  "clean",
  "add",
  "send-keys",
  "capture-pane",
  "kill-session",
  "new-session",
];
const clock = frozenClock("2026-09-29T16:00:00.000Z");
const dirs: string[] = [];

function tempDir(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "herdr-ro-"));
  dirs.push(dir);
  return dir;
}

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function gitExecutable(): string {
  for (const segment of (process.env.PATH ?? "").split(path.delimiter)) {
    if (!segment) continue;
    const candidate = path.join(segment, "git");
    if (existsSync(candidate)) return candidate;
  }
  throw new Error("git is not on PATH");
}

function runGit(args: string[]): void {
  const result = spawnSync(gitExecutable(), args, { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`git ${args.join(" ")} failed: ${result.stderr}`);
  }
}

function auditingRunner(): { runner: CommandRunner; calls: string[][] } {
  const inner = createCommandRunner();
  const calls: string[][] = [];
  return {
    calls,
    runner: {
      async run(request, signal) {
        calls.push([...request.args]);
        return inner.run(request, signal);
      },
    },
  };
}

function positionals(args: readonly string[], valueFlags: ReadonlySet<string>): string[] {
  const found: string[] = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] ?? "";
    if (valueFlags.has(arg)) {
      index += 1;
      continue;
    }
    if (arg.startsWith("-")) continue;
    found.push(arg);
  }
  return found;
}

function assertNoSentinel(label: string, text: string): void {
  expect(text, label).not.toContain(SENTINEL);
  expect(text, label).not.toContain("\"screen\":");
  expect(text, label).not.toContain("rawScreen");
}

interface RawResponse {
  status: number;
  headers: http.IncomingHttpHeaders;
  body: string;
}

function rawRequest(port: number, options: { path: string; method?: string; headersOnly?: boolean }): Promise<RawResponse> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (value: RawResponse): void => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    const fail = (error: Error): void => {
      if (settled) return;
      settled = true;
      reject(error);
    };
    const req = http.request(
      {
        host: "127.0.0.1",
        port,
        path: options.path,
        method: options.method ?? "GET",
        headers: { host: `127.0.0.1:${port}` },
      },
      (res) => {
        if (options.headersOnly) {
          res.resume();
          finish({ status: res.statusCode ?? 0, headers: res.headers, body: "" });
          req.destroy();
          return;
        }
        const chunks: Buffer[] = [];
        res.on("data", (chunk: Buffer) => chunks.push(chunk));
        res.on("end", () => {
          finish({
            status: res.statusCode ?? 0,
            headers: res.headers,
            body: Buffer.concat(chunks).toString("utf8"),
          });
        });
      },
    );
    req.on("error", fail);
    req.end();
  });
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

describe("read-only adapter and route audit", () => {
  it("rejects every mutating method on the exported routes and keeps the sentinel out of responses", async () => {
    const dir = tempDir();
    const home = isolatedHome();
    dirs.push(home);
    const example = JSON.parse(readFileSync(path.join(repoRoot, "config/dashboard.example.json"), "utf8")) as Record<string, unknown>;
    const configPath = path.join(dir, "dashboard.json");
    writeFileSync(configPath, JSON.stringify({
      ...example,
      herdrSocket: path.join(dir, "missing-herdr.sock"),
      tmuxSocket: path.join(dir, "missing-tmux.sock"),
      repositoryRoots: [],
      quotaProbesEnabled: false,
      mode: "passive",
    }));
    const databasePath = path.join(dir, "dashboard.sqlite");
    const dashboard = await startDashboardProcess({
      configPath,
      databasePath,
      fixture: true,
      home,
      env: { HERDR_FIXTURE: "1", HERDR_ALLOW_NETWORK: "0" },
    });
    try {
      const methods = ["POST", "PUT", "PATCH", "DELETE", "TRACE"];
      const paths = ["/", ...READ_ONLY_ROUTES, "/api/not-a-route", "/%2e%2e/etc/passwd", `/api/health?note=${SENTINEL}`];
      for (const method of methods) {
        for (const route of paths) {
          const response = await rawRequest(dashboard.port, { path: route, method });
          expect(response.status, `${method} ${route}`).toBe(405);
          expect(response.headers.allow).toBe("GET");
          assertNoSentinel(`${method} ${route}`, response.body);
        }
      }
      for (const route of READ_ONLY_ROUTES) {
        const response = await rawRequest(dashboard.port, {
          path: route,
          ...(route === "/api/events" ? { headersOnly: true } : {}),
        });
        expect(response.status, route).toBe(200);
        assertNoSentinel(route, response.body);
      }
      const missing = await rawRequest(dashboard.port, { path: "/api/not-a-route" });
      expect(missing.status).toBe(404);
      const escaped = await rawRequest(dashboard.port, { path: "/%2e%2e/etc/passwd" });
      expect(escaped.body).not.toContain("root:x:0:0");
      const queried = await rawRequest(dashboard.port, { path: `/api/health?note=${SENTINEL}` });
      assertNoSentinel("query", queried.body);
      const page = await rawRequest(dashboard.port, { path: "/" });
      expect(page.status).toBe(200);
      expect(page.body).toContain("herdr dashboard");
      expect(page.headers["content-security-policy"]).toContain("script-src 'self'");
    } finally {
      const stopped = await dashboard.stop();
      assertNoSentinel("stderr", stopped.stderr);
    }
    const stored = readFileSync(databasePath);
    expect(stored.includes(Buffer.from(SENTINEL))).toBe(false);
  });

  it("observes only read git commands and stores hostile subjects without the sentinel", async () => {
    const dir = tempDir();
    const repo = path.join(dir, "repo");
    runGit(["init", "-b", "main", repo]);
    runGit(["-C", repo, "config", "user.name", "Dashboard Fixture"]);
    runGit(["-C", repo, "config", "user.email", "fixture@example.invalid"]);
    writeFileSync(path.join(repo, "README"), "one\n");
    runGit(["-C", repo, "add", "README"]);
    runGit(["-C", repo, "commit", "-m", HOSTILE_SUBJECT]);
    const audit = auditingRunner();
    const source = createGitSource({ runner: audit.runner, clock, gitExecutable: gitExecutable() });
    const collected = await source.collect([repo], new AbortController().signal);
    expect(audit.calls.length).toBeGreaterThan(0);
    for (const args of audit.calls) {
      const words = positionals(args, new Set(["-C", "-c", "--git-dir", "--work-tree"]));
      const command = words[0] ?? (args.includes("--version") ? "--version" : "");
      expect(["rev-parse", "status", "symbolic-ref", "log", "worktree", "--version"]).toContain(command);
      if (command === "worktree") expect(words[1]).toBe("list");
      expect(words.some((word) => MUTATORS.includes(word))).toBe(false);
    }
    const work = collected.worktrees.find((entry) => entry.path === repo);
    expect(work).toBeTruthy();
    const subject = work?.recentCommits[0]?.subject ?? "";
    expect(subject).toContain("[redacted-secret]");
    expect(subject).toContain("https://[redacted]@example.test/x");
    expect(subject).toContain("<script>alert(1)</script>");
    expect(subject).toContain("../../etc/passwd");
    expect(subject).not.toContain("\u0007");
    assertNoSentinel("git subject", subject);
    const database = path.join(dir, "dashboard.sqlite");
    const store = openStore({ file: database, clock });
    try {
      store.applyGit(collected.worktrees);
      const logged: string[] = [];
      const echoing = openStore({
        file: path.join(dir, "echo.sqlite"),
        clock,
        log: (line) => logged.push(line),
      });
      try {
        echoing.applyGit(collected.worktrees);
        expect(logged.join("\n")).not.toContain(SENTINEL);
      } finally {
        echoing.close();
      }
    } finally {
      store.close();
    }
    expect(readFileSync(database).includes(Buffer.from(SENTINEL))).toBe(false);
    expect(readFileSync(path.join(dir, "echo.sqlite")).includes(Buffer.from(SENTINEL))).toBe(false);
  });

  it("reports a git timeout without a mutator when log does not finish", async () => {
    const dir = tempDir();
    const repo = path.join(dir, "repo");
    runGit(["init", "-b", "main", repo]);
    runGit(["-C", repo, "config", "user.name", "Dashboard Fixture"]);
    runGit(["-C", repo, "config", "user.email", "fixture@example.invalid"]);
    writeFileSync(path.join(repo, "README"), "one\n");
    runGit(["-C", repo, "add", "README"]);
    runGit(["-C", repo, "commit", "-m", "timeout fixture"]);
    const gitPath = path.join(dir, "git");
    writeFileSync(gitPath, `#!/bin/sh\nfor arg in "$@"; do\n  if [ "$arg" = "log" ]; then sleep 30; exit 0; fi\ndone\nexec ${gitExecutable()} "$@"\n`);
    chmodSync(gitPath, 0o755);
    const audit = auditingRunner();
    const source = createGitSource({ runner: audit.runner, clock, gitExecutable: gitPath });
    const started = Date.now();
    const collected = await source.collect([repo], new AbortController().signal);
    expect(Date.now() - started).toBeGreaterThanOrEqual(7_000);
    expect(Date.now() - started).toBeLessThan(12_000);
    expect(collected.health.status).toBe("timeout");
    expect(collected.worktrees.some((entry) => entry.health.reasonCode === "timeout")).toBe(true);
    expect(audit.calls.some((args) => args.includes("log"))).toBe(true);
    for (const args of audit.calls) {
      const words = positionals(args, new Set(["-C", "-c"]));
      expect(words.some((word) => MUTATORS.includes(word))).toBe(false);
    }
  });

  it("lists panes only on an explicit missing tmux socket", async () => {
    const dir = tempDir();
    const socketPath = path.join(dir, "missing.sock");
    const audit = auditingRunner();
    let tmuxPath: string | null = null;
    for (const segment of (process.env.PATH ?? "").split(path.delimiter)) {
      if (!segment) continue;
      const candidate = path.join(segment, "tmux");
      if (existsSync(candidate)) {
        tmuxPath = candidate;
        break;
      }
    }
    const source = createTmuxSource({
      runner: audit.runner,
      clock,
      socketPath,
      ...(tmuxPath ? { tmuxExecutable: tmuxPath } : {}),
    });
    const collected = await source.collect(new AbortController().signal);
    expect(collected.sessions).toEqual([]);
    expect(collected.health.status).not.toBe("ok");
    if (tmuxPath) {
      expect(audit.calls.some((args) => args[0] === "-S" && args[1] === socketPath && args.includes("list-panes"))).toBe(true);
      for (const args of audit.calls) {
        const words = positionals(args, new Set(["-S", "-L", "-f", "-F"]));
        const command = words[0] ?? (args.includes("-V") ? "-V" : "");
        expect(["list-panes", "-V"]).toContain(command);
        expect(args.some((arg) => MUTATORS.includes(arg))).toBe(false);
      }
    } else {
      expect(collected.health.reasonCode).toBe("tmux_missing");
      expect(audit.calls).toEqual([]);
    }
  });

  it("degrades when the herdr socket crashes and only asks for reads", async () => {
    const crashed = await startFakeHerdr(() => ({ type: "drop" }));
    try {
      const source = createHerdrSource({
        clock,
        socketPath: crashed.socketPath,
        environment: { HOME: path.join(crashed.socketPath, "no-home") },
      });
      const collected = await source.collect(new AbortController().signal);
      expect(collected.health.status).not.toBe("ok");
      expect(collected.sessions).toEqual([]);
      expect(crashed.methods.length).toBeGreaterThan(0);
      expect(crashed.methods.every((method) => READ_METHODS.has(method))).toBe(true);
    } finally {
      await crashed.close();
    }
    const missing = createHerdrSource({
      clock,
      socketPath: path.join(tempDir(), "gone.sock"),
      environment: { HOME: tempDir() },
    });
    const absent = await missing.collect(new AbortController().signal);
    expect(absent.health.status).not.toBe("ok");
    expect(absent.sessions).toEqual([]);
  });

  it("reaps a usage PTY that ignores its deadline", async () => {
    const dir = tempDir();
    chmodSync(dir, 0o700);
    writeFileSync(path.join(dir, "mode"), "slow");
    const started = Date.now();
    const result = await runQuotaProbe({
      executable: path.join(repoRoot, "tests", "helpers", "fake-cli.py"),
      profile: "fixture-v1",
      cwd: dir,
      deadlineMs: 100,
    });
    expect(result.ok).toBe(false);
    expect(result.reason).toBe("timeout");
    expect(result.sent).toEqual([]);
    expect(JSON.stringify(result)).not.toContain(SENTINEL);
    expect(Date.now() - started).toBeLessThan(4_000);
    const pid = Number(readFileSync(path.join(dir, "pid"), "utf8"));
    const sleepPid = Number(readFileSync(path.join(dir, "sleep.pid"), "utf8"));
    const deadline = Date.now() + 2_000;
    while ((alive(pid) || alive(sleepPid)) && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    expect(alive(pid)).toBe(false);
    expect(alive(sleepPid)).toBe(false);
  });
});
