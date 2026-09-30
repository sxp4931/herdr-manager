import { z } from "zod";

function hasControlCharacter(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code <= 31 || code === 127) {
      return true;
    }
  }
  return false;
}

/** UTC timestamp with millisecond precision, for example 2026-09-29T16:00:00.000Z. */
export const isoUtcSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);

export const sourceStatusSchema = z.enum([
  "ok",
  "missing",
  "not_authenticated",
  "disabled",
  "unsupported",
  "timeout",
  "parse_error",
  "stale",
]);

export const provenanceSchema = z.enum(["live", "fixture"]);

export const sourceHealthSchema = z
  .object({
    sourceId: z.string().min(1).max(120),
    status: sourceStatusSchema,
    checkedAt: isoUtcSchema,
    lastSuccessAt: isoUtcSchema.nullable(),
    reasonCode: z.string().min(1).max(80),
    cliVersion: z.string().min(1).max(80).nullable(),
    parserVersion: z.string().min(1).max(40),
    provenance: provenanceSchema,
  })
  .strict();

export const percentSchema = z.number().finite().min(0).max(100);

export const quotaWindowSchema = z
  .object({
    kind: z.enum(["five_hour", "weekly"]),
    scope: z.string().min(1).max(80),
    availability: z.enum(["known", "unknown", "not_applicable"]),
    usedPercent: percentSchema.nullable(),
    remainingPercent: percentSchema.nullable(),
    resetsAt: isoUtcSchema.nullable(),
    resetRaw: z.string().max(80).nullable(),
    sourceTimezone: z.string().min(1).max(80).nullable(),
    sampledAt: isoUtcSchema,
    confidence: z.enum(["exact", "rounded", "unknown"]),
  })
  .strict()
  .superRefine((window, ctx) => {
    if (window.resetRaw !== null && hasControlCharacter(window.resetRaw)) {
      ctx.addIssue("reset text must be a single sanitized line");
    }
    if (window.availability === "known") {
      if (window.usedPercent === null || window.remainingPercent === null) {
        ctx.addIssue("a known window needs both percentages");
        return;
      }
      const sum = window.usedPercent + window.remainingPercent;
      const tolerance = window.confidence === "rounded" ? 0.11 : 0.001;
      if (Math.abs(sum - 100) > tolerance) {
        ctx.addIssue("used and remaining percentages must account for the whole window");
      }
      return;
    }
    if (window.usedPercent !== null || window.remainingPercent !== null) {
      ctx.addIssue("unknown data must stay null and must not be encoded as zero");
    }
  });

export const bankedResetSchema = z
  .object({
    id: z.string().min(1).max(80),
    quantity: z.number().int().positive(),
    earnedAt: isoUtcSchema.nullable(),
    expiresAt: isoUtcSchema.nullable(),
    redeemableAt: isoUtcSchema.nullable(),
    eligibility: z.enum(["eligible", "ineligible", "unknown"]),
    eligibilityReason: z.string().max(160).nullable(),
    sampledAt: isoUtcSchema,
  })
  .strict();

export const providerQuotaSchema = z
  .object({
    provider: z.enum(["claude", "codex", "grok"]),
    windows: z.array(quotaWindowSchema).max(8),
    bankedResets: z.array(bankedResetSchema).nullable(),
    bankedStatus: z.enum(["known", "unknown", "not_applicable"]),
    health: sourceHealthSchema,
  })
  .strict()
  .superRefine((provider, ctx) => {
    if (provider.bankedStatus === "known") {
      if (provider.bankedResets === null) {
        ctx.addIssue("a known banked inventory is an array, empty when nothing is banked");
      }
    } else if (provider.bankedResets !== null) {
      ctx.addIssue("an unknown or not-applicable banked inventory is null, not an empty list");
    }
    const seen = new Set<string>();
    for (const window of provider.windows) {
      const key = `${window.kind}:${window.scope}`;
      if (seen.has(key)) {
        ctx.addIssue(`duplicate window ${key}`);
      }
      seen.add(key);
    }
  });

export const loopManifestSchema = z
  .object({
    schemaVersion: z.literal(1),
    sessionIdentity: z.string().min(1).max(120),
    provider: z.enum(["claude", "codex", "grok"]),
    pid: z.number().int().positive().safe(),
    processStartTicks: z.number().int().nonnegative().safe(),
    kind: z.enum(["goal", "loop", "workflow", "custom", "unknown"]),
    state: z.enum(["running", "waiting", "finished", "unknown"]),
    iteration: z.number().int().nonnegative().nullable(),
    objective: z.string().max(160).nullable(),
    updatedAt: isoUtcSchema,
  })
  .strict()
  .superRefine((manifest, ctx) => {
    if (hasControlCharacter(manifest.sessionIdentity)) {
      ctx.addIssue("manifest session identity contains control characters");
    }
    if (manifest.objective !== null && hasControlCharacter(manifest.objective)) {
      ctx.addIssue("manifest objective contains control characters");
    }
  });

export const loopInfoSchema = z
  .object({
    kind: z.enum(["goal", "loop", "workflow", "custom", "unknown"]),
    state: z.enum(["running", "waiting", "finished", "unknown"]),
    iteration: z.number().int().nonnegative().nullable(),
    objective: z.string().max(160).nullable(),
    source: z.enum(["manifest", "process"]),
  })
  .strict()
  .superRefine((loop, ctx) => {
    if (loop.objective !== null && hasControlCharacter(loop.objective)) {
      ctx.addIssue("loop objective contains control characters");
    }
  });

