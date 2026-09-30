import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { agentSessionSchema, frozenClock } from "@herdr/contracts";
import { createHerdrSource, herdrSessionId, resolveHerdrSocket } from "../../apps/server/src/adapters/herdr-source.js";
import { reconcileSessions } from "../../apps/server/src/services/sessions.js";
import { startFakeHerdr, type FakeHerdr, type FakeHerdrReply, type FakeHerdrRequest } from "../helpers/fake-herdr.js";

const NOW = "2026-09-29T16:00:00.000Z";
const clock = frozenClock(NOW);
const READ_METHODS = new Set(["agent.list", "session.snapshot"]);
const fakes: FakeHerdr[] = [];
const dirs: string[] = [];

function tempDir(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "herdr-socktest-"));
  dirs.push(dir);
  return dir;
}

afterEach(async () => {
  for (const fake of fakes.splice(0)) await fake.close();
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function agent(partial: Record<string, unknown>): Record<string, unknown> {
  return {
    workspace_id: "ws-1",
    tab_id: "tab-1",
    agent_status: "working",
    state_change_seq: 7,
    cwd: "/work/fallback",
    foreground_cwd: "/work/app",
    pid: 4242,
    ...partial,
  };
}

function snapshot(protocol: number, panes: Record<string, unknown>[] = []): Record<string, unknown> {
  return {
    type: "session_snapshot",
    snapshot: {
      version: "0.7.5",
      protocol,
      workspaces: [{ workspace_id: "ws-1", label: "Dash" }],
      tabs: [{ tab_id: "tab-1", workspace_id: "ws-1", label: "Main" }],
      panes,
    },
  };
}

function herdReply(request: FakeHerdrRequest, agents: Record<string, unknown>[], protocol = 17, panes: Record<string, unknown>[] = []): FakeHerdrReply {
  if (request.method === "agent.list") {
    return { type: "result", result: { agents }, error: null };
  }
  if (request.method === "session.snapshot") {
    return { type: "result", result: snapshot(protocol, panes), error: null };
  }
  return { type: "error", error: { code: -32601, message: "unexpected method" } };
}

async function open(respond: (request: FakeHerdrRequest, connection: number) => FakeHerdrReply): Promise<FakeHerdr> {
  const fake = await startFakeHerdr(respond);
  fakes.push(fake);
  return fake;
}

function sourceFor(socketPath: string) {
  return createHerdrSource({ clock, socketPath, environment: { HOME: "/nonexistent-herdr-home" } });
}

describe("herdr unix socket", () => {
  it("reads agents over a real socket and ignores shells", async () => {
    const panes = [
      { pane_id: "pane-claude", label: "snapshot label" },
      { pane_id: "pane-codex", label: "Codex pane" },
      { pane_id: "pane-html", label: "<img src=x onerror=alert(1)>" },
    ];
    const agents = [
      agent({
        pane_id: "pane-claude",
        agent: "claude",
        title: "Review quotas",
        agent_session: { source: "claude", agent: "claude", kind: "session", value: "abc" },
      }),
      agent({
        pane_id: "pane-codex",
        agent: "codex",
        agent_status: "idle",
        title: "",
        display_agent: "",
        name: "",
        pid: 4243,
        state_change_seq: 3,
      }),
      agent({
        pane_id: "pane-grok",
        agent: "grok",
        agent_status: "thinking",
        pid: 4244,
        state_change_seq: 1,
      }),
      agent({ pane_id: "pane-open", agent: "opencode", agent_status: "blocked", pid: 4245, state_change_seq: 2 }),
      agent({ pane_id: "pane-shell", agent: "", agent_status: "idle", pid: 9 }),
      { pane_id: "", agent: "claude", workspace_id: "ws-1" },
      { pane_id: "pane-secret", agent: "claude", title: "task SYNTHETIC_SECRET_SENTINEL", workspace_id: "ws-1", state_change_seq: 4, pid: 4246 },
      { pane_id: "pane-html", agent: "claude", workspace_id: "ws-1", state_change_seq: 5, pid: 4247 },
    ];
    const fake = await open((request) => herdReply(request, agents, 17, panes));
    const observed = await sourceFor(fake.socketPath).collect(new AbortController().signal);
    expect(observed.health).toMatchObject({ status: "ok", reasonCode: "observed", cliVersion: "0.7.5", parserVersion: "herdr-1" });
    expect(observed.sessions.map((session) => session.provider).sort()).toEqual(["claude", "claude", "claude", "codex", "grok", "opencode"]);
    expect(observed.sessions.some((session) => session.paneId === "pane-shell")).toBe(false);
    const claude = observed.sessions.find((session) => session.paneId === "pane-claude");
    expect(claude).toMatchObject({
      id: herdrSessionId(fake.socketPath, "ws-1", "pane-claude"),
      label: "Review quotas",
      cwd: "/work/app",
      status: "working",
      stateChangeSeq: 7,
      sessionIdentity: "claude|claude|session|abc",
      pid: 4242,
      evidenceSource: "herdr",
      confidence: "exact",
    });
    expect(claude?.id.includes(fake.socketPath)).toBe(false);
    expect(observed.sessions.find((session) => session.paneId === "pane-codex")?.label).toBe("Codex pane");
    expect(observed.sessions.find((session) => session.paneId === "pane-grok")).toMatchObject({ status: "unknown", confidence: "unknown" });
    expect(observed.sessions.find((session) => session.paneId === "pane-html")?.label).toBe("<img src=x onerror=alert(1)>");
    expect(observed.sessions.find((session) => session.paneId === "pane-secret")?.label).toContain("[redacted-secret]");
    expect(JSON.stringify(observed)).not.toContain("SYNTHETIC_SECRET_SENTINEL");
    expect(fake.methods.every((method) => READ_METHODS.has(method))).toBe(true);
    expect(fake.methods).toEqual(["agent.list", "session.snapshot"]);
  });

  it("accepts split frames, coalesced lines, numeric ids, and a null error", async () => {
    const fake = await open((request) => {
      if (request.method === "agent.list") {
        return {
          type: "result",
          id: Number(request.id),
          preface: [{ id: "999", result: { agents: [{ pane_id: "stale", agent: "codex", workspace_id: "ws-1" }] } }],
          result: { agents: [agent({ pane_id: "pane-1", agent: "claude", agent_status: "idle", state_change_seq: 4 })] },
          error: null,
        };
      }
      return { type: "split", result: snapshot(17) };
    });
    const observed = await sourceFor(fake.socketPath).collect(new AbortController().signal);
    expect(observed.health.status).toBe("ok");
    expect(observed.sessions.map((session) => session.paneId)).toEqual(["pane-1"]);
    expect(observed.sessions[0]?.stateChangeSeq).toBe(4);
  });

  it("rejects an oversized frame and an error object without inventing an empty herd", async () => {
    const oversized = await open(() => ({ type: "oversize" }));
    const rejected = await sourceFor(oversized.socketPath).collect(new AbortController().signal);
    expect(rejected.health).toMatchObject({ status: "parse_error", reasonCode: "frame_too_large" });
    expect(rejected.sessions).toEqual([]);
    expect(oversized.connections).toBe(1);

    const broken = await open((request) => {
      if (request.method === "agent.list") return { type: "error", error: { code: -32601 } };
      return { type: "result", result: snapshot(17) };
    });
    const failed = await sourceFor(broken.socketPath).collect(new AbortController().signal);
    expect(failed.health).toMatchObject({ status: "parse_error", reasonCode: "herdr_error" });
    expect(failed.sessions).toEqual([]);
    expect(failed.health.status).not.toBe("ok");
  });

  it("times out when a frame never arrives and retries one dropped connection", async () => {
    const silent = await open(() => ({ type: "nonewline", partial: "{\"id\":\"1\",\"result\":{\"agents\":[]}" }));
    const started = Date.now();
    const timed = await sourceFor(silent.socketPath).collect(new AbortController().signal);
    const elapsed = Date.now() - started;
    expect(timed.health).toMatchObject({ status: "timeout", reasonCode: "timeout" });
    expect(timed.sessions).toEqual([]);
    expect(elapsed).toBeGreaterThan(1_500);
    expect(elapsed).toBeLessThan(3_500);

    const resumed = await open((request, connection) => {
      if (connection === 1) return { type: "drop" };
      return herdReply(request, [agent({ pane_id: "pane-1", agent: "grok", agent_status: "done", state_change_seq: 1 })]);
    });
    const observed = await sourceFor(resumed.socketPath).collect(new AbortController().signal);
    expect(observed.health.status).toBe("ok");
    expect(observed.sessions.map((session) => session.provider)).toEqual(["grok"]);
    expect(resumed.connections).toBeGreaterThanOrEqual(2);
    expect(resumed.methods.every((method) => READ_METHODS.has(method))).toBe(true);
  });

  it("keeps the prior read when the socket disappears and drops removed or replaced occupants", async () => {
    const times = [
      "2026-09-29T16:00:00.000Z",
      "2026-09-29T16:00:01.000Z",
      "2026-09-29T16:00:02.000Z",
      "2026-09-29T16:00:03.000Z",
    ];
    let tick = 0;
    let generation = 0;
    const moving = {
      now() {
        return new Date(times[Math.min(tick, times.length - 1)] ?? times[0]);
      },
    };
    const fake = await open((request) => {
      const firstOccupant = agent({
        pane_id: "pane-1",
        agent: "claude",
        agent_session: { source: "claude", agent: "claude", kind: "session", value: "first" },
      });
      const agents = generation === 0
        ? [firstOccupant, agent({ pane_id: "pane-2", agent: "codex", agent_status: "idle", state_change_seq: 2, pid: 50 })]
        : [agent({
            pane_id: "pane-1",
            agent: "claude",
            agent_status: "blocked",
            state_change_seq: 8,
            agent_session: { source: "claude", agent: "claude", kind: "session", value: "second" },
          })];
      return herdReply(request, agents);
    });
    const source = createHerdrSource({ clock: moving, socketPath: fake.socketPath, environment: { HOME: "/nonexistent-herdr-home" } });
    const signal = new AbortController().signal;
    const first = await source.collect(signal);
    expect(first.sessions.map((session) => session.paneId).sort()).toEqual(["pane-1", "pane-2"]);
    tick = 1;
    const same = await source.collect(signal);
    expect(same.sessions.find((session) => session.paneId === "pane-1")).toMatchObject({
      enteredAt: times[0],
      observedAt: times[1],
      sessionIdentity: "claude|claude|session|first",
    });
    tick = 2;
    generation = 1;
    const replaced = await source.collect(signal);
    expect(replaced.sessions.map((session) => session.paneId)).toEqual(["pane-1"]);
    expect(replaced.sessions[0]).toMatchObject({
      sessionIdentity: "claude|claude|session|second",
      status: "blocked",
      stateChangeSeq: 8,
      enteredAt: times[2],
    });

    await fake.close();
    fakes.splice(fakes.indexOf(fake), 1);
    tick = 3;
    const lost = await source.collect(signal);
    expect(lost.health).toMatchObject({ status: "stale", reasonCode: "herdr_unavailable", lastSuccessAt: times[2] });
    expect(lost.health.checkedAt).toBe(times[3]);
    expect(lost.sessions).toEqual(replaced.sessions);
  });

  it("reports old and new protocols without sending a write", async () => {
    const oldServer = await open((request) => herdReply(request, [agent({ pane_id: "pane-1", agent: "claude" })], 16));
    const old = await sourceFor(oldServer.socketPath).collect(new AbortController().signal);
    expect(old.health).toMatchObject({ status: "unsupported", reasonCode: "protocol_older" });
    expect(old.sessions).toHaveLength(1);

    const newServer = await open((request) => herdReply(request, [agent({ pane_id: "pane-1", agent: "codex", agent_status: "idle" })], 18));
    const newer = await sourceFor(newServer.socketPath).collect(new AbortController().signal);
    expect(newer.health).toMatchObject({ status: "ok", reasonCode: "protocol_newer" });
    expect(newer.sessions).toHaveLength(1);

    const adapter = readFileSync(new URL("../../apps/server/src/adapters/herdr-source.ts", import.meta.url), "utf8");
    expect(adapter.includes("agent.list")).toBe(true);
    expect(adapter.includes("session.snapshot")).toBe(true);
    expect(adapter.includes("agent.answer")).toBe(false);
    expect(adapter.includes("agent.say")).toBe(false);
    expect(adapter.includes("agent.stop")).toBe(false);
    expect(adapter.includes("session.spawn")).toBe(false);
    expect([...oldServer.methods, ...newServer.methods].every((method) => READ_METHODS.has(method))).toBe(true);
  });

  it("resolves a named session file and reports an unresolved name", async () => {
    const root = tempDir();
    const outside = tempDir();
    const sessionDir = path.join(root, "herdr", "sessions", "alpha");
    mkdirSync(sessionDir, { recursive: true });
    const socketPath = path.join(sessionDir, "herdr.sock");
    writeFileSync(socketPath, "");
    expect(resolveHerdrSocket({ XDG_CONFIG_HOME: root, HERDR_SESSION: "alpha" })).toEqual({
      socketPath,
      sessionUnresolved: false,
    });
    expect(resolveHerdrSocket({ XDG_CONFIG_HOME: root, HERDR_SESSION: "alpha", HERDR_SOCKET_PATH: "/explicit.sock" }).socketPath).toBe("/explicit.sock");
    const outsideSock = path.join(outside, "escaped.sock");
    writeFileSync(outsideSock, "");
    const escapedDir = path.join(root, "herdr", "sessions", "beta");
    mkdirSync(escapedDir, { recursive: true });
    symlinkSync(outsideSock, path.join(escapedDir, "herdr.sock"));
    const escaped = resolveHerdrSocket({ XDG_CONFIG_HOME: root, HERDR_SESSION: "beta" });
    expect(escaped.sessionUnresolved).toBe(true);
    expect(escaped.socketPath).not.toBe(outsideSock);

    const missing = await createHerdrSource({
      clock,
      environment: { HOME: root, HERDR_SESSION: "nope" },
    }).collect(new AbortController().signal);
    expect(missing.health).toMatchObject({ status: "missing", reasonCode: "session_unresolved" });
    expect(missing.sessions).toEqual([]);
  });

  it("merges herdr and tmux only when pid, cwd, and provider agree", () => {
    const base = {
      provider: "claude",
      sessionIdentity: null,
      workspaceId: "ws-1",
      label: "claude",
      cwd: "/work/app",
      stateChangeSeq: 0,
      enteredAt: NOW,
      lastOutputAt: null,
      observedAt: NOW,
      confidence: "unknown" as const,
      pid: 4242,
      loop: null,
    };
    const herdr = agentSessionSchema.parse({
      ...base,
      id: "herdr:abc:ws-1:pane-1",
      runtime: "herdr",
      paneId: "pane-1",
      status: "working",
      stateChangeSeq: 6,
      evidenceSource: "herdr",
      confidence: "exact",
    });
    const tmux = agentSessionSchema.parse({
      ...base,
      id: "tmux:abc:%1",
      runtime: "tmux",
      paneId: "%1",
      status: "unknown",
      evidenceSource: "tmux",
      loop: { kind: "goal", state: "running", iteration: 2, objective: "Refresh the dashboard fixture", source: "manifest" },
    });
    const other = agentSessionSchema.parse({
      ...base,
      id: "tmux:abc:%2",
      runtime: "tmux",
      paneId: "%2",
      cwd: "/work/other",
      pid: 99,
      status: "unknown",
      evidenceSource: "tmux",
    });
    const uncertain = agentSessionSchema.parse({
      ...base,
      id: "tmux:abc:%3",
      runtime: "tmux",
      paneId: "%3",
      pid: null,
      status: "unknown",
      evidenceSource: "tmux",
    });
    const merged = reconcileSessions([herdr], [tmux, other, uncertain]);
    expect(merged).toHaveLength(3);
    expect(merged[0]).toMatchObject({
      id: herdr.id,
      status: "working",
      stateChangeSeq: 6,
      evidenceSource: "manifest",
      loop: { kind: "goal", state: "running", source: "manifest" },
    });
    expect(merged.map((session) => session.id)).toEqual([herdr.id, other.id, uncertain.id]);
  });
});
