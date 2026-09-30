import {
  agentSessionSchema,
  frozenClock,
  gitWorktreeSchema,
  providerQuotaSchema,
  scenarios,
  sourceHealthSchema,
  type Clock,
  type DashboardSnapshot,
  type GitSource,
  type ProviderId,
  type ProviderQuota,
  type QuotaSource,
  type SessionSource,
  type SourceHealth,
  type SourceStatus,
} from "@herdr/contracts";
import { createCommandRunner } from "./adapters/command-runner.js";
import { createGitSource } from "./adapters/git-source.js";
import { createHerdrSource } from "./adapters/herdr-source.js";
import { createTmuxSource } from "./adapters/tmux-source.js";
import type { DashboardConfig } from "./config.js";
import { QUOTA_PARSER_VERSION } from "./quota/parse.js";
import { createAlertEngine, sessionCoverage } from "./services/alerts.js";
import { reconcileSessions } from "./services/sessions.js";
import {
  disabledQuotaHealth,
  projectSnapshot,
  PROVIDER_ORDER,
  type SnapshotHub,
  type SnapshotState,
} from "./services/snapshot.js";
import type { DashboardStore } from "./storage/repository.js";

const COLLECTOR_ERROR = "collector_error";
const QUOTA_BACKOFF_MS = [5, 10, 20, 30].map((minutes) => minutes * 60 * 1000);
const SESSION_BACKOFF_MS = [10_000, 20_000, 40_000, 60_000];

type Kind = "sessions" | "git" | "quota";

export interface SchedulerClock extends Clock {
  /** Resolves true when the delay elapses, false when the signal aborts. */
  sleep(ms: number, signal: AbortSignal): Promise<boolean>;
}

export interface ManualClock extends SchedulerClock {
  advance(ms: number): Promise<void>;
}

interface Waiter {
  due: number;
  signal: AbortSignal;
  finish(completed: boolean): void;
}

export function wallSchedulerClock(): SchedulerClock {
  return {
    now: () => new Date(),
    sleep(ms, signal) {
      if (signal.aborted) return Promise.resolve(false);
      return new Promise((resolve) => {
        const timer = setTimeout(() => {
          signal.removeEventListener("abort", onAbort);
          resolve(true);
        }, ms);
        const onAbort = (): void => {
          clearTimeout(timer);
          resolve(false);
        };
        signal.addEventListener("abort", onAbort, { once: true });
      });
    },
  };
}

export function frozenSchedulerClock(isoUtc: string): SchedulerClock {
  const clock = frozenClock(isoUtc);
  const wall = wallSchedulerClock();
  return {
    now: () => clock.now(),
    sleep: (ms, signal) => wall.sleep(ms, signal),
  };
}

/** Test clock. `advance` fires sleeps whose delay has elapsed and no earlier ones. */
export function createManualClock(isoUtc: string): ManualClock {
  let current = Date.parse(isoUtc);
  const waiters: Waiter[] = [];

  return {
    now: () => new Date(current),
    sleep(ms, signal) {
      if (signal.aborted) return Promise.resolve(false);
      if (ms <= 0) return Promise.resolve(true);
      return new Promise((resolve) => {
        let settled = false;
        const waiter: Waiter = {
          due: current + ms,
          signal,
          finish(completed) {
            if (settled) return;
            settled = true;
            signal.removeEventListener("abort", onAbort);
            resolve(completed);
          },
        };
        const onAbort = (): void => {
          const index = waiters.indexOf(waiter);
          if (index >= 0) waiters.splice(index, 1);
          waiter.finish(false);
        };
        waiters.push(waiter);
        signal.addEventListener("abort", onAbort, { once: true });
      });
    },
    async advance(ms) {
      if (ms < 0) throw new Error("clock cannot go backwards");
      const target = current + ms;
      for (let guard = 0; guard < 100_000; guard += 1) {
        let nextIndex = -1;
        let nextDue = Number.POSITIVE_INFINITY;
        for (let index = 0; index < waiters.length; index += 1) {
          const waiter = waiters[index];
          if (waiter && waiter.due <= target && waiter.due < nextDue) {
            nextDue = waiter.due;
            nextIndex = index;
          }
        }
        if (nextIndex < 0) break;
        const waiter = waiters[nextIndex];
        if (!waiter) break;
        waiters.splice(nextIndex, 1);
        current = waiter.due;
        waiter.finish(true);
        await settleTurns();
      }
      current = target;
    },
  };
}