export const agentSessionSchema = z
  .object({
    id: z.string().min(1).max(200),
    provider: z.string().min(1).max(40),
    runtime: z.string().min(1).max(40),
    sessionIdentity: z.string().min(1).max(120).nullable(),
    workspaceId: z.string().min(1).max(120),
    paneId: z.string().min(1).max(120),
    label: z.string().max(160),
    cwd: z.string().max(400).nullable(),
    status: z.enum(["idle", "working", "blocked", "done", "unknown"]),
    stateChangeSeq: z.number().int().nonnegative().safe(),
    enteredAt: isoUtcSchema,
    lastOutputAt: isoUtcSchema.nullable(),
    observedAt: isoUtcSchema,
    evidenceSource: z.enum(["herdr", "tmux", "manifest"]),
    confidence: z.enum(["exact", "rounded", "unknown"]),
    pid: z.number().int().positive().nullable(),
    loop: loopInfoSchema.nullable(),
  })
  .strict();

export const gitCommitSchema = z
  .object({
    sha: z.string().regex(/^[0-9a-f]{40}$/),
    subject: z.string().min(1).max(120),
    committedAt: isoUtcSchema,
  })
  .strict();

export const gitWorktreeSchema = z
  .object({
    id: z.string().min(1).max(200),
    repositoryId: z.string().min(1).max(120),
    path: z.string().min(1).max(400),
    branch: z.string().min(1).max(200).nullable(),
    head: z.string().regex(/^[0-9a-f]{40}$/).nullable(),
    detached: z.boolean(),
    locked: z.boolean(),
    prunable: z.boolean(),
    staged: z.number().int().nonnegative(),
    modified: z.number().int().nonnegative(),
    untracked: z.number().int().nonnegative(),
    conflicted: z.number().int().nonnegative(),
    recentCommits: z.array(gitCommitSchema).max(5),
    observedAt: isoUtcSchema,
    health: sourceHealthSchema,
  })
  .strict();

const evidenceValueSchema = z.union([z.string().max(200), z.number().finite(), z.boolean(), z.null()]);

export const alertSchema = z
  .object({
    id: z.string().min(1).max(200),
    kind: z.enum([
      "window_open_idle",
      "weekly_reset_underused",
      "banked_reset_unusable_before_expiry",
      "banked_reset_expiring",
      "source_problem",
    ]),
    severity: z.enum(["info", "warning"]),
    provider: z.string().min(1).max(40),
    subjectId: z.string().min(1).max(160),
    message: z.string().min(1).max(400),
    createdAt: isoUtcSchema,
    evaluatedAt: isoUtcSchema,
    evidence: z.record(z.string().min(1).max(40), evidenceValueSchema),
  })
  .strict();

export const dashboardSnapshotSchema = z
  .object({
    schemaVersion: z.literal(1),
    sequence: z.number().int().nonnegative(),
    generatedAt: isoUtcSchema,
    providers: z.array(providerQuotaSchema),
    sessions: z.array(agentSessionSchema),
    worktrees: z.array(gitWorktreeSchema),
    alerts: z.array(alertSchema),
    sources: z.array(sourceHealthSchema),
    mode: z.enum(["passive", "live", "fixture"]),
  })
  .strict();

export const healthSchema = z
  .object({
    status: z.literal("ok"),
    schemaVersion: z.literal(1),
    mode: z.enum(["passive", "live", "fixture"]),
    readOnly: z.literal(true),
  })
  .strict();

export type SourceStatus = z.infer<typeof sourceStatusSchema>;
export type Provenance = z.infer<typeof provenanceSchema>;
export type SourceHealth = z.infer<typeof sourceHealthSchema>;
export type QuotaWindow = z.infer<typeof quotaWindowSchema>;
export type BankedReset = z.infer<typeof bankedResetSchema>;
export type ProviderQuota = z.infer<typeof providerQuotaSchema>;
export type ProviderId = ProviderQuota["provider"];
export type LoopManifest = z.infer<typeof loopManifestSchema>;
export type LoopInfo = z.infer<typeof loopInfoSchema>;
export type AgentSession = z.infer<typeof agentSessionSchema>;
export type GitCommit = z.infer<typeof gitCommitSchema>;
export type GitWorktree = z.infer<typeof gitWorktreeSchema>;
export type Alert = z.infer<typeof alertSchema>;
export type DashboardSnapshot = z.infer<typeof dashboardSnapshotSchema>;
export type Health = z.infer<typeof healthSchema>;

export const probeStateSchema = z.enum([
  "started",
  "empty_prompt",
  "command_sent",
  "known_usage_screen",
  "parsed",
  "shutdown",
]);

export const probeResultSchema = z
  .object({
    ok: z.boolean(),
    provider: z.string().regex(/^[a-z0-9_-]{1,32}$/),
    profile: z.string().regex(/^[A-Za-z0-9._-]{1,64}$/),
    state: probeStateSchema,
    reason: z.string().regex(/^[a-z][a-z0-9_]{0,63}$/),
    version: z.string().regex(/^[A-Za-z0-9._+-]{1,64}$/).nullable(),
    isatty: z.boolean(),
    sent: z.array(z.string().regex(/^\/(usage|status)$/)).max(4),
    childReaped: z.boolean(),
    recognized: z.boolean(),
    deadlineMs: z.number().int().min(100).max(20_000),
  })
  .strict()
  .superRefine((result, ctx) => {
    if (!result.ok) {
      return;
    }
    if (result.reason !== "ok" || !result.recognized || result.state !== "parsed" || !result.isatty || result.sent.length === 0) {
      ctx.addIssue("a successful probe result must be a parsed tty screen");
    }
  });

export type ProbeResult = z.infer<typeof probeResultSchema>;

export function parseHealth(input: unknown): Health {
  return healthSchema.parse(input);
}

export function parseDashboardSnapshot(input: unknown): DashboardSnapshot {
  return dashboardSnapshotSchema.parse(input);
}
