import { mkdtempSync, rmSync } from "node:fs";
import type { Server } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { once } from "node:events";
import http from "node:http";
import {
  FIXTURE_NOW,
  agentSessionSchema,
  fixtureIso,
  gitWorktreeSchema,
  providerQuotaSchema,
  scenarios,
  sourceHealthSchema,
  type AgentSession,
  type DashboardSnapshot,
  type GitSource,
  type GitWorktree,
  type ProviderId,
  type ProviderQuota,
  type QuotaSource,
  type SessionSource,
  type SourceHealth,
  type SourceStatus,
} from "@herdr/contracts";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { loadConfig } from "../../apps/server/src/config.js";
import { createDashboardServer, SSE_BUFFER_LIMIT, SSE_HEARTBEAT_MS } from "../../apps/server/src/http.js";
import {
  createManualClock,
  createRuntimeCollectors,
  createScheduler,
  type Scheduler,
} from "../../apps/server/src/scheduler.js";
import {
  GIT_TTL_MS,
  QUOTA_TTL_MS,
  SESSION_TTL_MS,
  type SnapshotHub,
} from "../../apps/server/src/services/snapshot.js";
import { openStore, type DashboardStore } from "../../apps/server/src/storage/repository.js";

const T0 = FIXTURE_NOW;
const T1 = fixtureIso(60_000);
const HOUR = { sessionsSeconds: 3600, gitSeconds: 3600, quotaSeconds: 3600 };

function sourceHealth(sourceId: string, status: SourceStatus, checkedAt: string, lastSuccessAt: string | null): SourceHealth {
  return sourceHealthSchema.parse({
    sourceId,
    status,
    checkedAt,
    lastSuccessAt,
    reasonCode: status === "ok" ? "ok" : status,
    cliVersion: status === "ok" ? "fixture-1" : null,
    parserVersion: "quota-1",
    provenance: "fixture",
  });
}

function quotaOf(provider: ProviderId, used: number, sampledAt: string, status: SourceStatus, checkedAt = sampledAt): ProviderQuota {
  return providerQuotaSchema.parse({
    provider,
    windows: [
      {
        kind: "five_hour",
        scope: "all",
        availability: "known",
        usedPercent: used,
        remainingPercent: 100 - used,
        resetsAt: null,
        resetRaw: null,
        sourceTimezone: "America/New_York",
        sampledAt,
        confidence: "exact",
      },
    ],
    bankedResets: null,
    bankedStatus: "not_applicable",
    health: sourceHealth(`${provider}-quota`, status, checkedAt, status === "ok" ? sampledAt : null),
  });
}

function sessionOf(observedAt: string, label: string): AgentSession {
  const base = scenarios.daily.sessions[0];
  if (!base) throw new Error("missing fixture session");
  return agentSessionSchema.parse({ ...base, id: "herdr:fixture:cadence", observedAt, label });
}

function worktreeOf(observedAt: string): GitWorktree {
  const base = scenarios.daily.worktrees[0];
  if (!base) throw new Error("missing fixture worktree");
  return gitWorktreeSchema.parse({
    ...base,
    observedAt,
    health: { ...base.health, checkedAt: observedAt, lastSuccessAt: observedAt },
  });
}

function okSessions(observedAt = T0): SessionSource {
  return {
    async collect() {
      return {
        sessions: [sessionOf(observedAt, "fresh")],
        health: sourceHealth("herdr", "ok", observedAt, observedAt),
      };
    },
  };
}

function okTmux(observedAt = T0): SessionSource {
  return {
    async collect() {
      return { sessions: [], health: sourceHealth("tmux", "ok", observedAt, observedAt) };
    },
  };
}

function okGit(observedAt = T0): GitSource {
  return {
    async collect() {
      return {
        worktrees: [worktreeOf(observedAt)],
        health: sourceHealth("git", "ok", observedAt, observedAt),
      };
    },
  };
}

function okQuota(sampledAt = T0, used = 10): QuotaSource {
  return {
    async collect(provider) {
      return quotaOf(provider, used, sampledAt, "ok");
    },
  };
}

interface Harness {
  clock: ReturnType<typeof createManualClock>;
  store: DashboardStore;
  scheduler: Scheduler;
  close: () => Promise<void>;
}

