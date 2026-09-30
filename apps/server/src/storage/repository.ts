import type { DatabaseSync } from "node:sqlite";
import {
  agentSessionSchema,
  gitWorktreeSchema,
  providerQuotaSchema,
  sourceHealthSchema,
  type AgentSession,
  type Clock,
  type GitWorktree,
  type ProviderId,
  type ProviderQuota,
  type SourceHealth,
} from "@herdr/contracts";
import { assertNoSentinel, redactStored } from "../services/redaction.js";
import { applyMigration, openDatabase, type OpenDatabase } from "./database.js";

const DAY_MS = 24 * 60 * 60 * 1000;
const QUOTA_RETENTION_MS = 7 * DAY_MS;
const DISAPPEAR_MS = DAY_MS;

export interface StoreOptions {
  file: string;
  clock: Clock;
  log?: (line: string) => void;
  busyTimeoutMs?: number;
}

export interface DashboardStore {
  file: string;
  applyQuota(quota: ProviderQuota): "stored" | "ignored_older";
  applySessions(sessions: AgentSession[]): void;
  applyGit(worktrees: GitWorktree[]): void;
  applyHealth(health: SourceHealth): void;
  latestQuota(provider: ProviderId): ProviderQuota | null;
  listQuotas(): ProviderQuota[];
  listSessions(): AgentSession[];
  listWorktrees(): GitWorktree[];
  listHealth(): SourceHealth[];
  session(id: string): AgentSession | null;
  counts(): { quotas: number; sessions: number; migrations: number };
  prune(): void;
  close(): void;
}

interface SessionRow {
  session_identity: string | null;
  entered_at: string;
  observed_at: string;
  payload_json: string;
}

function sampleTime(quota: ProviderQuota): string {
  const stamps = quota.windows.map((window) => window.sampledAt);
  if (quota.bankedResets) {
    for (const reset of quota.bankedResets) {
      stamps.push(reset.sampledAt);
    }
  }
  stamps.sort();
  return stamps[stamps.length - 1] ?? quota.health.checkedAt;
}

function parseStored<T>(schema: { parse(input: unknown): T }, payload: string): T {
  assertNoSentinel(payload);
  return schema.parse(JSON.parse(payload) as unknown);
}

export function openStore(options: StoreOptions): DashboardStore {
  const opened = openDatabase({
    file: options.file,
    ...(options.busyTimeoutMs !== undefined ? { busyTimeoutMs: options.busyTimeoutMs } : {}),
  });
  applyMigration(opened.db, options.clock.now().toISOString());
  const log = options.log ?? (() => undefined);
  const store = new SqliteStore(opened, options.clock, log);
  store.prune();
  return store;
}

class SqliteStore implements DashboardStore {
  readonly file: string;

  constructor(
    private readonly opened: OpenDatabase,
    private readonly clock: Clock,
    private readonly log: (line: string) => void,
  ) {
    this.file = opened.file;
  }

  private get db(): DatabaseSync {
    return this.opened.db;
  }

  applyQuota(quota: ProviderQuota): "stored" | "ignored_older" {
    const redacted = providerQuotaSchema.parse(redactStored(quota));
    const sampledAt = sampleTime(redacted);
    const id = `${redacted.provider}:${sampledAt}`;
    const existing = this.db.prepare("SELECT sampled_at FROM quota_samples WHERE id = ?").get(id) as
      | { sampled_at: string }
      | undefined;
    if (existing && existing.sampled_at >= sampledAt) {
      this.log(`quota ignored duplicate ${redacted.provider}`);
      return "ignored_older";
    }
    const payload = JSON.stringify(redacted);
    assertNoSentinel(payload);
    this.db
      .prepare(
        `INSERT INTO quota_samples (id, provider, sampled_at, payload_json)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET payload_json = excluded.payload_json
         WHERE excluded.sampled_at >= quota_samples.sampled_at`,
      )
      .run(id, redacted.provider, sampledAt, payload);
    this.applyHealth(redacted.health);
    this.prune();
    this.log(`quota stored ${redacted.provider}`);
    return "stored";
  }

  applySessions(sessions: AgentSession[]): void {
    const redacted = sessions.map((session) => agentSessionSchema.parse(redactStored(session)));
    const seen = new Set<string>();
    const write = this.db.prepare(
      `INSERT INTO session_state
        (id, session_identity, status, entered_at, last_output_at, observed_at, payload_json)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         session_identity = excluded.session_identity,
         status = excluded.status,
         entered_at = excluded.entered_at,
         last_output_at = excluded.last_output_at,
         observed_at = excluded.observed_at,
         payload_json = excluded.payload_json`,
    );
    for (const session of redacted) {
      seen.add(session.id);
      const existing = this.db
        .prepare("SELECT session_identity, entered_at, observed_at, payload_json FROM session_state WHERE id = ?")
        .get(session.id) as SessionRow | undefined;
      if (existing && existing.observed_at > session.observedAt) {
        this.log(`session ignored older ${session.id}`);
        continue;
      }
      let enteredAt = session.enteredAt;
      if (
        existing &&
        existing.session_identity !== null &&
        session.sessionIdentity !== null &&
        existing.session_identity === session.sessionIdentity
      ) {
        const previous = agentSessionSchema.parse(JSON.parse(existing.payload_json) as unknown);
        if (previous.pid === null || session.pid === null || previous.pid === session.pid) {
          enteredAt = existing.entered_at;
        }
      }
      const stored = { ...session, enteredAt };
      const payload = JSON.stringify(stored);
      assertNoSentinel(payload);
      write.run(stored.id, stored.sessionIdentity, stored.status, stored.enteredAt, stored.lastOutputAt, stored.observedAt, payload);
      this.log(`session stored ${stored.id}`);
    }
    const rows = this.db.prepare("SELECT id, observed_at FROM session_state").all() as { id: string; observed_at: string }[];
    const cutoff = this.clock.now().getTime() - DISAPPEAR_MS;
    const remove = this.db.prepare("DELETE FROM session_state WHERE id = ?");
    for (const row of rows) {
      if (seen.has(row.id)) {
        continue;
      }
      if (Date.parse(row.observed_at) < cutoff) {
        remove.run(row.id);
        this.log(`session aged out ${row.id}`);
      }
    }
  }