async function settleTurns(): Promise<void> {
  for (let turn = 0; turn < 4; turn += 1) {
    await new Promise((resolve) => setImmediate(resolve));
  }
}

/** One in-flight quota probe across providers and rounds. */
export class ProbeGate {
  private tail: Promise<void> = Promise.resolve();

  async exclusive<T>(task: () => Promise<T>): Promise<T> {
    const previous = this.tail;
    let release: () => void = () => undefined;
    this.tail = new Promise((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      return await task();
    } finally {
      release();
    }
  }
}

export interface CollectorSet {
  quota: QuotaSource;
  herdr: SessionSource;
  tmux: SessionSource;
  git: GitSource;
  roots: string[];
}

export interface SchedulerOptions {
  clock: SchedulerClock;
  store: DashboardStore;
  mode: DashboardSnapshot["mode"];
  poll: DashboardConfig["poll"];
  quota: QuotaSource;
  herdr: SessionSource;
  tmux: SessionSource;
  git: GitSource;
  roots?: string[];
  probesEnabled?: boolean;
}

export interface Scheduler extends SnapshotHub {
  start(): Promise<void>;
  stop(): Promise<void>;
  collectQuotas(): Promise<boolean>;
}

function backoffMs(kind: Kind, failures: number): number {
  const steps = kind === "quota" ? QUOTA_BACKOFF_MS : SESSION_BACKOFF_MS;
  const index = Math.min(Math.max(failures, 1), steps.length) - 1;
  return steps[index] ?? steps[steps.length - 1] ?? 60_000;
}

function succeeded(status: SourceStatus): boolean {
  return status === "ok" || status === "disabled";
}

function isoOf(clock: Clock): string {
  return clock.now().toISOString();
}

function restampQuota(quota: ProviderQuota, iso: string): ProviderQuota {
  return providerQuotaSchema.parse({
    ...quota,
    windows: quota.windows.map((window) => ({ ...window, sampledAt: iso })),
    bankedResets: quota.bankedResets === null ? null : quota.bankedResets.map((reset) => ({ ...reset, sampledAt: iso })),
    health: {
      ...quota.health,
      checkedAt: iso,
      lastSuccessAt: quota.health.lastSuccessAt === null ? null : iso,
    },
  });
}

function fixtureHealth(sourceId: string, clock: Clock): SourceHealth {
  const iso = isoOf(clock);
  const source = scenarios.daily.sources.find((item) => item.sourceId === sourceId);
  return sourceHealthSchema.parse({
    sourceId,
    status: "ok",
    checkedAt: iso,
    lastSuccessAt: iso,
    reasonCode: source?.reasonCode ?? "ok",
    cliVersion: source?.cliVersion ?? "fixture-1",
    parserVersion: source?.parserVersion ?? "fixture-1",
    provenance: "fixture",
  });
}

function fixtureCollectors(clock: Clock): CollectorSet {
  const quota: QuotaSource = {
    async collect(provider) {
      const source = scenarios.daily.providers.find((item) => item.provider === provider);
      if (!source) throw new Error(`missing fixture provider ${provider}`);
      return restampQuota(providerQuotaSchema.parse(source), isoOf(clock));
    },
  };
  const herdr: SessionSource = {
    async collect() {
      const iso = isoOf(clock);
      const sessions = scenarios.daily.sessions.map((session) => agentSessionSchema.parse({ ...session, observedAt: iso }));
      return { sessions, health: fixtureHealth("herdr", clock) };
    },
  };
  const tmux: SessionSource = {
    async collect() {
      return { sessions: [], health: fixtureHealth("tmux", clock) };
    },
  };
  const git: GitSource = {
    async collect() {
      const iso = isoOf(clock);
      const source = scenarios.daily.worktrees[0];
      if (!source) return { worktrees: [], health: fixtureHealth("git", clock) };
      const worktree = gitWorktreeSchema.parse({
        ...source,
        observedAt: iso,
        health: { ...source.health, checkedAt: iso, lastSuccessAt: iso, provenance: "fixture" },
      });
      return { worktrees: [worktree], health: fixtureHealth("git", clock) };
    },
  };
  return { quota, herdr, tmux, git, roots: [] };
}

function quotaShell(provider: ProviderId, clock: Clock, status: SourceStatus, reasonCode: string): ProviderQuota {
  const checkedAt = isoOf(clock);
  return providerQuotaSchema.parse({
    provider,
    windows: (["five_hour", "weekly"] as const).map((kind) => ({
      kind,
      scope: "all",
      availability: "unknown",
      usedPercent: null,
      remainingPercent: null,
      resetsAt: null,
      resetRaw: null,
      sourceTimezone: "America/New_York",
      sampledAt: checkedAt,
      confidence: "unknown",
    })),
    bankedResets: null,
    bankedStatus: "unknown",
    health: {
      sourceId: `${provider}-quota`,
      status,
      checkedAt,
      lastSuccessAt: null,
      reasonCode,
      cliVersion: null,
      parserVersion: QUOTA_PARSER_VERSION,
      provenance: "live",
    },
  });
}

/**
 * Fixture mode returns the synthetic catalog. Passive and live modes do not
 * launch subscription CLIs: probes stay disabled or report an unsafe profile.
 */
export function createRuntimeCollectors(options: {
  config: DashboardConfig;
  mode: DashboardSnapshot["mode"];
  clock: Clock;
}): CollectorSet {
  if (options.mode === "fixture") return fixtureCollectors(options.clock);
  const runner = createCommandRunner();
  const git = createGitSource({ runner, clock: options.clock });
  const tmux = createTmuxSource({
    runner,
    clock: options.clock,
    worktrees: options.config.repositoryRoots,
    socketPath: options.config.tmuxSocket,
  });
  const herdr = createHerdrSource({
    clock: options.clock,
    socketPath: options.config.herdrSocket,
    environment: process.env,
  });
  const quota: QuotaSource = {
    async collect(provider) {
      if (!options.config.quotaProbesEnabled) return quotaShell(provider, options.clock, "disabled", "probes_disabled");
      return quotaShell(provider, options.clock, "unsupported", "profile_unsafe");
    },
  };
  return { quota, herdr, tmux, git, roots: [...options.config.repositoryRoots] };
}

class DashboardScheduler implements Scheduler {
  private readonly clock: SchedulerClock;
  private readonly store: DashboardStore;
  private readonly quota: QuotaSource;
  private readonly herdr: SessionSource;
  private readonly tmux: SessionSource;
  private readonly git: GitSource;
  private readonly roots: string[];
  private readonly intervals: Record<Kind, number>;
  private readonly probesEnabled: boolean;
  private readonly gate = new ProbeGate();
  private readonly alertEngine: ReturnType<typeof createAlertEngine>;
  private readonly abort = new AbortController();
  private readonly listeners: Array<(snapshot: DashboardSnapshot) => void> = [];
  private readonly asleep: Record<Kind, boolean> = { sessions: false, git: false, quota: false };
  private readonly idleWaiters: Array<() => void> = [];
  private state: SnapshotState;
  private tasks: Promise<void>[] = [];
  private inflight = 0;
  private started = false;
  private stopped = false;
  private stopPromise: Promise<void> | null = null;
  /** Session ids from the latest collection. Null until the first collection finishes. */
  private liveSessionIds: ReadonlySet<string> | null = null;

