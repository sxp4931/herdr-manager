import {
  alertSchema,
  type Alert,
  type AlertCoverage,
  type AlertEngine,
  type BankedReset,
  type DashboardSnapshot,
  type ProviderQuota,
  type QuotaWindow,
  type SourceHealth,
} from "@herdr/contracts";
import { QUOTA_TTL_MS, ttlExceeded } from "./snapshot.js";
import { redactText } from "./redaction.js";

const FORTY_EIGHT_HOURS_MS = 48 * 60 * 60 * 1000;
const TEN_MINUTES_MS = 10 * 60 * 1000;

const PROBLEM_STATUS = new Set<SourceHealth["status"]>([
  "missing",
  "not_authenticated",
  "disabled",
  "unsupported",
  "timeout",
  "stale",
  "parse_error",
]);

const KIND_ORDER: Record<Alert["kind"], number> = {
  window_open_idle: 0,
  weekly_reset_underused: 1,
  banked_reset_unusable_before_expiry: 2,
  banked_reset_expiring: 3,
  source_problem: 4,
};

/**
 * Idle dwell is the time this process has continuously observed the open window.
 * It is not taken from session enteredAt. A restarted process keeps an alert that
 * was already firing, and starts a new ten-minute dwell after that alert resolves.
 */
export function createAlertEngine(prior: readonly Alert[] = []): AlertEngine {
  const createdAt: Record<string, string> = {};
  const idleSince: Record<string, string> = {};
  const idleLatched: Record<string, string> = {};
  for (const alert of prior) {
    createdAt[alert.id] = alert.createdAt;
    if (alert.kind === "window_open_idle") idleLatched[alert.provider] = alert.createdAt;
  }

  return {
    evaluate(snapshot, now, coverage) {
      const iso = isoOf(now);
      const found: Alert[] = [];
      const idleOpen: Record<string, true> = {};
      const ready = coverageReady(snapshot, coverage);
      if (ready) {
        for (const quota of orderedProviders(snapshot)) {
          if (!quotaTrusted(snapshot, quota, now)) continue;
          for (const window of uniqueWindows(quota, "weekly")) {
            const alert = weeklyAlert(quota, window, iso, now);
            if (alert) found.push(alert);
          }
          for (const reset of quota.bankedResets ?? []) {
            const alert = bankedAlert(quota, reset, iso, now);
            if (alert) found.push(alert);
          }
          if (idleOpenNow(snapshot, quota, now)) {
            idleOpen[quota.provider] = true;
            const since = latchIdle(quota.provider, iso, idleSince, idleLatched);
            if (now.getTime() - Date.parse(since) >= TEN_MINUTES_MS) {
              const alert = idleAlert(quota, since, iso, now);
              if (alert) found.push(alert);
            }
          }
        }
      }
      for (const provider of Object.keys(idleSince)) {
        if (!idleOpen[provider]) delete idleSince[provider];
      }
      for (const provider of Object.keys(idleLatched)) {
        if (!idleOpen[provider]) delete idleLatched[provider];
      }
      for (const health of sourceRows(snapshot)) {
        const alert = sourceAlert(health, iso);
        if (alert) found.push(alert);
      }
      const active: Record<string, true> = {};
      const stamped = found.map((alert) => {
        const created = createdAt[alert.id] ?? alert.createdAt;
        createdAt[alert.id] = created;
        active[alert.id] = true;
        return alertSchema.parse({ ...alert, createdAt: created, evaluatedAt: iso });
      });
      for (const id of Object.keys(createdAt)) {
        if (!active[id]) delete createdAt[id];
      }
      stamped.sort((left, right) => KIND_ORDER[left.kind] - KIND_ORDER[right.kind] || compareText(left.id, right.id));
      return stamped;
    },
  };
}

/** Herdr and tmux are fresh only while both report status ok. */
export function sessionCoverage(snapshot: DashboardSnapshot): AlertCoverage {
  const herdr = snapshot.sources.find((source) => source.sourceId === "herdr");
  const tmux = snapshot.sources.find((source) => source.sourceId === "tmux");
  const fresh = herdr?.status === "ok" && tmux?.status === "ok";
  return { sessionsFresh: fresh, sessionsComplete: fresh };
}

function coverageReady(snapshot: DashboardSnapshot, coverage: AlertCoverage): boolean {
  if (!coverage.sessionsFresh || !coverage.sessionsComplete) return false;
  const herdr = snapshot.sources.find((source) => source.sourceId === "herdr");
  const tmux = snapshot.sources.find((source) => source.sourceId === "tmux");
  return herdr?.status === "ok" && tmux?.status === "ok";
}

function quotaTrusted(snapshot: DashboardSnapshot, quota: ProviderQuota, now: Date): boolean {
  if (quota.health.provenance === "fixture" && snapshot.mode !== "fixture") return false;
  if (quota.health.status !== "ok") return false;
  const basis = quota.windows.map((window) => window.sampledAt).sort().at(-1) ?? quota.health.checkedAt;
  return !ttlExceeded(basis, now, QUOTA_TTL_MS);
}

