import {
  parseDashboardSnapshot,
  type AgentSession,
  type BankedReset,
  type DashboardSnapshot,
  type GitWorktree,
  type ProviderId,
  type ProviderQuota,
  type QuotaWindow,
  type SourceHealth,
  type SourceStatus,
} from "./schemas.js";

/** Fixed instant used by every synthetic fixture. */
export const FIXTURE_NOW = "2026-09-29T16:00:00.000Z";
const NOW_MS = Date.parse(FIXTURE_NOW);
const HOUR = 60 * 60 * 1000;

export function fixtureIso(offsetMs: number): string {
  return new Date(NOW_MS + offsetMs).toISOString();
}

function health(
  sourceId: string,
  status: SourceStatus,
  extras: Partial<Pick<SourceHealth, "lastSuccessAt" | "reasonCode" | "cliVersion" | "checkedAt">> = {},
): SourceHealth {
  const ok = status === "ok";
  return {
    sourceId,
    status,
    checkedAt: extras.checkedAt ?? FIXTURE_NOW,
    lastSuccessAt: extras.lastSuccessAt === undefined ? (ok ? FIXTURE_NOW : null) : extras.lastSuccessAt,
    reasonCode: extras.reasonCode ?? (ok ? "ok" : status),
    cliVersion: extras.cliVersion === undefined ? (ok ? "fixture-1" : null) : extras.cliVersion,
    parserVersion: "fixture-1",
    provenance: "fixture",
  };
}

function windowOf(
  kind: QuotaWindow["kind"],
  availability: QuotaWindow["availability"],
  used: number | null,
  resetsAt: string | null,
  resetRaw: string | null,
  sampledAt = FIXTURE_NOW,
): QuotaWindow {
  return {
    kind,
    scope: "all",
    availability,
    usedPercent: used,
    remainingPercent: used === null ? null : 100 - used,
    resetsAt,
    resetRaw,
    sourceTimezone: "America/New_York",
    sampledAt,
    confidence: availability === "known" ? "exact" : "unknown",
  };
}

function banked(
  id: string,
  expiresAt: string,
  redeemableAt: string,
  eligibility: BankedReset["eligibility"],
  eligibilityReason: string | null,
): BankedReset {
  return {
    id,
    quantity: 1,
    earnedAt: fixtureIso(-48 * HOUR),
    expiresAt,
    redeemableAt,
    eligibility,
    eligibilityReason,
    sampledAt: FIXTURE_NOW,
  };
}

function provider(
  name: ProviderId,
  windows: QuotaWindow[],
  bankedStatus: ProviderQuota["bankedStatus"],
  bankedResets: BankedReset[] | null,
  status: SourceStatus = "ok",
  healthExtras: Partial<Pick<SourceHealth, "lastSuccessAt" | "reasonCode" | "cliVersion" | "checkedAt">> = {},
): ProviderQuota {
  return {
    provider: name,
    windows,
    bankedResets,
    bankedStatus,
    health: health(`${name}-quota`, status, healthExtras),
  };
}

function session(input: AgentSession): AgentSession {
  return input;
}

const demoHead = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const demoParent = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

function demoWorktree(observedAt = FIXTURE_NOW): GitWorktree {
  return {
    id: "git:demo",
    repositoryId: "demo",
    path: "/work/demo",
    branch: "feature/demo",
    head: demoHead,
    detached: false,
    locked: false,
    prunable: false,
    staged: 1,
    modified: 1,
    untracked: 1,
    conflicted: 0,
    recentCommits: [
      { sha: demoHead, subject: "Add fixture worktree", committedAt: fixtureIso(-1 * HOUR) },
      { sha: demoParent, subject: "Initial fixture commit", committedAt: fixtureIso(-25 * HOUR) },
    ],
    observedAt,
    health: health("git", "ok", { checkedAt: observedAt, lastSuccessAt: observedAt }),
  };
}

