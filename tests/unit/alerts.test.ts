import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  FIXTURE_NOW,
  fixtureIso,
  idleSeed,
  scenarios,
  sourceHealthSchema,
  type Alert,
  type AlertCoverage,
  type BankedReset,
  type DashboardSnapshot,
  type ProviderId,
  type ProviderQuota,
  type QuotaWindow,
} from "@herdr/contracts";
import { describe, expect, it } from "vitest";
import { createAlertEngine, sessionCoverage } from "../../apps/server/src/services/alerts.js";
import { createManualClock, createScheduler } from "../../apps/server/src/scheduler.js";
import { openStore } from "../../apps/server/src/storage/repository.js";

const NOW = new Date(FIXTURE_NOW);
const HOUR = 60 * 60 * 1000;
const FORTY_EIGHT_HOURS = 48 * HOUR;
const TEN_MINUTES = 10 * 60 * 1000;
const READY: AlertCoverage = { sessionsFresh: true, sessionsComplete: true };
const CAPACITY = new Set<Alert["kind"]>([
  "window_open_idle",
  "weekly_reset_underused",
  "banked_reset_unusable_before_expiry",
  "banked_reset_expiring",
]);

function freshen(snapshot: DashboardSnapshot, iso: string): DashboardSnapshot {
  const next = structuredClone(snapshot);
  next.generatedAt = iso;
  for (const provider of next.providers) {
    provider.health.checkedAt = iso;
    if (provider.health.lastSuccessAt !== null) provider.health.lastSuccessAt = iso;
    for (const window of provider.windows) window.sampledAt = iso;
    for (const reset of provider.bankedResets ?? []) reset.sampledAt = iso;
  }
  for (const source of next.sources) {
    source.checkedAt = iso;
    if (source.lastSuccessAt !== null) source.lastSuccessAt = iso;
  }
  for (const session of next.sessions) session.observedAt = iso;
  for (const worktree of next.worktrees) {
    worktree.observedAt = iso;
    worktree.health.checkedAt = iso;
    if (worktree.health.lastSuccessAt !== null) worktree.health.lastSuccessAt = iso;
  }
  return next;
}

function provider(snapshot: DashboardSnapshot, name: ProviderId): ProviderQuota {
  const quota = snapshot.providers.find((item) => item.provider === name);
  if (!quota) throw new Error(`missing ${name}`);
  return quota;
}

function windowOf(quota: ProviderQuota, kind: QuotaWindow["kind"], scope = "all"): QuotaWindow {
  const window = quota.windows.find((item) => item.kind === kind && item.scope === scope);
  if (!window) throw new Error(`missing ${quota.provider} ${kind} ${scope}`);
  return window;
}

function resetOf(quota: ProviderQuota, id: string): BankedReset {
  const reset = quota.bankedResets?.find((item) => item.id === id);
  if (!reset) throw new Error(`missing reset ${id}`);
  return reset;
}

function ids(alerts: readonly Alert[], kind?: Alert["kind"]): string[] {
  return alerts.filter((alert) => kind === undefined || alert.kind === kind).map((alert) => alert.id);
}

function capacity(alerts: readonly Alert[]): Alert[] {
  return alerts.filter((alert) => CAPACITY.has(alert.kind));
}