function idleOpenNow(snapshot: DashboardSnapshot, quota: ProviderQuota, now: Date): boolean {
  if (uncertainTmux(snapshot)) return false;
  const fiveHour = overall(quota, "five_hour");
  const weekly = overall(quota, "weekly");
  if (!fiveHour || !weekly) return false;
  if (fiveHour.availability === "not_applicable") return false;
  if (!knownFresh(fiveHour, now) || !knownFresh(weekly, now)) return false;
  if (fiveHour.remainingPercent === null || fiveHour.remainingPercent < 20) return false;
  if (weekly.remainingPercent === null || weekly.remainingPercent <= 0) return false;
  const fiveReset = futureDelay(fiveHour.resetsAt, now);
  const weeklyReset = futureDelay(weekly.resetsAt, now);
  if (fiveReset === null || weeklyReset === null) return false;
  return !snapshot.sessions.some(
    (session) =>
      session.provider === quota.provider &&
      (session.status === "working" || session.status === "blocked" || session.status === "unknown"),
  );
}

function weeklyAlert(quota: ProviderQuota, window: QuotaWindow, iso: string, now: Date): Alert | null {
  if (!knownFresh(window, now)) return null;
  if (window.remainingPercent === null || window.remainingPercent < 40) return null;
  const delay = futureDelay(window.resetsAt, now);
  if (delay === null || delay >= FORTY_EIGHT_HOURS_MS) return null;
  const scope = window.scope === "all" ? "weekly" : `weekly ${window.scope}`;
  return draft({
    id: `weekly_reset_underused:${quota.provider}:weekly:${window.scope}`,
    kind: "weekly_reset_underused",
    severity: "info",
    provider: quota.provider,
    subjectId: `${quota.provider}:weekly:${window.scope}`,
    message: `${label(quota.provider)} ${scope} quota has ${window.remainingPercent}% remaining and resets in under 48 hours.`,
    createdAt: iso,
    evaluatedAt: iso,
    evidence: {
      remainingPercent: window.remainingPercent,
      usedPercent: window.usedPercent,
      resetsAt: window.resetsAt,
      scope: window.scope,
    },
  });
}

function bankedAlert(quota: ProviderQuota, reset: BankedReset, iso: string, now: Date): Alert | null {
  if (quota.bankedStatus !== "known") return null;
  const expiry = futureDelay(reset.expiresAt, now);
  if (reset.expiresAt !== null && expiry === null) return null;
  const reason = unusableReason(reset);
  if (reason !== null) {
    return draft({
      id: `banked_reset_unusable_before_expiry:${quota.provider}:${reset.id}`,
      kind: "banked_reset_unusable_before_expiry",
      severity: "warning",
      provider: quota.provider,
      subjectId: reset.id,
      message: `${label(quota.provider)} banked reset ${reset.id} cannot be used before expiry: ${reason}.`,
      createdAt: iso,
      evaluatedAt: iso,
      evidence: {
        expiresAt: reset.expiresAt,
        redeemableAt: reset.redeemableAt,
        eligibility: reset.eligibility,
        eligibilityReason: clip(reason, 200),
      },
    });
  }
  if (expiry === null || expiry >= FORTY_EIGHT_HOURS_MS) return null;
  const unknownEligibility = reset.eligibility === "unknown";
  const message = unknownEligibility
    ? `${label(quota.provider)} banked reset ${reset.id} expires soon; eligibility unknown.`
    : `${label(quota.provider)} banked reset ${reset.id} expires soon.`;
  return draft({
    id: `banked_reset_expiring:${quota.provider}:${reset.id}`,
    kind: "banked_reset_expiring",
    severity: "warning",
    provider: quota.provider,
    subjectId: reset.id,
    message,
    createdAt: iso,
    evaluatedAt: iso,
    evidence: {
      expiresAt: reset.expiresAt,
      redeemableAt: reset.redeemableAt,
      eligibility: reset.eligibility,
      eligibilityReason: reset.eligibilityReason === null ? null : clip(redactText(reset.eligibilityReason), 200),
    },
  });
}

function idleAlert(quota: ProviderQuota, since: string, iso: string, now: Date): Alert | null {
  const fiveHour = overall(quota, "five_hour");
  const weekly = overall(quota, "weekly");
  if (!fiveHour || !weekly || fiveHour.remainingPercent === null || weekly.remainingPercent === null) return null;
  return draft({
    id: `window_open_idle:${quota.provider}:five_hour:all`,
    kind: "window_open_idle",
    severity: "info",
    provider: quota.provider,
    subjectId: `${quota.provider}:five_hour:all`,
    message: `${label(quota.provider)} 5h window is open and no working session has been seen for 10 minutes.`,
    createdAt: iso,
    evaluatedAt: iso,
    evidence: {
      remainingPercent: fiveHour.remainingPercent,
      weeklyRemainingPercent: weekly.remainingPercent,
      dwellMs: now.getTime() - Date.parse(since),
      resetsAt: fiveHour.resetsAt,
    },
  });
}

