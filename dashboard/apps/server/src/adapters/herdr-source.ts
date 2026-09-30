import { createHash } from "node:crypto";
import { existsSync, lstatSync, realpathSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import {
  agentSessionSchema,
  sourceHealthSchema,
  type AgentSession,
  type Clock,
  type SessionSource,
  type SourceHealth,
} from "@herdr/contracts";
import { redactText } from "../services/redaction.js";

const MAX_FRAME_BYTES = 4 * 1024 * 1024;
const DEADLINE_MS = 2_000;
const PARSER_VERSION = "herdr-1";
const BASELINE_PROTOCOL = 17;
const STATUSES = new Set(["idle", "working", "blocked", "done", "unknown"]);

type ReadReason = "timeout" | "frame_too_large" | "connect" | "closed" | "protocol" | "invalid";

class HerdrReadError extends Error {
  constructor(readonly reason: ReadReason) {
    super(reason);
    this.name = "HerdrReadError";
  }
}

export interface ResolvedHerdrSocket {
  socketPath: string;
  sessionUnresolved: boolean;
}

export interface HerdrSourceOptions {
  clock: Clock;
  socketPath?: string | null;
  environment?: NodeJS.ProcessEnv;
}

interface PriorRead {
  sessions: AgentSession[];
  lastSuccessAt: string;
}

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex").slice(0, 16);
}

function clip(value: string, max: number): string {
  return Array.from(redactText(value).replace(/\s+/g, " ").trim()).slice(0, max).join("");
}

function defaultSocket(environment: NodeJS.ProcessEnv): string {
  const xdg = environment.XDG_CONFIG_HOME?.trim();
  if (xdg) return path.join(xdg, "herdr", "herdr.sock");
  const home = environment.HOME?.trim() || "/nonexistent";
  return path.join(home, ".config", "herdr", "herdr.sock");
}

function sessionSocket(environment: NodeJS.ProcessEnv, name: string): string | null {
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(name)) return null;
  const xdg = environment.XDG_CONFIG_HOME?.trim();
  const home = environment.HOME?.trim();
  const base = xdg || (home ? path.join(home, ".config") : "");
  if (!base) return null;
  const root = path.resolve(base);
  const candidate = path.resolve(root, "herdr", "sessions", name, "herdr.sock");
  if (candidate !== root && !candidate.startsWith(`${root}${path.sep}`)) return null;
  if (!existsSync(candidate)) return null;
  try {
    if (lstatSync(candidate).isSymbolicLink()) {
      const real = realpathSync(candidate);
      const realRoot = realpathSync(root);
      if (real !== realRoot && !real.startsWith(`${realRoot}${path.sep}`)) return null;
    }
  } catch {
    return null;
  }
  return candidate;
}

/** Config socket, then HERDR_SOCKET_PATH, then a named session file, then the XDG default. */
export function resolveHerdrSocket(environment: NodeJS.ProcessEnv, explicit?: string | null): ResolvedHerdrSocket {
  const configured = explicit?.trim();
  if (configured) return { socketPath: configured, sessionUnresolved: false };
  const override = environment.HERDR_SOCKET_PATH?.trim();
  if (override) return { socketPath: override, sessionUnresolved: false };
  const session = environment.HERDR_SESSION?.trim();
  if (session) {
    const named = sessionSocket(environment, session);
    if (named) return { socketPath: named, sessionUnresolved: false };
    return { socketPath: defaultSocket(environment), sessionUnresolved: true };
  }
  return { socketPath: defaultSocket(environment), sessionUnresolved: false };
}

function wholeNumber(value: unknown): number | null {
  if (typeof value === "boolean") return null;
  if (typeof value === "number" && Number.isSafeInteger(value)) return value;
  if (typeof value === "string" && /^-?\d+$/.test(value.trim())) {
    const parsed = Number(value.trim());
    return Number.isSafeInteger(parsed) ? parsed : null;
  }
  return null;
}

function record(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
}