describe("alert rules", () => {
  it("emits the daily weekly and banked alerts and no idle alert", () => {
    const alerts = createAlertEngine().evaluate(scenarios.daily, NOW, sessionCoverage(scenarios.daily));
    expect(ids(alerts, "weekly_reset_underused")).toEqual([
      "weekly_reset_underused:claude:weekly:all",
      "weekly_reset_underused:codex:weekly:all",
      "weekly_reset_underused:grok:weekly:all",
    ]);
    expect(ids(alerts, "banked_reset_expiring")).toEqual(["banked_reset_expiring:codex:codex-reset-expiring"]);
    expect(ids(alerts, "banked_reset_unusable_before_expiry")).toEqual([
      "banked_reset_unusable_before_expiry:codex:codex-reset-unusable",
    ]);
    expect(ids(alerts, "window_open_idle")).toEqual([]);
    expect(ids(alerts, "source_problem")).toEqual([]);
    const expiring = alerts.find((alert) => alert.kind === "banked_reset_expiring");
    const unusable = alerts.find((alert) => alert.kind === "banked_reset_unusable_before_expiry");
    expect(expiring?.message).toContain("expires soon");
    expect(expiring?.message).not.toContain("cannot be used");
    expect(expiring?.message).not.toContain("eligibility unknown");
    expect(unusable?.message).toContain("cannot be used before expiry");
    expect(unusable?.message).toContain("redeemable only after expiry");
    expect(alerts.map((alert) => alert.id)).toEqual([
      "weekly_reset_underused:claude:weekly:all",
      "weekly_reset_underused:codex:weekly:all",
      "weekly_reset_underused:grok:weekly:all",
      "banked_reset_unusable_before_expiry:codex:codex-reset-unusable",
      "banked_reset_expiring:codex:codex-reset-expiring",
    ]);
  });

  it("does not treat a 48 hour reset as underused and does one millisecond inside the window", () => {
    const engine = createAlertEngine();
    const exact = structuredClone(scenarios.daily);
    for (const name of ["claude", "codex", "grok"] as const) {
      const weekly = windowOf(provider(exact, name), "weekly");
      weekly.resetsAt = fixtureIso(FORTY_EIGHT_HOURS);
    }
    expect(ids(engine.evaluate(exact, NOW, READY), "weekly_reset_underused")).toEqual([]);

    const inside = structuredClone(exact);
    for (const name of ["claude", "codex", "grok"] as const) {
      windowOf(provider(inside, name), "weekly").resetsAt = fixtureIso(FORTY_EIGHT_HOURS - 1);
    }
    expect(ids(engine.evaluate(inside, NOW, READY), "weekly_reset_underused")).toHaveLength(3);

    const banked = structuredClone(scenarios.daily);
    const expiring = resetOf(provider(banked, "codex"), "codex-reset-expiring");
    expiring.expiresAt = fixtureIso(FORTY_EIGHT_HOURS);
    expiring.redeemableAt = fixtureIso(HOUR);
    expect(ids(engine.evaluate(banked, NOW, READY), "banked_reset_expiring")).toEqual([]);
    expiring.expiresAt = fixtureIso(FORTY_EIGHT_HOURS - 1);
    expect(ids(engine.evaluate(banked, NOW, READY), "banked_reset_expiring")).toEqual([
      "banked_reset_expiring:codex:codex-reset-expiring",
    ]);
  });

  it("treats 40 percent weekly remaining as underused and 39 percent as not", () => {
    const engine = createAlertEngine();
    const atForty = structuredClone(scenarios.daily);
    const weekly = windowOf(provider(atForty, "claude"), "weekly");
    weekly.remainingPercent = 40;
    weekly.usedPercent = 60;
    for (const name of ["codex", "grok"] as const) {
      const other = windowOf(provider(atForty, name), "weekly");
      other.remainingPercent = 39;
      other.usedPercent = 61;
    }
    expect(ids(engine.evaluate(atForty, NOW, READY), "weekly_reset_underused")).toEqual([
      "weekly_reset_underused:claude:weekly:all",
    ]);

    weekly.remainingPercent = 39;
    weekly.usedPercent = 61;
    expect(ids(engine.evaluate(atForty, NOW, READY), "weekly_reset_underused")).toEqual([]);
  });

  it("keeps a model weekly alert separate from the overall window", () => {
    const snapshot = structuredClone(scenarios.daily);
    const claude = provider(snapshot, "claude");
    const overall = windowOf(claude, "weekly");
    claude.windows.push({ ...overall, scope: "sonnet", remainingPercent: 55, usedPercent: 45 });
    const alerts = createAlertEngine().evaluate(snapshot, NOW, READY);
    expect(ids(alerts, "weekly_reset_underused").filter((id) => id.startsWith("weekly_reset_underused:claude:"))).toEqual([
      "weekly_reset_underused:claude:weekly:all",
      "weekly_reset_underused:claude:weekly:sonnet",
    ]);

    const modelOnly = structuredClone(scenarios.daily);
    const model = provider(modelOnly, "claude");
    model.windows = model.windows.filter((window) => window.kind !== "weekly");
    model.windows.push({ ...overall, scope: "sonnet", remainingPercent: 55, usedPercent: 45 });
    const modelAlerts = ids(createAlertEngine().evaluate(modelOnly, NOW, READY), "weekly_reset_underused");
    expect(modelAlerts).toContain("weekly_reset_underused:claude:weekly:sonnet");
    expect(modelAlerts).not.toContain("weekly_reset_underused:claude:weekly:all");
  });

  it("opens an idle alert only after ten continuous minutes and never for Grok's inapplicable 5h window", () => {
    const engine = createAlertEngine();
    const first = freshen(idleSeed, FIXTURE_NOW);
    expect(ids(engine.evaluate(first, NOW, READY), "window_open_idle")).toEqual([]);
    const almost = freshen(idleSeed, fixtureIso(TEN_MINUTES - 1));
    expect(ids(engine.evaluate(almost, new Date(fixtureIso(TEN_MINUTES - 1)), READY), "window_open_idle")).toEqual([]);
    const due = freshen(idleSeed, fixtureIso(TEN_MINUTES));
    const open = engine.evaluate(due, new Date(fixtureIso(TEN_MINUTES)), READY);
    expect(ids(open, "window_open_idle")).toEqual([
      "window_open_idle:claude:five_hour:all",
      "window_open_idle:codex:five_hour:all",
    ]);
    expect(ids(open, "window_open_idle").some((id) => id.includes("grok"))).toBe(false);
    const held = engine.evaluate(freshen(idleSeed, fixtureIso(TEN_MINUTES + 60_000)), new Date(fixtureIso(TEN_MINUTES + 60_000)), READY);
    const firstIdle = open.find((alert) => alert.id === "window_open_idle:claude:five_hour:all");
    const laterIdle = held.find((alert) => alert.id === "window_open_idle:claude:five_hour:all");
    expect(laterIdle?.createdAt).toBe(firstIdle?.createdAt);
    expect(laterIdle?.createdAt).toBe(fixtureIso(TEN_MINUTES));
    expect(laterIdle?.evaluatedAt).toBe(fixtureIso(TEN_MINUTES + 60_000));

    const working = freshen(idleSeed, fixtureIso(TEN_MINUTES + 120_000));
    const claude = working.sessions.find((session) => session.provider === "claude");
    if (!claude) throw new Error("missing claude session");
    claude.status = "working";
    expect(ids(engine.evaluate(working, new Date(fixtureIso(TEN_MINUTES + 120_000)), READY), "window_open_idle")).toEqual([
      "window_open_idle:codex:five_hour:all",
    ]);
    claude.status = "idle";
    const restarted = freshen(idleSeed, fixtureIso(TEN_MINUTES + 120_000));
    expect(ids(engine.evaluate(restarted, new Date(fixtureIso(TEN_MINUTES + 120_000)), READY), "window_open_idle")).toEqual([
      "window_open_idle:codex:five_hour:all",
    ]);
    const returned = freshen(idleSeed, fixtureIso(TEN_MINUTES + 120_000 + TEN_MINUTES));
    const again = engine.evaluate(returned, new Date(fixtureIso(TEN_MINUTES + 120_000 + TEN_MINUTES)), READY);
    const claudeAgain = again.find((alert) => alert.id === "window_open_idle:claude:five_hour:all");
    expect(claudeAgain?.createdAt).toBe(fixtureIso(TEN_MINUTES + 120_000 + TEN_MINUTES));
    expect(claudeAgain?.createdAt).not.toBe(firstIdle?.createdAt);
  });

  it("requires 20 percent 5h remaining and a weekly remainder above zero", () => {
    const open = structuredClone(idleSeed);
    const fiveHour = windowOf(provider(open, "claude"), "five_hour");
    fiveHour.remainingPercent = 20;
    fiveHour.usedPercent = 80;
    const engine = createAlertEngine();
    engine.evaluate(freshen(open, FIXTURE_NOW), NOW, READY);
    const due = freshen(open, fixtureIso(TEN_MINUTES));
    expect(ids(engine.evaluate(due, new Date(fixtureIso(TEN_MINUTES)), READY), "window_open_idle")).toContain(
      "window_open_idle:claude:five_hour:all",
    );

    const below = structuredClone(idleSeed);
    const low = windowOf(provider(below, "claude"), "five_hour");
    low.remainingPercent = 19;
    low.usedPercent = 81;
    const quiet = createAlertEngine();
    quiet.evaluate(freshen(below, FIXTURE_NOW), NOW, READY);
    expect(
      ids(quiet.evaluate(freshen(below, fixtureIso(TEN_MINUTES)), new Date(fixtureIso(TEN_MINUTES)), READY), "window_open_idle"),
    ).not.toContain("window_open_idle:claude:five_hour:all");

    const exhausted = structuredClone(idleSeed);
    for (const name of ["claude", "codex", "grok"] as const) {
      const weekly = windowOf(provider(exhausted, name), "weekly");
      weekly.remainingPercent = 0;
      weekly.usedPercent = 100;
    }
    const spent = createAlertEngine();
    spent.evaluate(freshen(exhausted, FIXTURE_NOW), NOW, READY);
    const spentAlerts = spent.evaluate(freshen(exhausted, fixtureIso(TEN_MINUTES)), new Date(fixtureIso(TEN_MINUTES)), READY);
    expect(ids(spentAlerts, "weekly_reset_underused")).toEqual([]);
    expect(ids(spentAlerts, "window_open_idle")).toEqual([]);
  });

  it("suppresses idle capacity when tmux activity is unknown and suppresses every capacity alert on stale usage", () => {
    const unknown = structuredClone(idleSeed);
    const tmuxSession = scenarios.daily.sessions.find((session) => session.evidenceSource === "tmux");
    if (!tmuxSession) throw new Error("missing tmux session");
    unknown.sessions.push(structuredClone(tmuxSession));
    const engine = createAlertEngine();
    engine.evaluate(freshen(unknown, FIXTURE_NOW), NOW, READY);
    const later = engine.evaluate(freshen(unknown, fixtureIso(TEN_MINUTES)), new Date(fixtureIso(TEN_MINUTES)), READY);
    expect(ids(later, "window_open_idle")).toEqual([]);
    expect(ids(later, "weekly_reset_underused")).toHaveLength(3);
    expect(ids(later, "banked_reset_expiring")).toHaveLength(1);

    const stale = structuredClone(scenarios.daily);
    const old = fixtureIso(-10 * 60 * 1000 - 1);
    for (const quota of stale.providers) {
      for (const window of quota.windows) window.sampledAt = old;
      for (const reset of quota.bankedResets ?? []) reset.sampledAt = old;
    }
    const staleAlerts = createAlertEngine().evaluate(stale, NOW, READY);
    expect(capacity(staleAlerts)).toEqual([]);
    expect(ids(createAlertEngine().evaluate(scenarios.stale, NOW, READY), "source_problem")).toContain(
      "source_problem:claude-quota:quota_ttl_exceeded",
    );
  });

  it("suppresses capacity alerts when session coverage is missing, stale, or reported incomplete", () => {
    const engine = createAlertEngine();
    expect(capacity(engine.evaluate(scenarios.missing, NOW, READY))).toEqual([]);
    expect(ids(engine.evaluate(scenarios.missing, NOW, READY), "source_problem")).toEqual(
      expect.arrayContaining([
        "source_problem:claude-quota:cli_missing",
        "source_problem:herdr:socket_missing",
        "source_problem:tmux:tmux_missing",
      ]),
    );
    const staleHerdr = structuredClone(scenarios.daily);
    const herdr = staleHerdr.sources.find((source) => source.sourceId === "herdr");
    if (!herdr) throw new Error("missing herdr");
    herdr.status = "stale";
    herdr.reasonCode = "session_ttl_exceeded";
    expect(capacity(engine.evaluate(staleHerdr, NOW, READY))).toEqual([]);
    expect(ids(engine.evaluate(staleHerdr, NOW, READY), "source_problem")).toContain(
      "source_problem:herdr:session_ttl_exceeded",
    );
    expect(capacity(engine.evaluate(scenarios.daily, NOW, { sessionsFresh: false, sessionsComplete: false }))).toEqual([]);
  });

  it("does not alert on an unknown reset time, a missing window, an expired reset, or fixture data in live mode", () => {
    const unknownReset = structuredClone(scenarios.daily);
    for (const name of ["claude", "codex", "grok"] as const) {
      const weekly = windowOf(provider(unknownReset, name), "weekly");
      weekly.resetsAt = null;
      weekly.resetRaw = "Sun Nov 1, 2026 1:30 AM";
    }
    expect(ids(createAlertEngine().evaluate(unknownReset, NOW, READY), "weekly_reset_underused")).toEqual([]);

    const missingWindow = structuredClone(scenarios.daily);
    for (const quota of missingWindow.providers) {
      const weekly = windowOf(quota, "weekly");
      weekly.availability = "unknown";
      weekly.usedPercent = null;
      weekly.remainingPercent = null;
      weekly.resetsAt = null;
      weekly.confidence = "unknown";
    }
    expect(ids(createAlertEngine().evaluate(missingWindow, NOW, READY), "weekly_reset_underused")).toEqual([]);

    const expired = structuredClone(scenarios.daily);
    for (const reset of provider(expired, "codex").bankedResets ?? []) {
      reset.expiresAt = FIXTURE_NOW;
      reset.eligibility = "eligible";
      reset.eligibilityReason = null;
      reset.redeemableAt = fixtureIso(-HOUR);
    }
    expect(ids(createAlertEngine().evaluate(expired, NOW, READY), "banked_reset_expiring")).toEqual([]);
    expect(ids(createAlertEngine().evaluate(expired, NOW, READY), "banked_reset_unusable_before_expiry")).toEqual([]);
    for (const reset of provider(expired, "codex").bankedResets ?? []) reset.expiresAt = fixtureIso(-1);
    expect(ids(createAlertEngine().evaluate(expired, NOW, READY), "banked_reset_expiring")).toEqual([]);

    const sameInstant = structuredClone(scenarios.daily);
    const reset = resetOf(provider(sameInstant, "codex"), "codex-reset-expiring");
    reset.redeemableAt = reset.expiresAt;
    reset.eligibility = "eligible";
    reset.eligibilityReason = null;
    const same = createAlertEngine().evaluate(sameInstant, NOW, READY);
    expect(ids(same, "banked_reset_unusable_before_expiry")).toContain(
      "banked_reset_unusable_before_expiry:codex:codex-reset-expiring",
    );
    expect(ids(same, "banked_reset_expiring")).not.toContain("banked_reset_expiring:codex:codex-reset-expiring");

    const unknownEligibility = structuredClone(scenarios.daily);
    const soon = resetOf(provider(unknownEligibility, "codex"), "codex-reset-expiring");
    soon.eligibility = "unknown";
    soon.eligibilityReason = null;
    soon.redeemableAt = null;
    const text = createAlertEngine()
      .evaluate(unknownEligibility, NOW, READY)
      .find((alert) => alert.id === "banked_reset_expiring:codex:codex-reset-expiring");
    expect(text?.message).toContain("expires soon; eligibility unknown");
    expect(text?.message).not.toContain("cannot be used");

    const live = structuredClone(scenarios.daily);
    live.mode = "live";
    expect(capacity(createAlertEngine().evaluate(live, NOW, READY))).toEqual([]);
    const passive = structuredClone(scenarios.daily);
    passive.mode = "passive";
    for (const quota of passive.providers) quota.health.provenance = "live";
    for (const source of passive.sources) source.provenance = "live";
    expect(ids(createAlertEngine().evaluate(passive, NOW, READY), "weekly_reset_underused")).toHaveLength(3);
  });

  it("retains createdAt until the condition resolves and replaces the ledger atomically", () => {
    const engine = createAlertEngine();
    const first = engine.evaluate(scenarios.daily, NOW, READY);
    const created = first.find((alert) => alert.id === "weekly_reset_underused:claude:weekly:all")?.createdAt;
    const later = engine.evaluate(freshen(scenarios.daily, fixtureIso(60_000)), new Date(fixtureIso(60_000)), READY);
    expect(later.find((alert) => alert.id === "weekly_reset_underused:claude:weekly:all")?.createdAt).toBe(created);
    expect(later.find((alert) => alert.id === "weekly_reset_underused:claude:weekly:all")?.evaluatedAt).toBe(fixtureIso(60_000));

    const cleared = structuredClone(scenarios.daily);
    for (const name of ["claude", "codex", "grok"] as const) {
      const weekly = windowOf(provider(cleared, name), "weekly");
      weekly.remainingPercent = 0;
      weekly.usedPercent = 100;
    }
    expect(ids(engine.evaluate(cleared, NOW, READY), "weekly_reset_underused")).toEqual([]);
    const returned = engine.evaluate(scenarios.daily, new Date(fixtureIso(120_000)), READY);
    expect(returned.find((alert) => alert.id === "weekly_reset_underused:claude:weekly:all")?.createdAt).toBe(fixtureIso(120_000));

    const resumed = createAlertEngine(first);
    const kept = resumed.evaluate(scenarios.daily, new Date(fixtureIso(60_000)), READY);
    expect(kept.find((alert) => alert.id === "weekly_reset_underused:claude:weekly:all")?.createdAt).toBe(created);

    const dir = mkdtempSync(path.join(tmpdir(), "herdr-alerts-"));
    const store = openStore({ file: path.join(dir, "dashboard.sqlite"), clock: { now: () => NOW } });
    try {
      store.replaceAlerts(first);
      expect(store.listAlerts().map((alert) => alert.id).sort()).toEqual(first.map((alert) => alert.id).sort());
      const revised = first.map((alert) => ({ ...alert, evaluatedAt: fixtureIso(60_000) }));
      store.replaceAlerts(revised);
      const row = store.listAlerts().find((alert) => alert.id === "weekly_reset_underused:claude:weekly:all");
      expect(row?.createdAt).toBe(created);
      expect(row?.evaluatedAt).toBe(fixtureIso(60_000));
      store.replaceAlerts(revised.filter((alert) => alert.id !== "weekly_reset_underused:grok:weekly:all"));
      const storedIds = store.listAlerts().map((alert) => alert.id);
      expect(storedIds).not.toContain("weekly_reset_underused:grok:weekly:all");
      expect(storedIds).toContain("weekly_reset_underused:claude:weekly:all");
    } finally {
      store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("serves the idle alert from the scheduler only on the ten-minute boundary", async () => {
    const clock = createManualClock(FIXTURE_NOW);
    const dir = mkdtempSync(path.join(tmpdir(), "herdr-alerts-"));
    const store = openStore({ file: path.join(dir, "dashboard.sqlite"), clock });
    const iso = (): string => clock.now().toISOString();
    const scheduler = createScheduler({
      clock,
      store,
      mode: "fixture",
      poll: { sessionsSeconds: 10, gitSeconds: 3600, quotaSeconds: 3600 },
      probesEnabled: false,
      quota: {
        async collect(name) {
          const source = idleSeed.providers.find((item) => item.provider === name);
          if (!source) throw new Error(`missing ${name}`);
          return {
            ...source,
            windows: source.windows.map((window) => ({ ...window, sampledAt: iso() })),
            bankedResets: source.bankedResets === null ? null : source.bankedResets.map((reset) => ({ ...reset, sampledAt: iso() })),
            health: { ...source.health, checkedAt: iso(), lastSuccessAt: iso() },
          };
        },
      },
      herdr: {
        async collect() {
          return {
            sessions: idleSeed.sessions.map((session) => ({ ...session, observedAt: iso() })),
            health: sourceHealthSchema.parse({
              ...idleSeed.sources.find((source) => source.sourceId === "herdr"),
              checkedAt: iso(),
              lastSuccessAt: iso(),
            }),
          };
        },
      },
      tmux: {
        async collect() {
          return {
            sessions: [],
            health: sourceHealthSchema.parse({
              ...idleSeed.sources.find((source) => source.sourceId === "tmux"),
              checkedAt: iso(),
              lastSuccessAt: iso(),
            }),
          };
        },
      },
      git: {
        async collect() {
          const worktree = idleSeed.worktrees[0];
          if (!worktree) throw new Error("missing worktree");
          return {
            worktrees: [{ ...worktree, observedAt: iso(), health: { ...worktree.health, checkedAt: iso(), lastSuccessAt: iso() } }],
            health: sourceHealthSchema.parse({
              ...idleSeed.sources.find((source) => source.sourceId === "git"),
              checkedAt: iso(),
              lastSuccessAt: iso(),
            }),
          };
        },
      },
    });
    try {
      await scheduler.start();
      expect(ids(scheduler.current().alerts, "window_open_idle")).toEqual([]);
      expect(ids(scheduler.current().alerts, "weekly_reset_underused")).toHaveLength(3);
      await clock.advance(TEN_MINUTES - 1);
      expect(ids(scheduler.current().alerts, "window_open_idle")).toEqual([]);
      await clock.advance(1);
      expect(ids(scheduler.current().alerts, "window_open_idle")).toEqual([
        "window_open_idle:claude:five_hour:all",
        "window_open_idle:codex:five_hour:all",
      ]);
      expect(scheduler.current().alerts.find((alert) => alert.kind === "window_open_idle")?.createdAt).toBe(fixtureIso(TEN_MINUTES));
      expect(ids(scheduler.current().alerts, "window_open_idle").some((id) => id.includes("grok"))).toBe(false);
    } finally {
      await scheduler.stop();
      store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
