import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { CommandDeniedError, runCommand } from "../../apps/server/src/adapters/command-runner.js";
import { loadConfig, loadConfigFile } from "../../apps/server/src/config.js";

const dirs: string[] = [];

function tempDir(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "herdr-probe-"));
  dirs.push(dir);
  return dir;
}

afterEach(() => {
  for (const dir of dirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function which(name: string): string | null {
  const result = spawnSync(process.execPath, ["-e", "process.stdout.write(process.env.PATH ?? '')"], { encoding: "utf8" });
  for (const segment of (result.stdout || process.env.PATH || "").split(path.delimiter)) {
    if (!segment) continue;
    const candidate = path.join(segment, name);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

async function runNode(dir: string, script: string, args: string[], extras: Partial<{ timeoutMs: number; maxBytes: number; env: Record<string, string> }> = {}) {
  const file = path.join(dir, "child.js");
  writeFileSync(file, script);
  const controller = new AbortController();
  return runCommand(
    {
      executable: process.execPath,
      args: [file, ...args],
      cwd: dir,
      timeoutMs: extras.timeoutMs ?? 2_000,
      maxBytes: extras.maxBytes ?? 16_384,
      allowedEnvironment: {
        PATH: process.env.PATH ?? "",
        ...extras.env,
      },
    },
    controller.signal,
  );
}

describe("collector configuration", () => {
  it("keeps probes disabled and rejects a non-loopback host", () => {
    const config = loadConfigFile("config/dashboard.example.json", {});
    expect(config.quotaProbesEnabled).toBe(false);
    expect(config.mode).toBe("passive");
    expect(config.host).toBe("127.0.0.1");
    expect(() => loadConfig({ ...config, host: "0.0.0.0" }, {})).toThrow(/non-loopback/);
    expect(() => loadConfig({ ...config, mode: "fixture" }, {})).toThrow(/HERDR_FIXTURE/);
    const fixture = loadConfig(config, { HERDR_FIXTURE: "1" });
    expect(fixture.mode).toBe("fixture");
    const root = tempDir();
    expect(loadConfig({ ...config, repositoryRoots: [root] }, {}).repositoryRoots).toEqual([root]);
    expect(() => loadConfig({ ...config, repositoryRoots: ["relative/path"] }, {})).toThrow(/absolute/);
  });
});

describe("command runner", () => {
  it("keeps shell metacharacters as literal arguments", async () => {
    const dir = tempDir();
    const sentinel = path.join(dir, "sentinel-from-shell");
    const recorded = path.join(dir, "argv.txt");
    const hostile = `; touch ${sentinel}`;
    const result = await runNode(
      dir,
      `const fs = require("node:fs"); fs.writeFileSync(process.argv[3], JSON.stringify(process.argv.slice(2)));`,
      [hostile, recorded],
    );
    expect(result.code).toBe(0);
    expect(existsSync(sentinel)).toBe(false);
    expect(JSON.parse(readFileSync(recorded, "utf8"))).toEqual([hostile, recorded]);
  });

  it("strips API keys and stops a flooded child before the cap is stored", async () => {
    const dir = tempDir();
    const result = await runNode(
      dir,
      `if (process.env.ANTHROPIC_API_KEY || process.env.OPENAI_API_KEY || process.env.OPENAI_BASE_URL || process.env.GIT_CONFIG_COUNT) { process.stdout.write("LEAKED"); process.exit(2); } while (true) { process.stdout.write("x".repeat(4096)); }`,
      [],
      {
        maxBytes: 1024,
        timeoutMs: 2_000,
        env: {
          ANTHROPIC_API_KEY: "sk-ant-should-not-pass",
          OPENAI_API_KEY: "sk-should-not-pass",
          OPENAI_BASE_URL: "https://example.invalid/v1",
          GIT_CONFIG_COUNT: "1",
          HERDR_SESSION: "named-session",
        },
      },
    );
    expect(result.truncated).toBe(true);
    expect(Buffer.byteLength(result.stdout)).toBeLessThanOrEqual(1024);
    expect(result.stdout).not.toContain("LEAKED");
    expect(result.stdout).not.toContain("sk-ant");
  });

  it("reaps a timed-out process group", async () => {
    const dir = tempDir();
    const parentFile = path.join(dir, "parent.pid");
    const childFile = path.join(dir, "sleep.pid");
    const started = Date.now();
    const result = await runNode(
      dir,
      `const fs = require("node:fs");
       const { spawn } = require("node:child_process");
       fs.writeFileSync(process.argv[2], String(process.pid));
       const child = spawn("sleep", ["60"], { stdio: "ignore" });
       fs.writeFileSync(process.argv[3], String(child.pid));
       setInterval(() => {}, 1000);`,
      [parentFile, childFile],
      { timeoutMs: 300 },
    );
    expect(result.timedOut).toBe(true);
    expect(Date.now() - started).toBeLessThan(5_000);
    const parentPid = Number(readFileSync(parentFile, "utf8"));
    const sleepPid = Number(readFileSync(childFile, "utf8"));
    const deadline = Date.now() + 2_000;
    const alive = (pid: number) => {
      try {
        process.kill(pid, 0);
        return true;
      } catch {
        return false;
      }
    };
    while ((alive(parentPid) || alive(sleepPid)) && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    expect(alive(parentPid)).toBe(false);
    expect(alive(sleepPid)).toBe(false);
  });

  it("denies shells, git mutators, and tmux input", async () => {
    const dir = tempDir();
    const bash = which("bash");
    expect(bash).toBeTruthy();
    await expect(
      runCommand(
        {
          executable: bash ?? "/bin/bash",
          args: ["-c", "echo no"],
          cwd: dir,
          timeoutMs: 500,
          maxBytes: 100,
          allowedEnvironment: {},
        },
        new AbortController().signal,
      ),
    ).rejects.toBeInstanceOf(CommandDeniedError);
    const git = which("git");
    expect(git).toBeTruthy();
    await expect(
      runCommand(
        {
          executable: git ?? "/usr/bin/git",
          args: ["reset", "--hard"],
          cwd: dir,
          timeoutMs: 500,
          maxBytes: 100,
          allowedEnvironment: {},
        },
        new AbortController().signal,
      ),
    ).rejects.toBeInstanceOf(CommandDeniedError);
    await expect(
      runCommand(
        {
          executable: git ?? "/usr/bin/git",
          args: ["-c", "core.hooksPath=/tmp/hooks", "status"],
          cwd: dir,
          timeoutMs: 500,
          maxBytes: 100,
          allowedEnvironment: {},
        },
        new AbortController().signal,
      ),
    ).rejects.toBeInstanceOf(CommandDeniedError);
    await expect(
      runCommand(
        {
          executable: git ?? "/usr/bin/git",
          args: ["log", "-1", "-p"],
          cwd: dir,
          timeoutMs: 500,
          maxBytes: 100,
          allowedEnvironment: {},
        },
        new AbortController().signal,
      ),
    ).rejects.toBeInstanceOf(CommandDeniedError);
    const tmux = which("tmux");
    if (tmux) {
      await expect(
        runCommand(
          {
            executable: tmux,
            args: ["send-keys", "hello"],
            cwd: dir,
            timeoutMs: 500,
            maxBytes: 100,
            allowedEnvironment: {},
          },
          new AbortController().signal,
        ),
      ).rejects.toBeInstanceOf(CommandDeniedError);
      const socket = path.join(dir, "missing.sock");
      const listed = await runCommand(
        {
          executable: tmux,
          args: ["-S", socket, "list-panes", "-a", "-F", "#{pane_id}"],
          cwd: dir,
          timeoutMs: 2_000,
          maxBytes: 4_096,
          allowedEnvironment: { PATH: process.env.PATH ?? "" },
        },
        new AbortController().signal,
      );
      expect(listed.code).not.toBe(0);
      expect(existsSync(socket)).toBe(false);
      await expect(
        runCommand(
          {
            executable: tmux,
            args: ["-S", socket, "send-keys", "hello"],
            cwd: dir,
            timeoutMs: 500,
            maxBytes: 100,
            allowedEnvironment: {},
          },
          new AbortController().signal,
        ),
      ).rejects.toBeInstanceOf(CommandDeniedError);
    }
    const mode = statSync(dir).mode & 0o777;
    expect(mode & 0o002).toBe(0);
  });

  it("rejects a world-writable working directory", async () => {
    const dir = tempDir();
    chmodSync(dir, 0o777);
    await expect(
      runCommand(
        {
          executable: process.execPath,
          args: ["-e", "process.exit(0)"],
          cwd: dir,
          timeoutMs: 500,
          maxBytes: 100,
          allowedEnvironment: {},
        },
        new AbortController().signal,
      ),
    ).rejects.toBeInstanceOf(CommandDeniedError);
  });
});

describe("capability doctor", () => {
  it("reports three providers without launching a probe", () => {
    const result = spawnSync(process.execPath, ["scripts/probe-doctor.mjs", "--json"], { encoding: "utf8" });
    expect(result.status).toBe(0);
    const report = JSON.parse(result.stdout) as {
      quotaProbesEnabled: boolean;
      providers: Array<{ provider: string; liveProbe: boolean; available: boolean }>;
    };
    expect(report.quotaProbesEnabled).toBe(false);
    expect(report.providers.map((entry) => entry.provider)).toEqual(["claude", "codex", "grok"]);
    expect(report.providers.every((entry) => entry.liveProbe === false)).toBe(true);
    expect(result.stdout).not.toContain("ANTHROPIC_API_KEY");
    expect(result.stdout).not.toContain("/home/");
    const live = spawnSync(process.execPath, ["scripts/probe-doctor.mjs", "--live"], { encoding: "utf8" });
    expect(live.status).toBe(2);
    expect(live.stderr).toContain("live probes are disabled");
  });
});