function text(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function matchesId(message: Record<string, unknown>, expected: string): boolean {
  const id = message.id;
  if (typeof id === "string") return id === expected;
  if (typeof id === "number" && Number.isInteger(id) && Number.isSafeInteger(id)) return String(id) === expected;
  return false;
}

function unwrap(message: Record<string, unknown>): unknown {
  if ("error" in message && message.error !== null && message.error !== undefined) {
    throw new HerdrReadError("protocol");
  }
  if (record(message.result)) return message.result;
  return message;
}

function budgetSignal(parent: AbortSignal, deadlineAt: number): AbortSignal {
  const remaining = Math.max(0, deadlineAt - Date.now());
  const timeout = AbortSignal.timeout(remaining);
  return AbortSignal.any([parent, timeout]);
}

function connectSocket(socketPath: string, signal: AbortSignal): Promise<net.Socket> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(new HerdrReadError("timeout"));
      return;
    }
    const socket = net.createConnection(socketPath);
    const fail = (error: Error): void => {
      socket.destroy();
      reject(error);
    };
    const onAbort = (): void => fail(new HerdrReadError("timeout"));
    signal.addEventListener("abort", onAbort, { once: true });
    socket.once("connect", () => {
      signal.removeEventListener("abort", onAbort);
      resolve(socket);
    });
    socket.once("error", () => {
      signal.removeEventListener("abort", onAbort);
      fail(new HerdrReadError("connect"));
    });
  });
}

function writeLine(socket: net.Socket, line: string, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(new HerdrReadError("timeout"));
      return;
    }
    const onAbort = (): void => reject(new HerdrReadError("timeout"));
    signal.addEventListener("abort", onAbort, { once: true });
    socket.write(line, (error) => {
      signal.removeEventListener("abort", onAbort);
      if (error) reject(new HerdrReadError("closed"));
      else resolve();
    });
  });
}

function drainFrames(buffer: Uint8Array, expectedId: string): { rest: Uint8Array; value?: unknown; error?: HerdrReadError } {
  let rest = buffer;
  while (rest.length > 0) {
    const newline = rest.indexOf(0x0a);
    if (newline === -1) {
      if (rest.length > MAX_FRAME_BYTES) return { rest, error: new HerdrReadError("frame_too_large") };
      return { rest };
    }
    if (newline + 1 > MAX_FRAME_BYTES) return { rest, error: new HerdrReadError("frame_too_large") };
    const line = Buffer.from(rest.subarray(0, newline)).toString("utf8");
    rest = rest.subarray(newline + 1);
    if (line.trim() === "") continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      continue;
    }
    const message = record(parsed);
    if (!message || !matchesId(message, expectedId)) continue;
    try {
      return { rest, value: unwrap(message) };
    } catch (error) {
      return { rest, error: error instanceof HerdrReadError ? error : new HerdrReadError("invalid") };
    }
  }
  return { rest };
}

function readResponse(socket: net.Socket, expectedId: string, signal: AbortSignal): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let buffer: Uint8Array = new Uint8Array(0);
    let settled = false;
    const finish = (fn: () => void): void => {
      if (settled) return;
      settled = true;
      socket.off("data", onData);
      socket.off("error", onError);
      socket.off("end", onEnd);
      signal.removeEventListener("abort", onAbort);
      fn();
    };
    const fail = (error: Error): void => finish(() => reject(error));
    const succeed = (value: unknown): void => finish(() => resolve(value));
    const onAbort = (): void => fail(new HerdrReadError("timeout"));
    const onError = (): void => fail(new HerdrReadError("closed"));
    const onEnd = (): void => fail(new HerdrReadError("closed"));
    const onData = (chunk: Uint8Array): void => {
      if (settled) return;
      buffer = Buffer.concat([buffer, chunk]);
      const drained = drainFrames(buffer, expectedId);
      buffer = drained.rest;
      if (drained.error) {
        fail(drained.error);
        return;
      }
      if (drained.value !== undefined) succeed(drained.value);
    };
    if (signal.aborted) {
      fail(new HerdrReadError("timeout"));
      return;
    }
    signal.addEventListener("abort", onAbort, { once: true });
    socket.on("data", onData);
    socket.on("error", onError);
    socket.on("end", onEnd);
  });
}

async function exchange(socketPath: string, id: string, method: string, signal: AbortSignal): Promise<unknown> {
  const socket = await connectSocket(socketPath, signal);
  const pending = readResponse(socket, id, signal);
  try {
    await writeLine(socket, `${JSON.stringify({ id, method, params: {} })}\n`, signal);
    return await pending;
  } catch (error) {
    socket.destroy();
    await pending.catch(() => undefined);
    throw error;
  } finally {
    socket.destroy();
  }
}

