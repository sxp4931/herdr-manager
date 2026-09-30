import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import { frozenClock, type Clock, scenarios, type AgentSession, type ProviderQuota } from "@herdr/contracts";
import { createDashboardServer } from "../../apps/server/src/http.js";
import { StorageCorruptionError } from "../../apps/server/src/storage/database.js";
import { openStore, type DashboardStore } from "../../apps/server/src/storage/repository.js";

const SENTINEL = "SYNTHETIC_SECRET_SENTINEL";
const cleanup: string[] = [];

function tempDir(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "herdr-sqlite-"));
  cleanup.push(dir);
  return dir;
}

afterEach(() => {
  for (const dir of cleanup.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function movableClock(start: string): Clock & { set(iso: string): void } {
  let current = Date.parse(start);
  return {
    now() {
      return new Date(current);
    },
    set(iso: string) {
      current = Date.parse(iso);
    },
  };
}

function dailyQuota(): ProviderQuota {
  const quota = scenarios.daily.providers.find((provider) => provider.provider === "claude");
  if (!quota) {
    throw new Error("missing claude fixture");
  }
  return structuredClone(quota);
}

function dailySession(): AgentSession {
  const session = scenarios.daily.sessions.find((item) => item.id === "herdr:fixture:ws-claude:pane-claude");
  if (!session) {
    throw new Error("missing claude session");
  }
  return structuredClone(session);
}

function fileContainsSentinel(file: string): boolean {
  const chunks = [file, `${file}-wal`, `${file}-shm`].filter((candidate) => {
    try {
      statSync(candidate);
      return true;
    } catch {
      return false;
    }
  });
  return chunks.some((candidate) => readFileSync(candidate).includes(SENTINEL));
}

describe("sqlite storage", () => {
  it("applies the migration once, keeps dwell across restart, and prunes old samples", () => {
    const dir = tempDir();
    const file = path.join(dir, "dashboard.sqlite");
    const logs: string[] = [];
    const clock = movableClock("2026-09-21T16:00:00.000Z");
    const first = openStore({ file, clock, log: (line) => logs.push(line) });
    const again = openStore({ file, clock, log: (line) => logs.push(line) });
    expect(again.counts().migrations).toBe(1);
    again.close();

    const quota = dailyQuota();
    const session = dailySession();
    session.label = `worker ${SENTINEL} bearer sk-ant-aaaaaaaaaaaa ada@example.com`;
    session.enteredAt = "2026-09-29T15:00:00.000Z";
    expect(first.applyQuota(quota)).toBe("stored");
    expect(first.applyQuota(quota)).toBe("ignored_older");
    first.applySessions([session]);
    const staleQuota = dailyQuota();
    for (const window of staleQuota.windows) {
      window.sampledAt = "2026-09-20T16:00:00.000Z";
    }
    expect(first.applyQuota(staleQuota)).toBe("stored");
    expect(first.counts().quotas).toBe(2);
    clock.set("2026-09-29T16:00:00.000Z");
    first.prune();
    expect(first.counts().quotas).toBe(1);
    expect(first.latestQuota("claude")?.windows[0]?.sampledAt).toBe("2026-09-29T16:00:00.000Z");
    first.close();

    const restarted = openStore({ file, clock, log: (line) => logs.push(line) });
    expect(restarted.latestQuota("claude")?.provider).toBe("claude");
    const preserved = restarted.session(session.id);
    expect(preserved?.enteredAt).toBe("2026-09-29T15:00:00.000Z");
    const reconnect = dailySession();
    reconnect.enteredAt = "2026-09-29T15:50:00.000Z";
    reconnect.observedAt = "2026-09-29T16:05:00.000Z";
    reconnect.status = "idle";
    restarted.applySessions([reconnect]);
    expect(restarted.session(session.id)?.enteredAt).toBe("2026-09-29T15:00:00.000Z");
    expect(restarted.session(session.id)?.status).toBe("idle");

    const replaced = dailySession();
    replaced.sessionIdentity = "different-session";
    replaced.enteredAt = "2026-09-29T16:10:00.000Z";
    replaced.observedAt = "2026-09-29T16:10:00.000Z";
    restarted.applySessions([replaced]);
    expect(restarted.session(session.id)?.enteredAt).toBe("2026-09-29T16:10:00.000Z");

    const older = dailySession();
    older.observedAt = "2026-09-29T15:30:00.000Z";
    older.status = "blocked";
    older.enteredAt = "2026-09-29T12:00:00.000Z";
    restarted.applySessions([older]);
    expect(restarted.session(session.id)?.status).not.toBe("blocked");
    expect(restarted.session(session.id)?.enteredAt).toBe("2026-09-29T16:10:00.000Z");

    expect(fileContainsSentinel(file)).toBe(false);
    expect(logs.join("\n")).not.toContain(SENTINEL);
    expect(JSON.stringify(restarted.session(session.id))).not.toContain(SENTINEL);
    expect(statSync(file).mode & 0o777).toBe(0o600);
    expect(statSync(dir).mode & 0o777).toBe(0o700);
    const wal = `${file}-wal`;
    expect(statSync(wal).mode & 0o777).toBe(0o600);
    restarted.close();
  });

  it("reports corruption without deleting the file", () => {
    const dir = tempDir();
    const file = path.join(dir, "dashboard.sqlite");
    writeFileSync(file, "not a database SYNTHETIC_SECRET_SENTINEL");
    expect(() => openStore({ file, clock: frozenClock("2026-09-29T16:00:00.000Z") })).toThrow(StorageCorruptionError);
    expect(readFileSync(file, "utf8")).toContain("not a database");
  });

  it("stops waiting on a locked database without dropping it", () => {
    const dir = tempDir();
    const file = path.join(dir, "dashboard.sqlite");
    const store = openStore({ file, clock: frozenClock("2026-09-29T16:00:00.000Z"), busyTimeoutMs: 100 });
    store.close();
    const blocker = new DatabaseSync(file);
    blocker.exec("BEGIN EXCLUSIVE");
    let thrown: Error | undefined;
    const started = Date.now();
    try {
      const contending: DashboardStore = openStore({
        file,
        clock: frozenClock("2026-09-29T16:00:00.000Z"),
        busyTimeoutMs: 100,
      });
      contending.close();
    } catch (error) {
      thrown = error as Error;
    }
    const elapsed = Date.now() - started;
    blocker.exec("ROLLBACK");
    blocker.close();
    expect(thrown).toBeInstanceOf(Error);
    expect(elapsed).toBeLessThan(5_000);
    expect(statSync(file).isFile()).toBe(true);
  });

  it("does not echo the sentinel through the health response", async () => {
    const server = createDashboardServer({
      host: "127.0.0.1",
      port: 0,
      webDist: path.resolve("apps/web/dist"),
      mode: "passive",
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
    const address = server.address();
    const port = typeof address === "object" && address ? address.port : 0;
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/nope?token=${SENTINEL}`);
      const body = await response.text();
      expect(response.status).toBe(404);
      expect(body).not.toContain(SENTINEL);
    } finally {
      await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
    }
  });
});