  applyGit(worktrees: GitWorktree[]): void {
    const write = this.db.prepare(
      `INSERT INTO git_cache (id, payload_json) VALUES (?, ?)
       ON CONFLICT(id) DO UPDATE SET payload_json = excluded.payload_json`,
    );
    for (const worktree of worktrees) {
      const redacted = gitWorktreeSchema.parse(redactStored(worktree));
      const existing = this.db.prepare("SELECT payload_json FROM git_cache WHERE id = ?").get(redacted.id) as
        | { payload_json: string }
        | undefined;
      if (existing) {
        const previous = gitWorktreeSchema.parse(JSON.parse(existing.payload_json) as unknown);
        if (previous.observedAt > redacted.observedAt) {
          this.log(`git ignored older ${redacted.id}`);
          continue;
        }
      }
      const payload = JSON.stringify(redacted);
      assertNoSentinel(payload);
      write.run(redacted.id, payload);
      this.log(`git stored ${redacted.id}`);
    }
  }

  applyHealth(health: SourceHealth): void {
    const redacted = sourceHealthSchema.parse(redactStored(health));
    const existing = this.db.prepare("SELECT payload_json FROM source_health WHERE source_id = ?").get(redacted.sourceId) as
      | { payload_json: string }
      | undefined;
    if (existing) {
      const previous = sourceHealthSchema.parse(JSON.parse(existing.payload_json) as unknown);
      if (previous.checkedAt > redacted.checkedAt) {
        this.log(`health ignored older ${redacted.sourceId}`);
        return;
      }
    }
    const payload = JSON.stringify(redacted);
    assertNoSentinel(payload);
    this.db
      .prepare(
        `INSERT INTO source_health (source_id, payload_json) VALUES (?, ?)
         ON CONFLICT(source_id) DO UPDATE SET payload_json = excluded.payload_json`,
      )
      .run(redacted.sourceId, payload);
  }

  latestQuota(provider: ProviderId): ProviderQuota | null {
    const row = this.db
      .prepare("SELECT payload_json FROM quota_samples WHERE provider = ? ORDER BY sampled_at DESC LIMIT 1")
      .get(provider) as { payload_json: string } | undefined;
    if (!row) {
      return null;
    }
    return parseStored(providerQuotaSchema, row.payload_json);
  }

  listQuotas(): ProviderQuota[] {
    const quotas: ProviderQuota[] = [];
    for (const provider of ["claude", "codex", "grok"] as const) {
      const quota = this.latestQuota(provider);
      if (quota) quotas.push(quota);
    }
    return quotas;
  }

  listSessions(): AgentSession[] {
    const rows = this.db.prepare("SELECT payload_json FROM session_state ORDER BY id").all() as { payload_json: string }[];
    return rows.map((row) => parseStored(agentSessionSchema, row.payload_json));
  }

  listWorktrees(): GitWorktree[] {
    const rows = this.db.prepare("SELECT payload_json FROM git_cache ORDER BY id").all() as { payload_json: string }[];
    return rows.map((row) => parseStored(gitWorktreeSchema, row.payload_json));
  }

  listHealth(): SourceHealth[] {
    const rows = this.db.prepare("SELECT payload_json FROM source_health ORDER BY source_id").all() as {
      payload_json: string;
    }[];
    return rows.map((row) => parseStored(sourceHealthSchema, row.payload_json));
  }

  session(id: string): AgentSession | null {
    const row = this.db.prepare("SELECT payload_json FROM session_state WHERE id = ?").get(id) as
      | { payload_json: string }
      | undefined;
    if (!row) {
      return null;
    }
    return parseStored(agentSessionSchema, row.payload_json);
  }

  counts(): { quotas: number; sessions: number; migrations: number } {
    const quotas = this.db.prepare("SELECT COUNT(*) AS count FROM quota_samples").get() as { count: number };
    const sessions = this.db.prepare("SELECT COUNT(*) AS count FROM session_state").get() as { count: number };
    const migrations = this.db.prepare("SELECT COUNT(*) AS count FROM schema_migrations").get() as { count: number };
    return { quotas: Number(quotas.count), sessions: Number(sessions.count), migrations: Number(migrations.count) };
  }

  prune(): void {
    const cutoff = new Date(this.clock.now().getTime() - QUOTA_RETENTION_MS).toISOString();
    this.db.prepare("DELETE FROM quota_samples WHERE sampled_at < ?").run(cutoff);
  }

  close(): void {
    this.opened.close();
  }
}