async function readMethod(socketPath: string, id: string, method: string, parent: AbortSignal, deadlineAt: number): Promise<unknown> {
  let last = new HerdrReadError("connect");
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const signal = budgetSignal(parent, deadlineAt);
    if (signal.aborted) break;
    try {
      return await exchange(socketPath, id, method, signal);
    } catch (error) {
      last = error instanceof HerdrReadError ? error : new HerdrReadError("closed");
      if (last.reason === "frame_too_large" || last.reason === "protocol" || last.reason === "invalid") throw last;
    }
  }
  throw last;
}

function sessionIdentityOf(value: unknown): string | null {
  const session = record(value);
  if (!session) return null;
  const source = text(session.source) ?? "";
  const agent = text(session.agent) ?? "";
  const kind = text(session.kind) ?? "";
  const raw = text(session.value);
  if (!raw) return null;
  const identity = clip(`${source}|${agent}|${kind}|${raw}`, 120);
  return identity.length > 0 ? identity : null;
}

function statusOf(value: unknown): AgentSession["status"] {
  return typeof value === "string" && STATUSES.has(value) ? (value as AgentSession["status"]) : "unknown";
}

function cwdOf(agent: Record<string, unknown>, snapshotCwd: string | undefined): string | null {
  const raw = text(agent.foreground_cwd) ?? text(agent.cwd) ?? snapshotCwd ?? null;
  if (!raw) return null;
  const redacted = redactText(raw);
  return redacted.length > 0 && redacted.length <= 400 ? redacted : null;
}

function labelOf(agent: Record<string, unknown>, paneLabel: string | undefined, provider: string): string {
  const preferred = text(agent.title)
    ?? text(agent.display_agent)
    ?? text(agent.name)
    ?? paneLabel
    ?? text(agent.terminal_title_stripped)
    ?? provider;
  return clip(preferred, 160);
}

function pidOf(agent: Record<string, unknown>): number | null {
  const pid = wholeNumber(agent.pid) ?? wholeNumber(agent.shell_pid);
  return pid !== null && pid > 0 ? pid : null;
}

function workspaceOf(value: unknown): string {
  const raw = text(value) ?? "unknown";
  return raw.length <= 120 ? raw : digest(raw);
}

interface SnapshotFacts {
  protocol: number | null;
  version: string | null;
  paneLabels: Map<string, string>;
  paneCwd: Map<string, string>;
}

function snapshotFacts(payload: unknown): SnapshotFacts {
  const root = record(payload) ?? {};
  const snap = record(root.snapshot) ?? root;
  const protocol = wholeNumber(snap.protocol);
  const labels = new Map<string, string>();
  const cwds = new Map<string, string>();
  const panes = Array.isArray(snap.panes) ? snap.panes : [];
  for (const entry of panes) {
    const pane = record(entry);
    const paneId = text(pane?.pane_id);
    if (!pane || !paneId) continue;
    const label = text(pane.label);
    if (label) labels.set(paneId, label);
    const cwd = text(pane.foreground_cwd) ?? text(pane.cwd);
    if (cwd) cwds.set(paneId, cwd);
  }
  return {
    protocol: protocol !== null && protocol >= 0 ? protocol : null,
    version: text(snap.version),
    paneLabels: labels,
    paneCwd: cwds,
  };
}

export function herdrSessionId(socketKey: string, workspaceId: string, paneId: string): string {
  const prefix = `herdr:${digest(socketKey)}:`;
  const rest = `${workspaceId}:${paneId}`;
  if (prefix.length + rest.length <= 200) return `${prefix}${rest}`;
  return `${prefix}${digest(rest)}`;
}