  constructor(options: SchedulerOptions) {
    this.clock = options.clock;
    this.store = options.store;
    this.quota = options.quota;
    this.herdr = options.herdr;
    this.tmux = options.tmux;
    this.git = options.git;
    this.roots = [...(options.roots ?? [])];
    this.probesEnabled = options.probesEnabled === true;
    this.alertEngine = createAlertEngine(options.store.listAlerts());
    this.intervals = {
      sessions: options.poll.sessionsSeconds * 1000,
      git: options.poll.gitSeconds * 1000,
      quota: options.poll.quotaSeconds * 1000,
    };
    this.state = {
      mode: options.mode,
      sequence: 0,
      generatedAt: isoOf(options.clock),
      quotas: {},
      health: [],
      sessions: [],
      worktrees: [],
      alerts: [],
      provenance: options.mode === "fixture" ? "fixture" : "live",
    };
  }

  current(): DashboardSnapshot {
    return projectSnapshot(this.state, this.clock.now());
  }

  subscribe(listener: (snapshot: DashboardSnapshot) => void): () => void {
    this.listeners.push(listener);
    return () => {
      const index = this.listeners.indexOf(listener);
      if (index >= 0) this.listeners.splice(index, 1);
    };
  }

  async start(): Promise<void> {
    if (this.started) return this.waitUntilSleeping();
    this.started = true;
    this.reload();
    this.seedDisabledQuotas();
    this.publish();
    this.tasks = (["sessions", "git", "quota"] as const).map((kind) => this.runLoop(kind));
    await this.waitUntilSleeping();
  }