function harness(options: {
  poll?: { sessionsSeconds: number; gitSeconds: number; quotaSeconds: number };
  quota?: QuotaSource;
  herdr?: SessionSource;
  tmux?: SessionSource;
  git?: GitSource;
  mode?: "passive" | "live" | "fixture";
  probesEnabled?: boolean;
  roots?: string[];
}): Harness {
  const clock = createManualClock(FIXTURE_NOW);
  const dir = mkdtempSync(path.join(tmpdir(), "herdr-scheduler-"));
  const store = openStore({ file: path.join(dir, "dashboard.sqlite"), clock });
  const scheduler = createScheduler({
    clock,
    store,
    mode: options.mode ?? "passive",
    poll: options.poll ?? { sessionsSeconds: 10, gitSeconds: 30, quotaSeconds: 300 },
    quota: options.quota ?? okQuota(),
    herdr: options.herdr ?? okSessions(),
    tmux: options.tmux ?? okTmux(),
    git: options.git ?? okGit(),
    roots: options.roots ?? [],
    probesEnabled: options.probesEnabled === true,
  });
  return {
    clock,
    store,
    scheduler,
    async close() {
      await scheduler.stop();
      store.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

async function waitFor(check: () => boolean): Promise<void> {
  const deadline = Date.now() + 2_000;
  while (!check()) {
    if (Date.now() > deadline) throw new Error("timed out waiting for scheduler");
    await new Promise((resolve) => setImmediate(resolve));
  }
}

async function closeServer(server: Server): Promise<void> {
  if (!server.listening) return;
  await new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

describe("scheduler", () => {
  it("collects at startup and again on the exact poll boundary", async () => {
    let sessions = 0;
    let git = 0;
    let quota = 0;
    const poll = { sessionsSeconds: 10, gitSeconds: 30, quotaSeconds: 3600 };
    const box = harness({
      poll,
      herdr: {
        async collect() {
          sessions += 1;
          return { sessions: [sessionOf(T0, "fresh")], health: sourceHealth("herdr", "ok", T0, T0) };
        },
      },
      tmux: okTmux(),
      git: {
        async collect() {
          git += 1;
          return { worktrees: [worktreeOf(T0)], health: sourceHealth("git", "ok", T0, T0) };
        },
      },
      quota: {
        async collect(provider) {
          quota += 1;
          return quotaOf(provider, 10, T0, "ok");
        },
      },
    });
    try {
      poll.sessionsSeconds = 1;
      await box.scheduler.start();
      expect(sessions).toBe(1);
      expect(git).toBe(1);
      expect(quota).toBe(3);
      const firstSequence = box.scheduler.current().sequence;
      expect(firstSequence).toBeGreaterThan(0);
      expect(box.scheduler.current().alerts).toEqual([]);
      expect(box.scheduler.current().providers.map((provider) => provider.provider)).toEqual(["claude", "codex", "grok"]);

      await box.clock.advance(9_999);
      expect(sessions).toBe(1);
      expect(git).toBe(1);
      await box.clock.advance(1);
      expect(sessions).toBe(2);
      expect(git).toBe(1);
      await box.clock.advance(19_999);
      expect(sessions).toBe(3);
      expect(git).toBe(1);
      await box.clock.advance(1);
      expect(sessions).toBe(4);
      expect(git).toBe(2);
      expect(quota).toBe(3);
      expect(box.scheduler.current().sequence).toBeGreaterThan(firstSequence);
    } finally {
      await box.close();
    }
  });

  it("backs off quota failures by 5, 10, 20, and 30 minutes, then returns to the configured interval", async () => {
    let claudeCalls = 0;
    const box = harness({
      poll: { sessionsSeconds: 3600, gitSeconds: 3600, quotaSeconds: 3600 },
      quota: {
        async collect(provider) {
          if (provider !== "claude") return quotaOf(provider, 10, T0, "ok");
          claudeCalls += 1;
          if (claudeCalls < 5) return quotaOf(provider, 99, T1, "timeout", T1);
          return quotaOf(provider, 10, T0, "ok");
        },
      },
    });
    try {
      await box.scheduler.start();
      expect(claudeCalls).toBe(1);
      await box.clock.advance(5 * 60_000 - 1);
      expect(claudeCalls).toBe(1);
      await box.clock.advance(1);
      expect(claudeCalls).toBe(2);
      await box.clock.advance(10 * 60_000 - 1);
      expect(claudeCalls).toBe(2);
      await box.clock.advance(1);
      expect(claudeCalls).toBe(3);
      await box.clock.advance(20 * 60_000);
      expect(claudeCalls).toBe(4);
      await box.clock.advance(30 * 60_000);
      expect(claudeCalls).toBe(5);
      await box.clock.advance(30 * 60_000);
      expect(claudeCalls).toBe(5);
      await box.clock.advance(30 * 60_000);
      expect(claudeCalls).toBe(6);
    } finally {
      await box.close();
    }
  });

  it("backs off session failures up to 60 seconds and resets after success", async () => {
    let calls = 0;
    const box = harness({
      poll: { sessionsSeconds: 10, gitSeconds: 3600, quotaSeconds: 3600 },
      herdr: {
        async collect() {
          calls += 1;
          const status: SourceStatus = calls < 5 ? "timeout" : "ok";
          return {
            sessions: [],
            health: sourceHealth("herdr", status, T0, status === "ok" ? T0 : null),
          };
        },
      },
    });
    try {
      await box.scheduler.start();
      expect(calls).toBe(1);
      await box.clock.advance(10_000 - 1);
      expect(calls).toBe(1);
      await box.clock.advance(1);
      expect(calls).toBe(2);
      await box.clock.advance(20_000 - 1);
      expect(calls).toBe(2);
      await box.clock.advance(1);
      expect(calls).toBe(3);
      await box.clock.advance(40_000 - 1);
      expect(calls).toBe(3);
      await box.clock.advance(1);
      expect(calls).toBe(4);
      await box.clock.advance(60_000 - 1);
      expect(calls).toBe(4);
      await box.clock.advance(1);
      expect(calls).toBe(5);
      await box.clock.advance(10_000 - 1);
      expect(calls).toBe(5);
      await box.clock.advance(1);
      expect(calls).toBe(6);
    } finally {
      await box.close();
    }
  });

  it("keeps going when a collector throws and still uses the git interval", async () => {
    let calls = 0;
    const box = harness({
      poll: { sessionsSeconds: 3600, gitSeconds: 30, quotaSeconds: 3600 },
      git: {
        async collect() {
          calls += 1;
          throw new Error("git failed");
        },
      },
    });
    try {
      await box.scheduler.start();
      expect(calls).toBe(1);
      await box.clock.advance(29_999);
      expect(calls).toBe(1);
      await box.clock.advance(1);
      expect(calls).toBe(2);
      expect(box.scheduler.current().worktrees).toEqual([]);
    } finally {
      await box.close();
    }
  });

  it("never overlaps quota probes", async () => {
    let open = 0;
    let maxOpen = 0;
    const events: string[] = [];
    let hold: (() => void) | null = null;
    const box = harness({
      poll: HOUR,
      quota: {
        async collect(provider) {
          open += 1;
          maxOpen = Math.max(maxOpen, open);
          events.push(`start ${provider}`);
          try {
            if (provider === "claude" && hold === null) {
              await new Promise<void>((resolve) => {
                hold = resolve;
              });
            }
            return quotaOf(provider, 10, T0, "ok");
          } finally {
            open -= 1;
            events.push(`end ${provider}`);
          }
        },
      },
    });
    try {
      const first = box.scheduler.collectQuotas();
      const second = box.scheduler.collectQuotas();
      await waitFor(() => events[0] === "start claude");
      expect(events).toEqual(["start claude"]);
      expect(maxOpen).toBe(1);
      if (!hold) throw new Error("quota probe was not held");
      (hold as () => void)();
      await first;
      await second;
      expect(maxOpen).toBe(1);
      const firstGrok = events.indexOf("end grok");
      const secondClaude = events.indexOf("start claude", 1);
      expect(firstGrok).toBeGreaterThan(0);
      expect(secondClaude).toBeGreaterThan(firstGrok);
    } finally {
      await box.close();
    }
  });

  it("keeps the original sampledAt when a later probe fails", async () => {
    let round = 0;
    const box = harness({
      poll: { sessionsSeconds: 3600, gitSeconds: 3600, quotaSeconds: 300 },
      quota: {
        async collect(provider) {
          if (provider !== "claude") return quotaOf(provider, 5, T0, "ok");
          round += 1;
          if (round === 1) return quotaOf("claude", 10, T0, "ok");
          return quotaOf("claude", 99, T1, "timeout", T1);
        },
      },
    });
    try {
      await box.scheduler.start();
      await box.clock.advance(300_000);
      const stored = box.store.latestQuota("claude");
      const snapshot = box.scheduler.current();
      const claude = snapshot.providers.find((provider) => provider.provider === "claude");
      expect(stored?.windows[0]?.sampledAt).toBe(T0);
      expect(stored?.windows[0]?.usedPercent).toBe(10);
      expect(claude?.windows[0]?.sampledAt).toBe(T0);
      expect(claude?.windows[0]?.usedPercent).toBe(10);
      expect(claude?.health.status).toBe("timeout");
      expect(claude?.health.lastSuccessAt).toBe(T0);
      expect(JSON.stringify(claude?.windows)).not.toContain(T1);
    } finally {
      await box.close();
    }
  });

  it("does not let an older observation replace a newer one", async () => {
    let quotaRound = 0;
    let sessionRound = 0;
    const box = harness({
      poll: { sessionsSeconds: 10, gitSeconds: 3600, quotaSeconds: 300 },
      quota: {
        async collect(provider) {
          if (provider !== "claude") return quotaOf(provider, 5, T1, "ok", T1);
          quotaRound += 1;
          return quotaRound === 1 ? quotaOf("claude", 10, T1, "ok", T1) : quotaOf("claude", 90, T0, "ok", T0);
        },
      },
      herdr: {
        async collect() {
          sessionRound += 1;
          const observedAt = sessionRound === 1 ? T1 : T0;
          const label = sessionRound === 1 ? "newer" : "older";
          return {
            sessions: [sessionOf(observedAt, label)],
            health: sourceHealth("herdr", "ok", observedAt, observedAt),
          };
        },
      },
    });
    try {
      await box.scheduler.start();
      await box.clock.advance(10_000);
      expect(box.scheduler.current().sessions[0]?.label).toBe("newer");
      expect(box.scheduler.current().sessions[0]?.observedAt).toBe(T1);
      await box.clock.advance(290_000);
      const claude = box.scheduler.current().providers.find((provider) => provider.provider === "claude");
      expect(claude?.windows[0]?.usedPercent).toBe(10);
      expect(claude?.windows[0]?.sampledAt).toBe(T1);
      expect(box.scheduler.current().sessions[0]?.label).toBe("newer");
    } finally {
      await box.close();
    }
  });

  it("marks quota, session, and git data stale only after the TTL", async () => {
    const box = harness({
      poll: HOUR,
      quota: okQuota(T0, 10),
      herdr: okSessions(T0),
      tmux: okTmux(T0),
      git: okGit(T0),
    });
    try {
      await box.scheduler.start();
      const sequence = box.scheduler.current().sequence;
      await box.scheduler.stop();
      await box.clock.advance(SESSION_TTL_MS);
      expect(box.scheduler.current().sources.find((source) => source.sourceId === "herdr")?.status).toBe("ok");
      await box.clock.advance(1);
      const sessions = box.scheduler.current();
      expect(sessions.sources.find((source) => source.sourceId === "herdr")?.status).toBe("stale");
      expect(sessions.sources.find((source) => source.sourceId === "herdr")?.reasonCode).toBe("session_ttl_exceeded");
      expect(sessions.sources.find((source) => source.sourceId === "git")?.status).toBe("ok");
      expect(sessions.sessions[0]?.observedAt).toBe(T0);
      await box.clock.advance(GIT_TTL_MS - SESSION_TTL_MS - 1);
      expect(box.scheduler.current().sources.find((source) => source.sourceId === "git")?.status).toBe("ok");
      expect(box.scheduler.current().worktrees[0]?.health.status).toBe("ok");
      await box.clock.advance(1);
      const git = box.scheduler.current();
      expect(git.sources.find((source) => source.sourceId === "git")?.status).toBe("stale");
      expect(git.sources.find((source) => source.sourceId === "git")?.reasonCode).toBe("git_ttl_exceeded");
      expect(git.worktrees[0]?.observedAt).toBe(T0);
      expect(git.worktrees[0]?.health.status).toBe("stale");
      const elapsed = GIT_TTL_MS + 1;
      expect(box.scheduler.current().providers[0]?.health.status).toBe("ok");
      await box.clock.advance(QUOTA_TTL_MS - elapsed);
      expect(box.scheduler.current().providers[0]?.health.status).toBe("ok");
      await box.clock.advance(1);
      const quota = box.scheduler.current();
      expect(quota.providers[0]?.health.status).toBe("stale");
      expect(quota.providers[0]?.health.reasonCode).toBe("quota_ttl_exceeded");
      expect(quota.providers[0]?.windows[0]?.sampledAt).toBe(T0);
      expect(quota.providers[0]?.windows[0]?.usedPercent).toBe(10);
      expect(quota.sequence).toBe(sequence);
      expect(quota.generatedAt).toBe(T0);
    } finally {
      await box.close();
    }
  });

  it("answers GET /api/snapshot while a quota collect is still running", async () => {
    let release: ((value: ProviderQuota) => void) | null = null;
    const box = harness({
      poll: HOUR,
      probesEnabled: false,
      quota: {
        collect(provider, signal) {
          if (provider !== "claude") return Promise.resolve(quotaOf(provider, 10, T0, "ok"));
          return new Promise((resolve) => {
            release = resolve;
            signal.addEventListener("abort", () => resolve(quotaOf(provider, 10, T0, "timeout", T0)), { once: true });
          });
        },
      },
    });
    const server = createDashboardServer({
      host: "127.0.0.1",
      port: 0,
      webDist: path.resolve("apps/web/dist"),
      mode: "passive",
      snapshots: box.scheduler,
    });
    const starting = box.scheduler.start();
    try {
      await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      const began = Date.now();
      const response = await fetch(`http://127.0.0.1:${port}/api/snapshot`);
      const elapsed = Date.now() - began;
      const body = (await response.json()) as DashboardSnapshot;
      expect(response.status).toBe(200);
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(elapsed).toBeLessThan(500);
      expect(body.schemaVersion).toBe(1);
      expect(body.providers).toHaveLength(3);
      expect(release).not.toBeNull();
    } finally {
      await box.scheduler.stop();
      await starting;
      await closeServer(server);
      await box.close();
    }
  });

  it("stops owned collection when the scheduler shuts down", async () => {
    let calls = 0;
    const box = harness({
      poll: { sessionsSeconds: 10, gitSeconds: 30, quotaSeconds: 300 },
      herdr: {
        collect(signal) {
          calls += 1;
          return new Promise((resolve) => {
            const finish = (): void => {
              resolve({ sessions: [], health: sourceHealth("herdr", "missing", T0, null) });
            };
            if (signal.aborted) {
              finish();
              return;
            }
            signal.addEventListener("abort", finish, { once: true });
          });
        },
      },
      tmux: {
        collect(signal) {
          return new Promise((resolve) => {
            if (signal.aborted) {
              resolve({ sessions: [], health: sourceHealth("tmux", "missing", T0, null) });
              return;
            }
            signal.addEventListener(
              "abort",
              () => resolve({ sessions: [], health: sourceHealth("tmux", "missing", T0, null) }),
              { once: true },
            );
          });
        },
      },
      git: {
        collect(_roots, signal) {
          return new Promise((resolve) => {
            if (signal.aborted) {
              resolve({ worktrees: [], health: sourceHealth("git", "missing", T0, null) });
              return;
            }
            signal.addEventListener(
              "abort",
              () => resolve({ worktrees: [], health: sourceHealth("git", "missing", T0, null) }),
              { once: true },
            );
          });
        },
      },
      quota: {
        collect(provider, signal) {
          return new Promise((resolve) => {
            if (signal.aborted) {
              resolve(quotaOf(provider, 10, T0, "timeout", T0));
              return;
            }
            signal.addEventListener("abort", () => resolve(quotaOf(provider, 10, T0, "timeout", T0)), { once: true });
          });
        },
      },
    });
    const starting = box.scheduler.start();
    try {
      await waitFor(() => calls === 1);
      const began = Date.now();
      await box.scheduler.stop();
      await starting;
      expect(Date.now() - began).toBeLessThan(500);
      await box.clock.advance(120_000);
      expect(calls).toBe(1);
    } finally {
      await box.close();
    }
  });

  it("serves fixture data from the synthetic catalog without host collectors", async () => {
    const example = JSON.parse(readFileSync(path.resolve("config/dashboard.example.json"), "utf8")) as unknown;
    const config = loadConfig(example, { HERDR_FIXTURE: "1" });
    const clock = createManualClock(FIXTURE_NOW);
    const collectors = createRuntimeCollectors({ config, mode: "fixture", clock });
    const box = harness({
      mode: "fixture",
      probesEnabled: false,
      poll: { sessionsSeconds: 10, gitSeconds: 30, quotaSeconds: 300 },
      quota: collectors.quota,
      herdr: collectors.herdr,
      tmux: collectors.tmux,
      git: collectors.git,
    });
    try {
      const disabled = createRuntimeCollectors({
        config: loadConfig(example, {}),
        mode: "passive",
        clock,
      });
      const passive = await disabled.quota.collect("claude", new AbortController().signal);
      expect(passive.health.status).toBe("disabled");
      expect(passive.health.reasonCode).toBe("probes_disabled");
      const unsafeConfig = loadConfig({ ...(example as object), quotaProbesEnabled: true, mode: "live" }, {});
      const unsafe = createRuntimeCollectors({ config: unsafeConfig, mode: "live", clock });
      const refused = await unsafe.quota.collect("codex", new AbortController().signal);
      expect(refused.health.status).toBe("unsupported");
      expect(refused.health.reasonCode).toBe("profile_unsafe");

      await box.scheduler.start();
      const snapshot = box.scheduler.current();
      expect(snapshot.mode).toBe("fixture");
      expect(snapshot.providers.map((provider) => provider.provider)).toEqual(["claude", "codex", "grok"]);
      const claude = snapshot.providers[0];
      const codex = snapshot.providers[1];
      const grok = snapshot.providers[2];
      expect(claude?.windows.find((window) => window.kind === "five_hour")?.usedPercent).toBe(10);
      expect(codex?.bankedStatus).toBe("known");
      expect(codex?.bankedResets).toHaveLength(2);
      expect(grok?.windows.find((window) => window.kind === "five_hour")?.availability).toBe("not_applicable");
      expect(snapshot.worktrees[0]?.path).toBe("/work/demo");
      expect(snapshot.providers.every((provider) => provider.health.provenance === "fixture")).toBe(true);
      expect(snapshot.sources.every((source) => source.provenance === "fixture")).toBe(true);
    } finally {
      await box.close();
    }
  });

  it("streams a snapshot event and a heartbeat without buffering forever", async () => {
    expect(SSE_HEARTBEAT_MS).toBe(15_000);
    expect(SSE_BUFFER_LIMIT).toBe(64 * 1024);
    let sequence = scenarios.daily.sequence;
    const listeners = new Set<(snapshot: DashboardSnapshot) => void>();
    const hub: SnapshotHub = {
      current() {
        return { ...scenarios.daily, sequence };
      },
      subscribe(listener) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
    };
    const server = createDashboardServer({
      host: "127.0.0.1",
      port: 0,
      webDist: path.resolve("apps/web/dist"),
      mode: "fixture",
      snapshots: hub,
      heartbeatMs: 30,
      bufferLimit: 1024,
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
    const address = server.address();
    const port = typeof address === "object" && address ? address.port : 0;
    const req = http.request({ host: "127.0.0.1", port, path: "/api/events", method: "GET" });
    req.end();
    const response = await once(req, "response");
    const res = response[0] as http.IncomingMessage;
    let text = "";
    res.on("data", (chunk: Buffer) => {
      text += chunk.toString("utf8");
    });
    try {
      const deadline = Date.now() + 1_000;
      while (!text.includes(": heartbeat") && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      expect(text).toContain("event: snapshot");
      expect(text).toContain(`id: ${scenarios.daily.sequence}`);
      expect(text).toContain(": heartbeat");
      res.pause();
      const ended = once(res, "end");
      for (let index = 0; index < 80 && !res.complete; index += 1) {
        sequence += 1;
        const snapshot = { ...scenarios.daily, sequence };
        for (const listener of listeners) listener(snapshot);
      }
      await Promise.race([
        ended,
        new Promise((resolve) => setTimeout(resolve, 500)),
      ]);
      expect(res.complete || res.destroyed).toBe(true);
    } finally {
      req.destroy();
      await closeServer(server);
    }
  });
});