function sessionsFromList(payload: unknown, facts: SnapshotFacts, socketKey: string, now: string, prior: AgentSession[]): AgentSession[] {
  const root = record(payload);
  const agents = Array.isArray(root?.agents) ? root.agents : [];
  const previous = new Map(prior.map((session) => [session.id, session]));
  const sessions: AgentSession[] = [];
  for (const entry of agents) {
    const agent = record(entry);
    const paneId = text(agent?.pane_id);
    const provider = text(agent?.agent);
    if (!agent || !paneId || !provider || paneId.length > 120) continue;
    const seqValue = agent.state_change_seq;
    const seq = seqValue === undefined || seqValue === null ? 0 : wholeNumber(seqValue);
    if (seq === null || seq < 0) continue;
    const workspaceId = workspaceOf(agent.workspace_id);
    const id = herdrSessionId(socketKey, workspaceId, paneId);
    const sessionIdentity = sessionIdentityOf(agent.agent_session);
    const status = statusOf(agent.agent_status);
    const reportedStatus = text(agent.agent_status);
    const previousSession = previous.get(id);
    const sameOccupant = previousSession?.sessionIdentity === sessionIdentity;
    const enteredAt = sameOccupant ? previousSession.enteredAt : now;
    const parsed = agentSessionSchema.safeParse({
      id,
      provider: clip(provider, 40),
      runtime: "herdr",
      sessionIdentity,
      workspaceId,
      paneId,
      label: labelOf(agent, facts.paneLabels.get(paneId), provider),
      cwd: cwdOf(agent, facts.paneCwd.get(paneId)),
      status,
      stateChangeSeq: seq,
      enteredAt,
      lastOutputAt: null,
      observedAt: now,
      evidenceSource: "herdr",
      confidence: status === "unknown" && reportedStatus !== "unknown" ? "unknown" : "exact",
      pid: pidOf(agent),
      loop: null,
    });
    if (parsed.success) sessions.push(parsed.data);
  }
  return sessions;
}

function protocolHealth(protocol: number | null, sessionUnresolved: boolean): { status: SourceHealth["status"]; reasonCode: string } {
  if (sessionUnresolved) return { status: "ok", reasonCode: "session_unresolved" };
  if (protocol === null) return { status: "unsupported", reasonCode: "protocol_unknown" };
  if (protocol < BASELINE_PROTOCOL) return { status: "unsupported", reasonCode: "protocol_older" };
  if (protocol > BASELINE_PROTOCOL) return { status: "ok", reasonCode: "protocol_newer" };
  return { status: "ok", reasonCode: "observed" };
}

function makeHealth(
  status: SourceHealth["status"],
  reasonCode: string,
  now: string,
  lastSuccessAt: string | null,
  cliVersion: string | null,
): SourceHealth {
  return sourceHealthSchema.parse({
    sourceId: "herdr",
    status,
    checkedAt: now,
    lastSuccessAt,
    reasonCode,
    cliVersion,
    parserVersion: PARSER_VERSION,
    provenance: "live",
  });
}

function failureStatus(reason: ReadReason): SourceHealth["status"] {
  if (reason === "timeout") return "timeout";
  if (reason === "frame_too_large" || reason === "protocol" || reason === "invalid") return "parse_error";
  return "missing";
}

function failureReason(reason: ReadReason): string {
  if (reason === "timeout") return "timeout";
  if (reason === "frame_too_large") return "frame_too_large";
  if (reason === "protocol" || reason === "invalid") return "herdr_error";
  return "herdr_unavailable";
}

export function createHerdrSource(options: HerdrSourceOptions): SessionSource {
  let prior: PriorRead | null = null;
  let requestSerial = 0;
  return {
    async collect(signal) {
      const now = options.clock.now().toISOString();
      const resolved = resolveHerdrSocket(options.environment ?? process.env, options.socketPath);
      const deadlineAt = Date.now() + DEADLINE_MS;
      try {
        const agentsPayload = await readMethod(resolved.socketPath, String(++requestSerial), "agent.list", signal, deadlineAt);
        const snapshotPayload = await readMethod(resolved.socketPath, String(++requestSerial), "session.snapshot", signal, deadlineAt);
        const facts = snapshotFacts(snapshotPayload);
        const sessions = sessionsFromList(agentsPayload, facts, resolved.socketPath, now, prior?.sessions ?? []);
        const protocol = protocolHealth(facts.protocol, resolved.sessionUnresolved);
        const cliVersion = facts.version ?? (facts.protocol === null ? null : String(facts.protocol));
        prior = { sessions, lastSuccessAt: now };
        return {
          sessions,
          health: makeHealth(protocol.status, protocol.reasonCode, now, now, cliVersion ? clip(cliVersion, 80) : null),
        };
      } catch (error) {
        const reason = error instanceof HerdrReadError ? error.reason : "closed";
        if (prior) {
          return {
            sessions: prior.sessions,
            health: makeHealth("stale", failureReason(reason), now, prior.lastSuccessAt, null),
          };
        }
        const reasonCode = resolved.sessionUnresolved ? "session_unresolved" : failureReason(reason);
        return {
          sessions: [],
          health: makeHealth(failureStatus(reason), reasonCode, now, null, null),
        };
      }
    },
  };
}