function baseSnapshot(partial: Omit<DashboardSnapshot, "schemaVersion" | "mode"> & { mode?: DashboardSnapshot["mode"] }): DashboardSnapshot {
  return parseDashboardSnapshot({
    schemaVersion: 1,
    mode: partial.mode ?? "fixture",
    sequence: partial.sequence,
    generatedAt: partial.generatedAt,
    providers: partial.providers,
    sessions: partial.sessions,
    worktrees: partial.worktrees,
    alerts: partial.alerts,
    sources: partial.sources,
  });
}

const claudeWorking = session({
  id: "herdr:fixture:ws-claude:pane-claude",
  provider: "claude",
  runtime: "herdr",
  sessionIdentity: "claude-session-1",
  workspaceId: "ws-claude",
  paneId: "pane-claude",
  label: "daily-claude-worker",
  cwd: "/work/demo",
  status: "working",
  stateChangeSeq: 4,
  enteredAt: fixtureIso(-20 * 60 * 1000),
  lastOutputAt: fixtureIso(-60 * 1000),
  observedAt: FIXTURE_NOW,
  evidenceSource: "herdr",
  confidence: "exact",
  pid: 4101,
  loop: null,
});

const codexWorking = session({
  id: "herdr:fixture:ws-codex:pane-codex",
  provider: "codex",
  runtime: "herdr",
  sessionIdentity: "codex-session-1",
  workspaceId: "ws-codex",
  paneId: "pane-codex",
  label: "daily-codex-worker",
  cwd: "/work/demo",
  status: "working",
  stateChangeSeq: 7,
  enteredAt: fixtureIso(-15 * 60 * 1000),
  lastOutputAt: fixtureIso(-30 * 1000),
  observedAt: FIXTURE_NOW,
  evidenceSource: "herdr",
  confidence: "exact",
  pid: 4102,
  loop: null,
});

const grokWorking = session({
  id: "herdr:fixture:ws-grok:pane-grok",
  provider: "grok",
  runtime: "herdr",
  sessionIdentity: "grok-session-1",
  workspaceId: "ws-grok",
  paneId: "pane-grok",
  label: "daily-grok-worker",
  cwd: "/work/demo",
  status: "working",
  stateChangeSeq: 2,
  enteredAt: fixtureIso(-10 * 60 * 1000),
  lastOutputAt: fixtureIso(-20 * 1000),
  observedAt: FIXTURE_NOW,
  evidenceSource: "herdr",
  confidence: "exact",
  pid: 4103,
  loop: null,
});

const goalRunning = session({
  id: "manifest:fixture:goal-1",
  provider: "claude",
  runtime: "manifest",
  sessionIdentity: "goal-session-1",
  workspaceId: "ws-goal",
  paneId: "pane-goal",
  label: "goal-runner",
  cwd: "/work/demo",
  status: "working",
  stateChangeSeq: 1,
  enteredAt: fixtureIso(-30 * 60 * 1000),
  lastOutputAt: fixtureIso(-2 * 60 * 1000),
  observedAt: FIXTURE_NOW,
  evidenceSource: "manifest",
  confidence: "exact",
  pid: 4202,
  loop: {
    kind: "goal",
    state: "running",
    iteration: 2,
    objective: "Refresh the dashboard fixture",
    source: "manifest",
  },
});

const processOnly = session({
  id: "tmux:fixture:%9",
  provider: "codex",
  runtime: "tmux",
  sessionIdentity: null,
  workspaceId: "tmux-session",
  paneId: "%9",
  label: "codex-process-only",
  cwd: "/work/other",
  status: "unknown",
  stateChangeSeq: 0,
  enteredAt: fixtureIso(-2 * HOUR),
  lastOutputAt: null,
  observedAt: FIXTURE_NOW,
  evidenceSource: "tmux",
  confidence: "unknown",
  pid: 4303,
  loop: {
    kind: "unknown",
    state: "unknown",
    iteration: null,
    objective: null,
    source: "process",
  },
});

