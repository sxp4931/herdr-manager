import { spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { CommandDeniedError, runCommand } from "../../apps/server/src/adapters/command-runner.js";
import { clampDeadline, interpretProbeOutput, runQuotaProbe } from "../../apps/server/src/adapters/quota-probe.js";
import { loadConfig, loadConfigFile } from "../../apps/server/src/config.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const fakeCli = path.join(repoRoot, "tests", "helpers", "fake-cli.py");
const venvPython = path.join(repoRoot, ".venv", "bin", "python");

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
    const guarded = await runCommand(
      {
        executable: git ?? "/usr/bin/git",
        args: ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=", "status", "--porcelain=v1", "-z"],
        cwd: dir,
        timeoutMs: 2_000,
        maxBytes: 4_096,
        allowedEnvironment: { PATH: process.env.PATH ?? "", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null" },
      },
      new AbortController().signal,
    );
    expect(guarded.code).not.toBe(0);
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

  it("keeps null git config switches and strips config injection", async () => {
    const dir = tempDir();
    const result = await runNode(
      dir,
      `process.stdout.write(JSON.stringify({
        count: process.env.GIT_CONFIG_COUNT ?? null,
        global: process.env.GIT_CONFIG_GLOBAL ?? null,
        system: process.env.GIT_CONFIG_SYSTEM ?? null,
        nosystem: process.env.GIT_CONFIG_NOSYSTEM ?? null,
      }));`,
      [],
      {
        env: {
          GIT_CONFIG_COUNT: "1",
          GIT_CONFIG_GLOBAL: "/dev/null",
          GIT_CONFIG_SYSTEM: "/tmp/evil-system",
          GIT_CONFIG_NOSYSTEM: "1",
        },
      },
    );
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({
      count: null,
      global: "/dev/null",
      system: null,
      nosystem: "1",
    });
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
  function doctorEnv(bin: string): NodeJS.ProcessEnv {
    return {
      ...process.env,
      PATH: bin,
      ANTHROPIC_API_KEY: "SYNTHETIC_SECRET_SENTINEL",
      HOME: "/home/doctor-must-not-print",
    };
  }

  function assertQuiet(result: { stdout: string; stderr: string }): void {
    expect(result.stdout).not.toContain("SYNTHETIC_SECRET_SENTINEL");
    expect(result.stderr).not.toContain("SYNTHETIC_SECRET_SENTINEL");
    expect(result.stdout).not.toContain("ANTHROPIC_API_KEY");
    expect(result.stdout).not.toContain("/home/");
    expect(result.stdout).not.toContain("rawScreen");
    expect(result.stdout).not.toContain("\"screen\":");
  }

  it("reports three providers without launching a probe", () => {
    const result = spawnSync(process.execPath, ["scripts/probe-doctor.mjs", "--json"], {
      encoding: "utf8",
      env: doctorEnv(process.env.PATH ?? ""),
    });
    expect(result.status).toBe(0);
    const report = JSON.parse(result.stdout) as {
      quotaProbesEnabled: boolean;
      executedCount: number;
      providers: Array<{ provider: string; liveProbe: boolean; available: boolean; status: string; diagnostic: string }>;
    };
    expect(report.quotaProbesEnabled).toBe(false);
    expect(report.executedCount).toBe(0);
    expect(report.providers.map((entry) => entry.provider)).toEqual(["claude", "codex", "grok"]);
    expect(report.providers.every((entry) => entry.liveProbe === false)).toBe(true);
    for (const entry of report.providers) {
      expect(entry.status).toBe(entry.available ? "present" : "missing");
      expect(entry.diagnostic).toBe("not_requested");
    }
    assertQuiet(result);
    const live = spawnSync(process.execPath, ["scripts/probe-doctor.mjs", "--live"], {
      encoding: "utf8",
      env: doctorEnv(process.env.PATH ?? ""),
    });
    expect(live.status).toBe(0);
    const liveReport = JSON.parse(live.stdout) as {
      executedCount: number;
      providers: Array<{ available: boolean; status: string; diagnostic: string; liveProbe: boolean; reason?: string }>;
    };
    expect(liveReport.executedCount).toBe(0);
    expect(liveReport.providers.every((entry) => entry.liveProbe === false)).toBe(true);
    for (const entry of liveReport.providers) {
      if (entry.available) {
        expect(entry.status).toBe("profile_unsafe");
        expect(entry.diagnostic).toBe("refused");
        expect(entry.reason).toBe("startup hooks and MCP are not proven inert");
      } else {
        expect(entry.status).toBe("missing");
        expect(entry.diagnostic).toBe("missing");
      }
    }
    assertQuiet(live);
  });

  it("leaves a trap binary unexecuted for both doctor modes", () => {
    const dir = tempDir();
    const bin = path.join(dir, "bin");
    const marker = path.join(dir, "launched");
    mkdirSync(bin);
    for (const name of ["claude", "codex", "grok"]) {
      const file = path.join(bin, name);
      writeFileSync(file, `#!/bin/sh\nprintf launched >> '${marker}'\n`);
      chmodSync(file, 0o755);
    }
    for (const args of [["--json"], ["--live"]]) {
      const result = spawnSync(process.execPath, ["scripts/probe-doctor.mjs", ...args], {
        encoding: "utf8",
        env: doctorEnv(bin),
      });
      expect(result.status).toBe(0);
      expect(existsSync(marker)).toBe(false);
      const report = JSON.parse(result.stdout) as {
        executed: unknown[];
        executedCount: number;
        providers: Array<{ available: boolean; status: string; diagnostic: string; liveProbe: boolean }>;
      };
      expect(report.executed).toEqual([]);
      expect(report.executedCount).toBe(0);
      expect(report.providers.map((entry) => entry.available)).toEqual([true, true, true]);
      expect(report.providers.every((entry) => entry.liveProbe === false)).toBe(true);
      if (args[0] === "--live") {
        expect(report.providers.every((entry) => entry.status === "profile_unsafe" && entry.diagnostic === "refused")).toBe(true);
      } else {
        expect(report.providers.every((entry) => entry.status === "present" && entry.diagnostic === "not_requested")).toBe(true);
      }
      assertQuiet(result);
    }
  });
});

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitForText(file: string): Promise<string> {
  const deadline = Date.now() + 3_000;
  while (Date.now() < deadline) {
    if (existsSync(file) && statSync(file).size > 0) {
      return readFileSync(file, "utf8").trim();
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`missing ${path.basename(file)}`);
}

async function waitDead(pid: number): Promise<void> {
  const deadline = Date.now() + 2_000;
  while (alive(pid) && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

describe("quota probe transport", () => {
  it("clamps the deadline without waiting for the ceiling", () => {
    expect(clampDeadline(60_000)).toBe(20_000);
    expect(clampDeadline(undefined)).toBe(20_000);
    expect(clampDeadline(50)).toBe(100);
    expect(clampDeadline(2_000)).toBe(2_000);
  });

  it("drops a raw screen instead of returning helper stdout", () => {
    const raw = '{"ok":true,"screen":"Session  10% used","secret":"SYNTHETIC_SECRET_SENTINEL"}';
    const parsed = interpretProbeOutput(raw, { profile: "fixture-v1", deadlineMs: 20_000 });
    expect(parsed.reason).toBe("invalid_result");
    expect(parsed).not.toHaveProperty("screen");
    expect(parsed).not.toHaveProperty("stdout");
    const encoded = JSON.stringify(parsed);
    expect(encoded).not.toContain("Session");
    expect(encoded).not.toContain("SYNTHETIC_SECRET_SENTINEL");
    const trailing = `${JSON.stringify({
      ok: false,
      provider: "fixture",
      profile: "fixture-v1",
      state: "started",
      reason: "timeout",
      version: null,
      isatty: false,
      sent: [],
      childReaped: true,
      recognized: false,
      deadlineMs: 2000,
    })}\n{"screen":"Weekly  20% used"}`;
    const second = interpretProbeOutput(trailing, { profile: "fixture-v1", deadlineMs: 2_000 });
    expect(second.reason).toBe("invalid_result");
    expect(JSON.stringify(second)).not.toContain("Weekly");
  });

  it("reads the fake CLI through a PTY and keeps the screen out of the result", async () => {
    const dir = tempDir();
    writeFileSync(path.join(dir, "mode"), "usage");
    const previous = {
      anthropic: process.env.ANTHROPIC_API_KEY,
      openai: process.env.OPENAI_API_KEY,
      xai: process.env.XAI_API_KEY,
      base: process.env.OPENAI_BASE_URL,
    };
    process.env.ANTHROPIC_API_KEY = "SYNTHETIC_SECRET_SENTINEL";
    process.env.OPENAI_API_KEY = "SYNTHETIC_SECRET_SENTINEL";
    process.env.XAI_API_KEY = "SYNTHETIC_SECRET_SENTINEL";
    process.env.OPENAI_BASE_URL = "https://example.invalid/v1";
    try {
      const result = await runQuotaProbe({
        executable: fakeCli,
        profile: "fixture-v1",
        cwd: dir,
        deadlineMs: 60_000,
      });
      expect(result.ok).toBe(true);
      expect(result.isatty).toBe(true);
      expect(result.recognized).toBe(true);
      expect(result.sent).toEqual(["/usage"]);
      expect(result.state).toBe("parsed");
      expect(result.version).toBe("fixture-1.0.0");
      expect(result.deadlineMs).toBe(20_000);
      expect(result.childReaped).toBe(true);
      expect(result).not.toHaveProperty("screen");
      expect(result).not.toHaveProperty("stdout");
      const encoded = JSON.stringify(result);
      expect(encoded).not.toContain("Session");
      expect(encoded).not.toContain("10%");
      expect(encoded).not.toContain("SYNTHETIC_SECRET_SENTINEL");
      expect(encoded).not.toContain("\u001b");
      expect(readFileSync(path.join(dir, "tty-check"), "utf8")).toBe("1");
      expect(readFileSync(path.join(dir, "keystrokes"))).toEqual(Buffer.from("/usage\n"));
      const audit = readFileSync(path.join(dir, "env-audit"), "utf8");
      expect(audit).not.toContain("ANTHROPIC_API_KEY");
      expect(audit).not.toContain("OPENAI_BASE_URL");
      expect(audit).not.toContain("SYNTHETIC_SECRET_SENTINEL");
    } finally {
      restoreEnv("ANTHROPIC_API_KEY", previous.anthropic);
      restoreEnv("OPENAI_API_KEY", previous.openai);
      restoreEnv("XAI_API_KEY", previous.xai);
      restoreEnv("OPENAI_BASE_URL", previous.base);
    }
  });

  it("sends nothing to trust and redemption screens", async () => {
    for (const [mode, reason] of [
      ["trust", "trust_prompt"],
      ["redeem", "redemption_prompt"],
    ] as const) {
      const dir = tempDir();
      writeFileSync(path.join(dir, "mode"), mode);
      const result = await runQuotaProbe({
        executable: fakeCli,
        profile: "fixture-v1",
        cwd: dir,
        deadlineMs: 5_000,
      });
      expect(result.reason).toBe(reason);
      expect(result.sent).toEqual([]);
      expect(result.ok).toBe(false);
      expect(readFileSync(path.join(dir, "keystrokes"))).toEqual(Buffer.from(""));
    }
  });

  it("reaps a timed-out probe group within 22 seconds", async () => {
    const dir = tempDir();
    writeFileSync(path.join(dir, "mode"), "slow");
    const started = Date.now();
    const result = await runQuotaProbe({
      executable: fakeCli,
      profile: "fixture-v1",
      cwd: dir,
      deadlineMs: 2_000,
    });
    const elapsed = Date.now() - started;
    expect(result.reason).toBe("timeout");
    expect(result.sent).toEqual([]);
    expect(elapsed).toBeLessThanOrEqual(22_000);
    expect(elapsed).toBeLessThan(8_000);
    const pid = Number(readFileSync(path.join(dir, "pid"), "utf8"));
    const sleepPid = Number(readFileSync(path.join(dir, "sleep.pid"), "utf8"));
    await waitDead(pid);
    await waitDead(sleepPid);
    expect(alive(pid)).toBe(false);
    expect(alive(sleepPid)).toBe(false);
  });

  it("cancels an in-flight probe without leaving the child", async () => {
    const dir = tempDir();
    writeFileSync(path.join(dir, "mode"), "slow");
    const controller = new AbortController();
    const pending = runQuotaProbe({
      executable: fakeCli,
      profile: "fixture-v1",
      cwd: dir,
      deadlineMs: 20_000,
      signal: controller.signal,
    });
    const pid = Number(await waitForText(path.join(dir, "pid")));
    const sleepPid = Number(await waitForText(path.join(dir, "sleep.pid")));
    controller.abort();
    const started = Date.now();
    const result = await pending;
    expect(Date.now() - started).toBeLessThan(5_000);
    expect(result.reason).toBe("cancelled");
    expect(result.sent).toEqual([]);
    await waitDead(pid);
    await waitDead(sleepPid);
    expect(alive(pid)).toBe(false);
    expect(alive(sleepPid)).toBe(false);
  });

  it("does not launch an unsafe live profile or a relative executable", async () => {
    const dir = tempDir();
    writeFileSync(path.join(dir, "mode"), "usage");
    const unsafe = await runQuotaProbe({
      executable: fakeCli,
      profile: "claude",
      cwd: dir,
      deadlineMs: 2_000,
    });
    expect(unsafe.reason).toBe("profile_unsafe");
    expect(unsafe.sent).toEqual([]);
    expect(existsSync(path.join(dir, "pid"))).toBe(false);
    const relative = await runQuotaProbe({
      executable: "fake-cli.py",
      profile: "fixture-v1",
      cwd: dir,
      deadlineMs: 2_000,
    });
    expect(relative.reason).toBe("not_absolute");
    expect(existsSync(path.join(dir, "pid"))).toBe(false);
    chmodSync(dir, 0o777);
    const open = await runQuotaProbe({
      executable: fakeCli,
      profile: "fixture-v1",
      cwd: dir,
      deadlineMs: 2_000,
    });
    expect(open.reason).toBe("cwd_denied");
    expect(existsSync(path.join(dir, "pid"))).toBe(false);
  });

  it("reports a busy probe without starting the CLI", async () => {
    const dir = tempDir();
    writeFileSync(path.join(dir, "mode"), "usage");
    const lock = path.join(dir, "held.lock");
    const holder = spawn(
      venvPython,
      [
        "-c",
        "import fcntl,sys,time; fd=open(sys.argv[1],'a+'); fcntl.flock(fd, fcntl.LOCK_EX); sys.stdout.write('held\\n'); sys.stdout.flush(); time.sleep(20)",
        lock,
      ],
      { stdio: ["ignore", "pipe", "pipe"] },
    );
    try {
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("lock holder did not start")), 3_000);
        holder.stdout?.on("data", (chunk: Uint8Array) => {
          if (Buffer.from(chunk).toString("utf8").includes("held")) {
            clearTimeout(timer);
            resolve();
          }
        });
      });
      const result = await runQuotaProbe({
        executable: fakeCli,
        profile: "fixture-v1",
        cwd: dir,
        deadlineMs: 2_000,
        lockPath: lock,
      });
      expect(result.reason).toBe("probe_busy");
      expect(existsSync(path.join(dir, "pid"))).toBe(false);
    } finally {
      if (holder.pid) {
        try {
          process.kill(holder.pid, "SIGKILL");
        } catch {
          // The holder already exited.
        }
      }
    }
  });
});

function restoreEnv(name: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[name];
    return;
  }
  process.env[name] = value;
}
