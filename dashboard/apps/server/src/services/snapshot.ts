import {
  parseDashboardSnapshot,
  sourceHealthSchema,
  type AgentSession,
  type Alert,
  type DashboardSnapshot,
  type GitWorktree,
  type ProviderId,
  type ProviderQuota,
  type SourceHealth,
} from "@herdr/contracts";
import { QUOTA_PARSER_VERSION } from "../quota/parse.js";

/** Quota samples older than this are stale. Equal age stays fresh. */
export const QUOTA_TTL_MS = 10 * 60 * 1000;
/** Session coverage older than this is stale. Equal age stays fresh. */
export const SESSION_TTL_MS = 30 * 1000;
/** Git observations older than this are stale. Equal age stays fresh. */
export const GIT_TTL_MS = 90 * 1000;

export const PROVIDER_ORDER = ["claude", "codex", "grok"] as const;

export const QUOTA_TTL_REASON = "quota_ttl_exceeded";
export const SESSION_TTL_REASON = "session_ttl_exceeded";
export const GIT_TTL_REASON = "git_ttl_exceeded";

const SESSION_SOURCES = new Set(["herdr", "tmux"]);

export interface SnapshotState {
  mode: DashboardSnapshot["mode"];
  sequence: number;
  generatedAt: string;
  quotas: Partial<Record<ProviderId, ProviderQuota>>;
  health: SourceHealth[];
  sessions: AgentSession[];
  worktrees: GitWorktree[];
  alerts: Alert[];
  provenance: "live" | "fixture";
}

export interface SnapshotHub {
  current(): DashboardSnapshot;
  subscribe(listener: (snapshot: DashboardSnapshot) => void): () => void;
}

export function disabledQuotaHealth(provider: ProviderId, checkedAt: string, provenance: "live" | "fixture"): SourceHealth {
  return sourceHealthSchema.parse({
    sourceId: `${provider}-quota`,
    status: "disabled",
    checkedAt,
    lastSuccessAt: null,
    reasonCode: "probes_disabled",
    cliVersion: null,
    parserVersion: QUOTA_PARSER_VERSION,
    provenance,
  });
}

function missingHealth(sourceId: string, checkedAt: string, provenance: "live" | "fixture"): SourceHealth {
  return sourceHealthSchema.parse({
    sourceId,
    status: "missing",
    checkedAt,
    lastSuccessAt: null,
    reasonCode: "not_collected",
    cliVersion: null,
    parserVersion: QUOTA_PARSER_VERSION,
    provenance,
  });
}

function unknownWindow(kind: "five_hour" | "weekly", sampledAt: string): ProviderQuota["windows"][number] {
  return {
    kind,
    scope: "all",
    availability: "unknown",
    usedPercent: null,
    remainingPercent: null,
    resetsAt: null,
    resetRaw: null,
    sourceTimezone: "America/New_York",
    sampledAt,
    confidence: "unknown",
  };
}

/** Age strictly greater than the TTL is stale. The equal boundary stays fresh. */
export function ttlExceeded(basis: string, now: Date, ttlMs: number): boolean {
  const age = now.getTime() - Date.parse(basis);
  return Number.isFinite(age) && age > ttlMs;
}

function applyTtl(health: SourceHealth, basis: string, now: Date, ttlMs: number, reason: string): SourceHealth {
  if (health.status !== "ok" || !ttlExceeded(basis, now, ttlMs)) return health;
  return {
    ...health,
    status: "stale",
    reasonCode: reason,
    checkedAt: now.toISOString(),
  };
}

function healthById(rows: readonly SourceHealth[], sourceId: string): SourceHealth | null {
  let best: SourceHealth | null = null;
  for (const health of rows) {
    if (health.sourceId !== sourceId) continue;
    if (!best || health.checkedAt >= best.checkedAt) best = health;
  }
  return best;
}

function quotaBasis(quota: ProviderQuota): string {
  const stamps = quota.windows.map((window) => window.sampledAt).sort();
  return stamps[stamps.length - 1] ?? quota.health.lastSuccessAt ?? quota.health.checkedAt;
}

function adjustListedHealth(health: SourceHealth, now: Date): SourceHealth {
  if (SESSION_SOURCES.has(health.sourceId)) {
    return applyTtl(health, health.checkedAt, now, SESSION_TTL_MS, SESSION_TTL_REASON);
  }
  if (health.sourceId === "git") {
    return applyTtl(health, health.lastSuccessAt ?? health.checkedAt, now, GIT_TTL_MS, GIT_TTL_REASON);
  }
  return health;
}

function projectProvider(provider: ProviderId, state: SnapshotState, now: Date): ProviderQuota {
  const stored = state.quotas[provider] ?? null;
  const listed = healthById(state.health, `${provider}-quota`);
  const fallback = stored?.health ?? listed ?? missingHealth(`${provider}-quota`, state.generatedAt, state.provenance);
  const preferred = listed && listed.checkedAt >= fallback.checkedAt ? listed : fallback;
  const basis = stored ? quotaBasis(stored) : preferred.lastSuccessAt ?? preferred.checkedAt;
  const health = applyTtl(preferred, basis, now, QUOTA_TTL_MS, QUOTA_TTL_REASON);
  if (!stored) {
    return {
      provider,
      windows: [unknownWindow("five_hour", health.checkedAt), unknownWindow("weekly", health.checkedAt)],
      bankedResets: null,
      bankedStatus: "unknown",
      health,
    };
  }
  return { ...stored, health };
}

function projectWorktree(worktree: GitWorktree, now: Date): GitWorktree {
  return {
    ...worktree,
    health: applyTtl(worktree.health, worktree.observedAt, now, GIT_TTL_MS, GIT_TTL_REASON),
  };
}

/** Assemble one immutable snapshot. Window and session timestamps are copied, not refreshed. */
export function projectSnapshot(state: SnapshotState, now: Date): DashboardSnapshot {
  const providers = PROVIDER_ORDER.map((provider) => projectProvider(provider, state, now));
  const worktrees = state.worktrees.map((worktree) => projectWorktree(worktree, now));
  const sources: SourceHealth[] = [];
  const seen = new Set<string>();
  const push = (health: SourceHealth): void => {
    if (seen.has(health.sourceId)) return;
    seen.add(health.sourceId);
    sources.push(health);
  };
  for (const provider of providers) push(provider.health);
  for (const health of state.health) push(adjustListedHealth(health, now));
  return parseDashboardSnapshot({
    schemaVersion: 1,
    sequence: state.sequence,
    generatedAt: state.generatedAt,
    providers,
    sessions: state.sessions,
    worktrees,
    alerts: state.alerts,
    sources,
    mode: state.mode,
  });
}