function sourceAlert(health: SourceHealth, iso: string): Alert | null {
  if (!PROBLEM_STATUS.has(health.status)) return null;
  const provider = health.sourceId.endsWith("-quota") ? health.sourceId.slice(0, -"-quota".length) : health.sourceId;
  return draft({
    id: `source_problem:${health.sourceId}:${health.reasonCode}`,
    kind: "source_problem",
    severity: "warning",
    provider,
    subjectId: health.sourceId,
    message: `Source ${health.sourceId} is ${health.status} (${clip(redactText(health.reasonCode), 80)}).`,
    createdAt: iso,
    evaluatedAt: iso,
    evidence: {
      sourceId: health.sourceId,
      status: health.status,
      reasonCode: clip(redactText(health.reasonCode), 80),
      lastSuccessAt: health.lastSuccessAt,
    },
  });
}

function unusableReason(reset: BankedReset): string | null {
  const explicit = reset.eligibility === "ineligible" ? cleaned(reset.eligibilityReason) : null;
  if (explicit) return explicit;
  const expires = reset.expiresAt === null ? Number.NaN : Date.parse(reset.expiresAt);
  const redeemable = reset.redeemableAt === null ? Number.NaN : Date.parse(reset.redeemableAt);
  if (Number.isFinite(expires) && Number.isFinite(redeemable) && redeemable >= expires) {
    return "redeemable at or after expiry";
  }
  return null;
}

function latchIdle(
  provider: string,
  iso: string,
  idleSince: Record<string, string>,
  idleLatched: Record<string, string>,
): string {
  const existing = idleSince[provider];
  if (existing) return existing;
  const latched = idleLatched[provider];
  const since = latched ? new Date(Date.parse(iso) - TEN_MINUTES_MS).toISOString() : iso;
  idleSince[provider] = since;
  return since;
}

function knownFresh(window: QuotaWindow, now: Date): boolean {
  return window.availability === "known" && window.remainingPercent !== null && !ttlExceeded(window.sampledAt, now, QUOTA_TTL_MS);
}

function futureDelay(iso: string | null, now: Date): number | null {
  if (iso === null) return null;
  const parsed = Date.parse(iso);
  if (!Number.isFinite(parsed)) return null;
  const delay = parsed - now.getTime();
  if (delay <= 0) return null;
  return delay;
}

function uncertainTmux(snapshot: DashboardSnapshot): boolean {
  return snapshot.sessions.some(
    (session) => session.evidenceSource === "tmux" && (session.status === "unknown" || session.confidence === "unknown"),
  );
}

function overall(quota: ProviderQuota, kind: QuotaWindow["kind"]): QuotaWindow | null {
  return quota.windows.find((window) => window.kind === kind && window.scope === "all") ?? null;
}

function uniqueWindows(quota: ProviderQuota, kind: QuotaWindow["kind"]): QuotaWindow[] {
  const seen: Record<string, true> = {};
  const windows: QuotaWindow[] = [];
  for (const window of quota.windows) {
    if (window.kind !== kind || seen[window.scope]) continue;
    seen[window.scope] = true;
    windows.push(window);
  }
  return windows;
}

function orderedProviders(snapshot: DashboardSnapshot): ProviderQuota[] {
  const rank = (provider: string): number => (provider === "claude" ? 0 : provider === "codex" ? 1 : provider === "grok" ? 2 : 9);
  return [...snapshot.providers].sort((left, right) => rank(left.provider) - rank(right.provider) || compareText(left.provider, right.provider));
}

function sourceRows(snapshot: DashboardSnapshot): SourceHealth[] {
  const chosen: Record<string, SourceHealth> = {};
  const incoming = [...snapshot.sources];
  for (const quota of snapshot.providers) {
    if (!incoming.some((health) => health.sourceId === quota.health.sourceId)) incoming.push(quota.health);
  }
  for (const health of incoming) {
    const previous = chosen[health.sourceId];
    if (!previous || health.checkedAt >= previous.checkedAt) chosen[health.sourceId] = health;
  }
  return Object.values(chosen).sort((left, right) => compareText(left.sourceId, right.sourceId));
}

function draft(alert: Alert): Alert {
  return {
    ...alert,
    provider: clip(alert.provider, 40),
    subjectId: clip(alert.subjectId, 160),
    message: clip(redactText(alert.message), 400),
    id: clip(alert.id, 200),
  };
}

function cleaned(value: string | null): string | null {
  if (value === null) return null;
  const text = redactText(value).trim();
  return text === "" ? null : clip(text, 200);
}

function clip(value: string, max: number): string {
  return value.length <= max ? value : value.slice(0, max);
}

function label(provider: string): string {
  if (provider === "claude") return "Claude";
  if (provider === "codex") return "Codex";
  if (provider === "grok") return "Grok";
  return provider;
}

function isoOf(now: Date): string {
  return now.toISOString();
}

function compareText(left: string, right: string): number {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}
