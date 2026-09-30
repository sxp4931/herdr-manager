import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { frozenClock, type CommandRunner } from "@herdr/contracts";
import { createTmuxSource, parseTmuxPanes, TMUX_PANE_FORMAT } from "../../apps/server/src/adapters/tmux-source.js";
import { findProvider, providerFromArgv, type ProcessFacts, type ProcessLookup } from "../../apps/server/src/services/identity.js";
import { readLoopManifest } from "../../apps/server/src/services/loop-manifest.js";
import { inspectProcess } from "../../apps/server/src/services/process-info.js";

const NOW = "2026-09-29T16:00:00.000Z";
const clock = frozenClock(NOW);
const dirs: string[] = [];

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function tempDir(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "herdr-id-"));
  dirs.push(dir);
  return dir;
}

function facts(partial: Partial<ProcessFacts> & Pick<ProcessFacts, "argv">): ProcessFacts {
  return {
    cwd: partial.cwd ?? "/work",
    startTicks: partial.startTicks ?? 100,
    ppid: partial.ppid ?? 1,
    argv: partial.argv,
  };
}

function lookup(rows: Record<number, ProcessFacts>): ProcessLookup {
  return { inspect: (pid) => rows[pid] ?? null };
}

function pane(fields: string[]): string {
  return fields.join("\t");
}

describe("provider identity", () => {
  it("recognizes provider binaries and node wrappers, not shells", () => {
    expect(providerFromArgv(["/usr/local/bin/claude"])).toBe("claude");
    expect(providerFromArgv(["node", "/opt/lib/codex"])).toBe("codex");
    expect(providerFromArgv(["/usr/bin/node", "--", "/opt/grok"])).toBe("grok");
    expect(providerFromArgv(["bash", "-c", "sleep 60"])).toBeNull();
    expect(providerFromArgv(["zsh"])).toBeNull();
    expect(providerFromArgv(["node", "-e", "setInterval(() => {}, 1000)"])).toBeNull();
    const rows = lookup({
      10: facts({ argv: ["bash", "-c", "sleep 60"], ppid: 1 }),
      11: facts({ argv: ["node"], ppid: 12 }),
      12: facts({ argv: ["node", "/opt/claude"], ppid: 1 }),
    });
    expect(findProvider(10, rows)).toBeNull();
    expect(findProvider(11, rows)?.provider).toBe("claude");
    expect(findProvider(11, rows)?.pid).toBe(12);
  });

  it("reads this process from /proc without storing its command line", () => {
    const current = inspectProcess(process.pid);
    expect(current?.startTicks).toBeGreaterThan(0);
    expect(current?.argv.join(" ")).toContain("node");
    expect(current?.ppid).toBeGreaterThan(0);
  });
});

describe("loop manifests", () => {
  it("accepts a fresh fixture and rejects stale, escaped, and oversized files", () => {
    const work = tempDir();
    const manifestDir = path.join(work, ".herdr-dashboard");
    mkdirSync(manifestDir);
    const fixture = readFileSync("tests/fixtures/loops/valid.json", "utf8");
    writeFileSync(path.join(manifestDir, "run.json"), fixture);
    const fresh = readLoopManifest(work, new Date(NOW));
    expect(fresh.ok).toBe(true);
    if (fresh.ok) {
      expect(fresh.manifest).toMatchObject({ kind: "goal", state: "running", provider: "claude", pid: 4242 });
    }
    const boundary = JSON.parse(fixture) as { updatedAt: string };
    boundary.updatedAt = "2026-09-29T15:59:30.000Z";
    writeFileSync(path.join(manifestDir, "run.json"), JSON.stringify(boundary));
    expect(readLoopManifest(work, new Date(NOW)).ok).toBe(true);
    boundary.updatedAt = "2026-09-29T15:59:29.999Z";
    writeFileSync(path.join(manifestDir, "run.json"), JSON.stringify(boundary));
    expect(readLoopManifest(work, new Date(NOW))).toEqual({ ok: false, reason: "stale" });

    const outside = tempDir();
    mkdirSync(path.join(outside, "escaped"));
    writeFileSync(path.join(outside, "escaped", "run.json"), fixture);
    const linked = tempDir();
    symlinkSync(path.join(outside, "escaped"), path.join(linked, ".herdr-dashboard"));
    expect(readLoopManifest(linked, new Date(NOW))).toEqual({ ok: false, reason: "escape" });

    const bulky = tempDir();
    mkdirSync(path.join(bulky, ".herdr-dashboard"));
    writeFileSync(path.join(bulky, ".herdr-dashboard", "run.json"), `${"x".repeat(17 * 1024)}`);
    expect(readLoopManifest(bulky, new Date(NOW))).toEqual({ ok: false, reason: "oversize" });

    const invalid = tempDir();
    mkdirSync(path.join(invalid, ".herdr-dashboard"));
    writeFileSync(path.join(invalid, ".herdr-dashboard", "run.json"), JSON.stringify({ ...JSON.parse(fixture), schemaVersion: 2 }));
    expect(readLoopManifest(invalid, new Date(NOW))).toEqual({ ok: false, reason: "invalid" });
  });
});