  async stop(): Promise<void> {
    if (this.stopPromise) return this.stopPromise;
    this.stopPromise = this.finish();
    return this.stopPromise;
  }

  async collectQuotas(): Promise<boolean> {
    let ok = true;
    await this.gate.exclusive(async () => {
      for (const provider of PROVIDER_ORDER) {
        if (this.abort.signal.aborted) {
          ok = false;
          return;
        }
        let quota: ProviderQuota;
        try {
          quota = await this.quota.collect(provider, this.abort.signal);
        } catch {
          // One provider failing must not hide the others or leave its old status on screen.
          if (this.abort.signal.aborted) return;
          this.recordCollectorError(`${provider}-quota`);
          ok = false;
          continue;
        }
        this.recordQuota(quota);
        if (!succeeded(quota.health.status)) ok = false;
      }
    });
    return ok;
  }

  private async finish(): Promise<void> {
    this.stopped = true;
    this.abort.abort();
    this.poke();
    await Promise.race([
      Promise.allSettled(this.tasks),
      new Promise((resolve) => setTimeout(resolve, 1500)),
    ]);
  }

  private seedDisabledQuotas(): void {
    if (this.probesEnabled || this.state.mode === "fixture") return;
    const checkedAt = isoOf(this.clock);
    for (const provider of PROVIDER_ORDER) {
      if (healthExists(this.state.health, `${provider}-quota`)) continue;
      this.store.applyHealth(disabledQuotaHealth(provider, checkedAt, "live"));
    }
    this.reload();
  }

  private reload(): void {
    const quotas: SnapshotState["quotas"] = {};
    for (const quota of this.store.listQuotas()) quotas[quota.provider] = quota;
    this.state = {
      ...this.state,
      quotas,
      health: this.store.listHealth(),
      sessions: this.visibleSessions(),
      worktrees: this.store.listWorktrees(),
    };
  }

  /**
   * Stored rows outlive a disappearance for 24 hours so a returning occupant keeps
   * its dwell. The snapshot shows only what the latest collection reported.
   */
  private visibleSessions(): SnapshotState["sessions"] {
    const stored = this.store.listSessions();
    const live = this.liveSessionIds;
    return live === null ? stored : stored.filter((session) => live.has(session.id));
  }

  /** A collector that throws still gets a health row, so the page does not keep showing its last success as current. */
  private recordCollectorError(sourceId: string): void {
    const previous = this.state.health.find((health) => health.sourceId === sourceId) ?? null;
    this.store.applyHealth(
      sourceHealthSchema.parse({
        sourceId,
        status: "parse_error",
        checkedAt: isoOf(this.clock),
        lastSuccessAt: previous?.lastSuccessAt ?? null,
        reasonCode: COLLECTOR_ERROR,
        cliVersion: previous?.cliVersion ?? null,
        parserVersion: previous?.parserVersion ?? QUOTA_PARSER_VERSION,
        provenance: this.state.provenance,
      }),
    );
    this.reload();
  }

  private publish(): void {
    const now = this.clock.now();
    const generatedAt = isoOf(this.clock);
    const projected = projectSnapshot({ ...this.state, alerts: [], generatedAt }, now);
    const alerts = this.alertEngine.evaluate(projected, now, sessionCoverage(projected));
    this.store.replaceAlerts(alerts);
    this.state = {
      ...this.state,
      alerts,
      sequence: this.state.sequence + 1,
      generatedAt,
    };
    const snapshot = this.current();
    for (const listener of [...this.listeners]) {
      try {
        listener(snapshot);
      } catch {
        // One broken subscriber must not stop collection or starve the others.
      }
    }
  }