const hostileLabel = session({
  id: "herdr:fixture:ws-label:pane-label",
  provider: "grok",
  runtime: "herdr",
  sessionIdentity: "label-session",
  workspaceId: "ws-label",
  paneId: "pane-label",
  label: '<img src=x onerror=alert(1)>',
  cwd: null,
  status: "done",
  stateChangeSeq: 1,
  enteredAt: fixtureIso(-3 * HOUR),
  lastOutputAt: fixtureIso(-3 * HOUR),
  observedAt: FIXTURE_NOW,
  evidenceSource: "herdr",
  confidence: "exact",
  pid: 4404,
  loop: null,
});

const expiringReset = banked("codex-reset-expiring", fixtureIso(24 * HOUR), fixtureIso(1 * HOUR), "eligible", null);
const unusableReset = banked(
  "codex-reset-unusable",
  fixtureIso(24 * HOUR),
  fixtureIso(25 * HOUR),
  "ineligible",
  "redeemable only after expiry",
);

function dailyProviders(sampledAt = FIXTURE_NOW): ProviderQuota[] {
  return [
    provider("claude", [
      windowOf("five_hour", "known", 10, fixtureIso(4 * HOUR), "in 4h", sampledAt),
      windowOf("weekly", "known", 20, fixtureIso(36 * HOUR), "in 36h", sampledAt),
    ], "not_applicable", null),
    provider("codex", [
      windowOf("five_hour", "known", 35, fixtureIso(4 * HOUR), "in 4h", sampledAt),
      windowOf("weekly", "known", 25, fixtureIso(37 * HOUR), "in 37h", sampledAt),
    ], "known", [
      { ...expiringReset, sampledAt },
      { ...unusableReset, sampledAt },
    ]),
    provider("grok", [
      windowOf("five_hour", "not_applicable", null, null, null, sampledAt),
      windowOf("weekly", "known", 15, fixtureIso(47 * HOUR), "in 47h", sampledAt),
    ], "not_applicable", null),
  ];
}

