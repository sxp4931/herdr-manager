import type { AgentSession, Alert, DashboardSnapshot, GitWorktree, ProviderId, ProviderQuota, SourceHealth } from "./schemas.js";

export interface Clock {
  now(): Date;
}

export interface CommandRequest {
  executable: string;
  args: string[];
  cwd: string;
  timeoutMs: number;
  maxBytes: number;
  allowedEnvironment: Record<string, string>;
}

export interface CommandResult {
  code: number | null;
  stdout: string;
  stderr: string;
}

export interface CommandRunner {
  run(request: CommandRequest, signal: AbortSignal): Promise<CommandResult>;
}

export interface SessionCollectResult {
  sessions: AgentSession[];
  health: SourceHealth;
}

export interface SessionSource {
  collect(signal: AbortSignal): Promise<SessionCollectResult>;
}

export interface QuotaSource {
  collect(provider: ProviderId, signal: AbortSignal): Promise<ProviderQuota>;
}

export interface GitCollectResult {
  worktrees: GitWorktree[];
  health: SourceHealth;
}

export interface GitSource {
  collect(roots: string[], signal: AbortSignal): Promise<GitCollectResult>;
}

export interface AlertCoverage {
  sessionsFresh: boolean;
  sessionsComplete: boolean;
}

export interface AlertEngine {
  evaluate(snapshot: DashboardSnapshot, now: Date, coverage: AlertCoverage): Alert[];
}

/** A normalized observation. Raw terminal text is never part of this type. */
export type Observation =
  | { kind: "quota"; observedAt: string; quota: ProviderQuota }
  | { kind: "sessions"; observedAt: string; sessions: AgentSession[]; health: SourceHealth }
  | { kind: "git"; observedAt: string; worktrees: GitWorktree[]; health: SourceHealth }
  | { kind: "health"; observedAt: string; health: SourceHealth };

export interface SnapshotRepository {
  read(): DashboardSnapshot | null;
  apply(observation: Observation): void;
}

export function systemClock(): Clock {
  return {
    now() {
      return new Date();
    },
  };
}

export function frozenClock(isoUtc: string): Clock {
  const fixed = Date.parse(isoUtc);
  return {
    now() {
      return new Date(fixed);
    },
  };
}