  private recordQuota(quota: ProviderQuota): void {
    const previous = this.store.latestQuota(quota.provider);
    if (quota.health.status === "ok") {
      this.store.applyQuota(quota);
    } else {
      const lastSuccessAt = quota.health.lastSuccessAt ?? previous?.health.lastSuccessAt ?? null;
      this.store.applyHealth({ ...quota.health, lastSuccessAt });
    }
    this.reload();
  }

  private async collectSessions(): Promise<boolean> {
    const [herdr, tmux] = await Promise.allSettled([
      this.herdr.collect(this.abort.signal),
      this.tmux.collect(this.abort.signal),
    ]);
    if (this.abort.signal.aborted) return false;
    const herdrSessions = herdr.status === "fulfilled" ? herdr.value.sessions : [];
    const tmuxSessions = tmux.status === "fulfilled" ? tmux.value.sessions : [];
    const sessions = reconcileSessions(herdrSessions, tmuxSessions);
    this.store.applySessions(sessions);
    this.liveSessionIds = new Set(sessions.map((session) => session.id));
    let ok = true;
    for (const [sourceId, result] of [["herdr", herdr], ["tmux", tmux]] as const) {
      if (result.status === "fulfilled") {
        this.store.applyHealth(result.value.health);
        if (!succeeded(result.value.health.status)) ok = false;
      } else {
        this.recordCollectorError(sourceId);
        ok = false;
      }
    }
    this.reload();
    return ok;
  }

  private async collectGit(): Promise<boolean> {
    let result: Awaited<ReturnType<GitSource["collect"]>>;
    try {
      result = await this.git.collect(this.roots, this.abort.signal);
    } catch (error) {
      if (!this.abort.signal.aborted) this.recordCollectorError("git");
      throw error;
    }
    this.store.applyGit(result.worktrees);
    this.store.applyHealth(result.health);
    this.reload();
    return succeeded(result.health.status);
  }

  private async runKind(kind: Kind): Promise<boolean> {
    if (kind === "sessions") return this.collectSessions();
    if (kind === "git") return this.collectGit();
    return this.collectQuotas();
  }

  private async runLoop(kind: Kind): Promise<void> {
    let failures = 0;
    while (!this.abort.signal.aborted) {
      let ok = false;
      this.inflight += 1;
      try {
        ok = await this.runKind(kind);
      } catch {
        ok = false;
      } finally {
        this.inflight -= 1;
        this.poke();
      }
      if (this.abort.signal.aborted) return;
      failures = ok ? 0 : failures + 1;
      try {
        this.publish();
      } catch {
        // A storage or projection failure skips this publish. The loop must
        // survive: nothing awaits it until shutdown, so a rejection would be unhandled.
      }
      const delay = ok || kind === "git" ? this.intervals[kind] : backoffMs(kind, failures);
      this.asleep[kind] = true;
      const slept = this.clock.sleep(delay, this.abort.signal);
      this.poke();
      const woke = await slept;
      this.asleep[kind] = false;
      if (!woke || this.abort.signal.aborted) return;
    }
  }

  private waitUntilSleeping(): Promise<void> {
    if (this.stopped || (this.inflight === 0 && this.asleepCount() === 3)) return Promise.resolve();
    return new Promise((resolve) => {
      this.idleWaiters.push(resolve);
      if (this.stopped || (this.inflight === 0 && this.asleepCount() === 3)) this.poke();
    });
  }

  private asleepCount(): number {
    return (["sessions", "git", "quota"] as const).filter((kind) => this.asleep[kind]).length;
  }

  private poke(): void {
    if (!this.stopped && (this.inflight !== 0 || this.asleepCount() !== 3)) return;
    const pending = this.idleWaiters.splice(0);
    for (const resolve of pending) resolve();
  }
}

function healthExists(rows: readonly SourceHealth[], sourceId: string): boolean {
  return rows.some((health) => health.sourceId === sourceId);
}

export function createScheduler(options: SchedulerOptions): Scheduler {
  return new DashboardScheduler(options);
}
