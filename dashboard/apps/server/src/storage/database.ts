import { chmodSync, existsSync, mkdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";

export class StorageCorruptionError extends Error {
  readonly code = "storage_corrupt";

  constructor(message = "sqlite database failed integrity check") {
    super(message);
    this.name = "StorageCorruptionError";
  }
}

export interface OpenDatabaseOptions {
  file: string;
  busyTimeoutMs?: number;
}

export interface OpenDatabase {
  db: DatabaseSync;
  file: string;
  close(): void;
}

function migrationPath(): string {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    path.join(here, "migrations/001.sql"),
    path.resolve("apps/server/src/storage/migrations/001.sql"),
  ];
  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }
  throw new StorageCorruptionError("migration 001 is missing");
}

function protect(file: string): void {
  const directory = path.dirname(file);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  chmodSync(directory, 0o700);
  if (existsSync(file)) {
    chmodSync(file, 0o600);
  }
  for (const suffix of ["-wal", "-shm"]) {
    const extra = `${file}${suffix}`;
    if (existsSync(extra)) {
      chmodSync(extra, 0o600);
    }
  }
}

export function openDatabase(options: OpenDatabaseOptions): OpenDatabase {
  const file = path.resolve(options.file);
  protect(file);
  if (existsSync(file) && statSync(file).size > 0) {
    const header = readFileSync(file).subarray(0, 16).toString("utf8");
    if (!header.startsWith("SQLite format 3")) {
      throw new StorageCorruptionError("sqlite header is not a database");
    }
  }
  let db: DatabaseSync;
  try {
    db = new DatabaseSync(file);
    db.exec(`PRAGMA busy_timeout = ${Math.max(0, options.busyTimeoutMs ?? 500)}`);
    db.exec("PRAGMA foreign_keys = ON");
    db.exec("PRAGMA journal_mode = WAL");
    const integrity = db.prepare("PRAGMA integrity_check").get() as { integrity_check?: string } | undefined;
    if (!integrity || integrity.integrity_check !== "ok") {
      db.close();
      throw new StorageCorruptionError();
    }
  } catch (error) {
    if (error instanceof StorageCorruptionError) {
      throw error;
    }
    throw new StorageCorruptionError("sqlite open failed");
  }
  protect(file);
  return {
    db,
    file,
    close() {
      db.close();
      protect(file);
    },
  };
}

export function applyMigration(db: DatabaseSync, appliedAt: string): void {
  db.exec("BEGIN IMMEDIATE");
  try {
    const existing = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations'").get() as
      | { name: string }
      | undefined;
    if (existing) {
      const row = db.prepare("SELECT version FROM schema_migrations WHERE version = '001'").get() as { version: string } | undefined;
      if (row) {
        db.exec("COMMIT");
        return;
      }
    }
    db.exec(readFileSync(migrationPath(), "utf8"));
    db.prepare("INSERT INTO schema_migrations (version, applied_at) VALUES ('001', ?)").run(appliedAt);
    db.exec("COMMIT");
  } catch (error) {
    try {
      db.exec("ROLLBACK");
    } catch {
      // The transaction may already be closed.
    }
    throw error;
  }
}

export function migrationCount(db: DatabaseSync): number {
  const row = db.prepare("SELECT COUNT(*) AS count FROM schema_migrations").get() as { count: number };
  return Number(row.count);
}
