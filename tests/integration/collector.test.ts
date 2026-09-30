import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { FIXTURE_NOW, fixtureIso, frozenClock, type ProviderId } from "@herdr/contracts";
import { collectFixtureQuota, createFixtureQuotaSource } from "../../apps/server/src/quota/source.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const clock = frozenClock(FIXTURE_NOW);
const HOUR = 60 * 60 * 1000;
const dirs: string[] = [];

function privateDir(mode: string | null = "usage"): string {
  const dir = mkdtempSync(path.join(tmpdir(), "herdr-quota-"));
  dirs.push(dir);
  if (mode !== null) writeFileSync(path.join(dir, "mode"), mode);
  return dir;
}

function executable(name: string): string {
  return path.join(repoRoot, "tests", "helpers", name);
}

function killRecorded(dir: string): void {
  const file = path.join(dir, "pid");
  if (!existsSync(file)) return;
  const pid = Number(readFileSync(file, "utf8").trim());
  if (!Number.isInteger(pid) || pid <= 1) return;
  try {
    process.kill(pid, "SIGKILL");
  } catch {
    // The probe already reaped this synthetic CLI.
  }
}

afterEach(() => {
  for (const dir of dirs.splice(0)) {
    killRecorded(dir);
    rmSync(dir, { recursive: true, force: true });
  }
});

async function collect(provider: ProviderId, program: string, mode: string, deadlineMs = 8_000) {
  const cwd = privateDir(mode);
  const started = Date.now();
  const quota = await collectFixtureQuota(
    { provider, executable: executable(program), cwd, deadlineMs },
    clock,
  );
  return { cwd, quota, elapsed: Date.now() - started };
}

describe("fixture quota collectors", () => {
  it("reads Claude, Codex, and Grok through real PTYs", async () => {
    const claude = await collect("claude", "fake-claude.py", "usage");
    const codex = await collect("codex", "fake-codex.py", "usage");
    const grok = await collect("grok", "fake-grok.py", "usage");

    expect(claude.elapsed).toBeLessThan(8_000);
    expect(codex.elapsed).toBeLessThan(8_000);
    expect(grok.elapsed).toBeLessThan(8_000);
    expect(readFileSync(path.join(claude.cwd, "tty-check"), "utf8")).toBe("1");
    expect(readFileSync(path.join(claude.cwd, "keystrokes"))).toEqual(Buffer.from("/usage\n"));
    expect(readFileSync(path.join(grok.cwd, "keystrokes"))).toEqual(Buffer.from("/usage\n"));
    expect(readFileSync(path.join(codex.cwd, "keystrokes"))).toEqual(Buffer.from("/status\n\x1b/usage\n"));
    for (const dir of [claude.cwd, codex.cwd, grok.cwd]) {
      const keys = readFileSync(path.join(dir, "keystrokes")).toString("utf8").toLowerCase();
      expect(keys).not.toContain("redeem");
      expect(keys).not.toContain("apply");
      expect(keys).not.toContain("confirm");
      expect(keys).not.toContain("y");
    }

    expect(claude.quota.windows.map((window) => [window.kind, window.usedPercent, window.resetRaw])).toEqual([
      ["five_hour", 10, "in 4h"],
      ["weekly", 20, "in 36h"],
    ]);
    expect(claude.quota.windows.find((window) => window.kind === "five_hour")?.resetsAt).toBe(fixtureIso(4 * HOUR));
    expect(claude.quota.bankedStatus).toBe("not_applicable");
    expect(codex.quota.windows.map((window) => [window.kind, window.usedPercent, window.remainingPercent, window.resetRaw])).toEqual([
      ["five_hour", 35, 65, "in 4h"],
      ["weekly", 25, 75, "in 37h"],
    ]);
    expect(codex.quota.bankedStatus).toBe("known");
    expect(codex.quota.bankedResets?.map((reset) => [reset.id, reset.quantity, reset.earnedAt, reset.expiresAt, reset.eligibility])).toEqual([
      ["codex-reset-expiring", 1, null, fixtureIso(24 * HOUR), "eligible"],
      ["codex-reset-unusable", 1, null, fixtureIso(24 * HOUR), "ineligible"],
    ]);
    expect(grok.quota.windows.map((window) => [window.kind, window.availability, window.usedPercent])).toEqual([
      ["five_hour", "not_applicable", null],
      ["weekly", "known", 15],
    ]);
    for (const quota of [claude.quota, codex.quota, grok.quota]) {
      expect(quota.health).toMatchObject({ status: "ok", parserVersion: "quota-1", cliVersion: "fixture-1", provenance: "fixture" });
      const encoded = JSON.stringify(quota);
      expect(encoded).not.toContain("SYNTHETIC");
      expect(encoded).not.toContain("65% left");
      expect(encoded).not.toContain("Current session");
      expect(encoded).not.toContain("Earned resets");
    }
  });

  it("keeps a known empty inventory distinct from a redemption trap", async () => {
    const empty = await collect("codex", "fake-codex.py", "none");
    expect(empty.quota.bankedStatus).toBe("known");
    expect(empty.quota.bankedResets).toEqual([]);
    expect(empty.quota.windows.find((window) => window.kind === "five_hour")?.usedPercent).toBe(35);
    expect(empty.quota.health.status).toBe("ok");

    const trapped = await collect("codex", "fake-codex.py", "redeem");
    expect(readFileSync(path.join(trapped.cwd, "keystrokes"))).toEqual(Buffer.from("/status\n\x1b/usage\n"));
    expect(trapped.quota.bankedStatus).toBe("unknown");
    expect(trapped.quota.bankedResets).toBeNull();
    expect(trapped.quota.windows.find((window) => window.kind === "five_hour")?.usedPercent).toBe(35);
    expect(trapped.quota.health).toMatchObject({ status: "unsupported", reasonCode: "redemption_prompt" });
    expect(JSON.stringify(trapped.quota)).not.toContain("codex-reset-expiring");
  });

  it("reports login and an unsafe live profile without treating either as quota", async () => {
    const login = await collect("claude", "fake-claude.py", "login", 5_000);
    expect(readFileSync(path.join(login.cwd, "keystrokes"))).toEqual(Buffer.from(""));
    expect(login.quota.health).toMatchObject({ status: "not_authenticated", reasonCode: "login_required" });
    expect(login.quota.windows.every((window) => window.availability === "unknown" && window.usedPercent === null)).toBe(true);

    const cwd = privateDir("usage");
    const source = createFixtureQuotaSource(
      { claude: { executable: executable("fake-claude.py"), cwd, profile: "claude", deadlineMs: 2_000 } },
      clock,
    );
    const quota = await source.collect("claude", new AbortController().signal);
    expect(quota.health).toMatchObject({ status: "unsupported", reasonCode: "profile_unsafe", provenance: "live" });
    expect(quota.windows.every((window) => window.usedPercent === null)).toBe(true);
    expect(existsSync(path.join(cwd, "pid"))).toBe(false);

    const missing = createFixtureQuotaSource({}, clock);
    const absent = await missing.collect("grok", new AbortController().signal);
    expect(absent.health).toMatchObject({ status: "missing", reasonCode: "cli_missing", provenance: "fixture" });
    expect(absent.bankedStatus).toBe("unknown");
    expect(absent.bankedResets).toBeNull();
  });
});