describe("tmux collector", () => {
  it("keeps three unknown agent rows and drops the shell", async () => {
    const work = tempDir();
    mkdirSync(path.join(work, ".herdr-dashboard"));
    const fixture = JSON.parse(readFileSync("tests/fixtures/loops/valid.json", "utf8")) as { objective: string; processStartTicks: number };
    fixture.objective = "task SYNTHETIC_SECRET_SENTINEL";
    writeFileSync(path.join(work, ".herdr-dashboard", "run.json"), JSON.stringify(fixture));
    const stdout = [
      pane(["$1", "agents", "@1", "claude-win", "%1", "4242", "node", work, "0"]),
      pane(["$1", "agents", "@1", "shell", "%2", "222", "bash", "/tmp/shell", "0"]),
      pane(["$2", "other", "@2", "codex-win", "%3", "333", "node", "/work/codex", "0"]),
      pane(["$3", "third", "@3", "<img src=x onerror=alert(1)>", "%4", "444", "grok", "/work/grok", "0"]),
      pane(["$3", "third", "@3", "dead", "%5", "555", "claude", "/work/dead", "1"]),
    ].join("\n");
    const calls: string[][] = [];
    const runner: CommandRunner = {
      async run(request) {
        calls.push([...request.args]);
        if (request.args.includes("-V")) {
          return { code: 0, stdout: "tmux 3.5a\n", stderr: "", timedOut: false, truncated: false };
        }
        return { code: 0, stdout, stderr: "", timedOut: false, truncated: false };
      },
    };
    const processes = lookup({
      4242: facts({ argv: [process.execPath, path.join(work, "bin", "claude")], cwd: work, startTicks: 100 }),
      222: facts({ argv: ["bash", "-c", "sleep 60"], cwd: "/tmp/shell" }),
      333: facts({ argv: ["node", "/opt/codex"], cwd: "/work/codex", startTicks: 50 }),
      444: facts({ argv: ["/usr/local/bin/grok"], cwd: "/work/grok", startTicks: 70 }),
      555: facts({ argv: ["/usr/local/bin/claude"], cwd: "/work/dead" }),
    });
    const source = createTmuxSource({
      runner,
      clock,
      socketName: "fake-session",
      worktrees: [work],
      tmuxExecutable: process.execPath,
      processes,
    });
    const result = await source.collect(new AbortController().signal);
    expect(result.health.status).toBe("ok");
    expect(result.sessions.map((session) => session.provider).sort()).toEqual(["claude", "codex", "grok"]);
    expect(result.sessions.every((session) => session.status === "unknown")).toBe(true);
    expect(result.sessions.some((session) => session.label === "shell")).toBe(false);
    const claude = result.sessions.find((session) => session.provider === "claude");
    const codex = result.sessions.find((session) => session.provider === "codex");
    const grok = result.sessions.find((session) => session.provider === "grok");
    expect(claude?.loop).toMatchObject({ kind: "goal", state: "running", source: "manifest", iteration: 2 });
    expect(claude?.loop?.objective).toBe("task [redacted-secret]");
    expect(claude?.evidenceSource).toBe("manifest");
    expect(codex?.loop).toBeNull();
    expect(codex?.evidenceSource).toBe("tmux");
    expect(grok?.label).toBe("<img src=x onerror=alert(1)>");
    expect(JSON.stringify(result)).not.toContain("SYNTHETIC_SECRET_SENTINEL");
    expect(parseTmuxPanes(stdout)).toHaveLength(5);
    for (const args of calls) {
      expect(args).not.toContain("send-keys");
      expect(args).not.toContain("capture-pane");
      expect(args).not.toContain("kill-session");
      expect(args).not.toContain("kill-server");
    }
    expect(TMUX_PANE_FORMAT.includes("\t")).toBe(true);
    expect(TMUX_PANE_FORMAT.includes("\\t")).toBe(false);
    expect(calls.some((args) => args.includes("list-panes") && args.includes(TMUX_PANE_FORMAT) && args[0] === "-L")).toBe(true);

    fixture.processStartTicks = 101;
    writeFileSync(path.join(work, ".herdr-dashboard", "run.json"), JSON.stringify({ ...fixture, updatedAt: NOW, processStartTicks: 99 }));
    const reused = await source.collect(new AbortController().signal);
    expect(reused.sessions.find((session) => session.provider === "claude")?.loop).toBeNull();

    const stale = JSON.parse(readFileSync("tests/fixtures/loops/valid.json", "utf8")) as { updatedAt: string };
    stale.updatedAt = "2026-09-29T15:00:00.000Z";
    writeFileSync(path.join(work, ".herdr-dashboard", "run.json"), JSON.stringify(stale));
    const aged = await source.collect(new AbortController().signal);
    expect(aged.sessions.find((session) => session.provider === "claude")?.loop).toBeNull();
  });

  it("reports a missing server and a missing binary without launching panes", async () => {
    const calls: string[][] = [];
    const runner: CommandRunner = {
      async run(request) {
        calls.push([...request.args]);
        if (request.args[0] === "-S") {
          return { code: 1, stdout: "", stderr: "error connecting\n", timedOut: false, truncated: false };
        }
        return { code: 0, stdout: "tmux 3.5a\n", stderr: "", timedOut: false, truncated: false };
      },
    };
    const missingServer = createTmuxSource({
      runner,
      clock,
      socketPath: "/tmp/herdr-missing.sock",
      tmuxExecutable: process.execPath,
      processes: lookup({}),
    });
    const server = await missingServer.collect(new AbortController().signal);
    expect(server.health).toMatchObject({ status: "missing", reasonCode: "tmux_server_missing" });
    expect(server.sessions).toEqual([]);
    expect(calls.some((args) => args[0] === "-S" && args[1] === "/tmp/herdr-missing.sock" && args.includes("list-panes"))).toBe(true);
    const missingBinary = createTmuxSource({
      runner,
      clock,
      tmuxExecutable: "/no/such/tmux-binary",
    });
    const binary = await missingBinary.collect(new AbortController().signal);
    expect(binary.health).toMatchObject({ status: "missing", reasonCode: "tmux_missing" });
    expect(calls.some((args) => args.includes("send-keys"))).toBe(false);
  });
});