export const scenarios = {
  daily: baseSnapshot({
    sequence: 1,
    generatedAt: FIXTURE_NOW,
    providers: dailyProviders(),
    sessions: [claudeWorking, codexWorking, grokWorking, goalRunning, processOnly, hostileLabel],
    worktrees: [demoWorktree()],
    alerts: [],
    sources: [
      health("claude-quota", "ok"),
      health("codex-quota", "ok"),
      health("grok-quota", "ok"),
      health("herdr", "ok"),
      health("tmux", "ok"),
      health("git", "ok"),
    ],
  }),
  missing: baseSnapshot({
    sequence: 1,
    generatedAt: FIXTURE_NOW,
    providers: (["claude", "codex", "grok"] as const).map((name) =>
      provider(name, [
        windowOf("five_hour", "unknown", null, null, null),
        windowOf("weekly", "unknown", null, null, null),
      ], "unknown", null, "missing", { cliVersion: null, reasonCode: "cli_missing" }),
    ),
    sessions: [],
    worktrees: [],
    alerts: [],
    sources: [
      health("claude-quota", "missing", { cliVersion: null, reasonCode: "cli_missing" }),
      health("codex-quota", "missing", { cliVersion: null, reasonCode: "cli_missing" }),
      health("grok-quota", "missing", { cliVersion: null, reasonCode: "cli_missing" }),
      health("herdr", "missing", { cliVersion: null, reasonCode: "socket_missing" }),
      health("tmux", "missing", { cliVersion: null, reasonCode: "tmux_missing" }),
    ],
  }),
  stale: baseSnapshot({
    sequence: 2,
    generatedAt: FIXTURE_NOW,
    providers: [
      provider(
        "claude",
        [
          windowOf("five_hour", "known", 10, fixtureIso(4 * HOUR), "in 4h", fixtureIso(-15 * 60 * 1000)),
          windowOf("weekly", "known", 20, fixtureIso(36 * HOUR), "in 36h", fixtureIso(-15 * 60 * 1000)),
        ],
        "not_applicable",
        null,
        "stale",
        { lastSuccessAt: fixtureIso(-15 * 60 * 1000), reasonCode: "quota_ttl_exceeded", cliVersion: "fixture-1" },
      ),
    ],
    sessions: [],
    worktrees: [],
    alerts: [],
    sources: [
      health("claude-quota", "stale", {
        lastSuccessAt: fixtureIso(-15 * 60 * 1000),
        reasonCode: "quota_ttl_exceeded",
        cliVersion: "fixture-1",
      }),
    ],
  }),
  partial: baseSnapshot({
    sequence: 1,
    generatedAt: FIXTURE_NOW,
    providers: [
      provider("claude", [
        windowOf("five_hour", "unknown", null, null, null),
        windowOf("weekly", "known", 20, fixtureIso(36 * HOUR), "in 36h"),
      ], "unknown", null),
      provider("codex", [
        windowOf("five_hour", "known", 35, fixtureIso(4 * HOUR), "in 4h"),
        windowOf("weekly", "unknown", null, null, null),
      ], "known", []),
      provider("grok", [
        windowOf("five_hour", "not_applicable", null, null, null),
        windowOf("weekly", "unknown", null, null, null),
      ], "unknown", null, "missing", { cliVersion: null, reasonCode: "cli_missing" }),
    ],
    sessions: [],
    worktrees: [],
    alerts: [],
    sources: [
      health("claude-quota", "ok"),
      health("codex-quota", "ok"),
      health("grok-quota", "missing", { cliVersion: null, reasonCode: "cli_missing" }),
    ],
  }),
  dst: baseSnapshot({
    sequence: 1,
    generatedAt: FIXTURE_NOW,
    providers: [
      provider("claude", [
        {
          kind: "weekly",
          scope: "all",
          availability: "known",
          usedPercent: 20,
          remainingPercent: 80,
          resetsAt: null,
          resetRaw: "Sun Nov 1, 2026 1:30 AM",
          sourceTimezone: "America/New_York",
          sampledAt: FIXTURE_NOW,
          confidence: "exact",
        },
      ], "not_applicable", null),
    ],
    sessions: [],
    worktrees: [],
    alerts: [],
    sources: [health("claude-quota", "ok")],
  }),
  "banked-expiring": baseSnapshot({
    sequence: 1,
    generatedAt: FIXTURE_NOW,
    providers: [
      provider("codex", [
        windowOf("five_hour", "known", 35, fixtureIso(4 * HOUR), "in 4h"),
        windowOf("weekly", "known", 25, fixtureIso(37 * HOUR), "in 37h"),
      ], "known", [expiringReset, unusableReset]),
    ],
    sessions: [],
    worktrees: [],
    alerts: [],
    sources: [health("codex-quota", "ok")],
  }),
  "unknown-loop": baseSnapshot({
    sequence: 1,
    generatedAt: FIXTURE_NOW,
    providers: [],
    sessions: [processOnly],
    worktrees: [],
    alerts: [],
    sources: [health("tmux", "ok")],
  }),
} as const satisfies Record<string, DashboardSnapshot>;

export type ScenarioName = keyof typeof scenarios;

export const scenarioNames = Object.keys(scenarios) as ScenarioName[];

/** Idle fixture: same quotas as daily, no working or unknown sessions, clock not yet advanced. */
export const idleSeed = baseSnapshot({
  sequence: 1,
  generatedAt: FIXTURE_NOW,
  providers: dailyProviders(),
  sessions: [
    { ...claudeWorking, status: "idle", id: "herdr:fixture:ws-claude:pane-idle", label: "claude-idle" },
    { ...codexWorking, status: "done", id: "herdr:fixture:ws-codex:pane-done", label: "codex-done" },
  ],
  worktrees: [demoWorktree()],
  alerts: [],
  sources: [
    health("claude-quota", "ok"),
    health("codex-quota", "ok"),
    health("grok-quota", "ok"),
    health("herdr", "ok"),
    health("tmux", "ok"),
    health("git", "ok"),
  ],
});
