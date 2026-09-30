import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  agentSessionSchema,
  sourceHealthSchema,
  type AgentSession,
  type Clock,
  type CommandResult,
  type CommandRunner,
  type SessionSource,
  type SourceHealth,
} from "@herdr/contracts";
import { CommandDeniedError } from "./command-runner.js";
import { findProvider, type ProcessLookup, type ProviderName } from "../services/identity.js";
import { readLoopManifest } from "../services/loop-manifest.js";
import { inspectProcess } from "../services/process-info.js";
import { redactText } from "../services/redaction.js";

export const TMUX_PANE_FORMAT = "#{session_id}\t#{session_name}\t#{window_id}\t#{window_name}\t#{pane_id}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_dead}";
const PARSER_VERSION = "tmux-1";

export interface TmuxPane {
  sessionId: string;
  sessionName: string;
  windowId: string;
  windowName: string;
  paneId: string;
  pid: number;
  command: string;
  cwd: string | null;
  dead: boolean;
}

export interface TmuxSourceOptions {
  runner: CommandRunner;
  clock: Clock;
  worktrees?: readonly string[];
  socketName?: string | null;
  socketPath?: string | null;
  tmuxExecutable?: string;
  processes?: ProcessLookup;
}

interface TmuxRun extends CommandResult {
  denied: boolean;
}

export function parseTmuxPanes(stdout: string): TmuxPane[] {
  const panes: TmuxPane[] = [];
  for (const line of stdout.split(/\r?\n/)) {
    if (line === "") continue;
    const fields = line.split("\t");
    if (fields.length < 9) continue;
    const pid = Number(fields[5]);
    if (!Number.isInteger(pid) || pid <= 0) continue;
    const cwd = fields.slice(7, -1).join("\t");
    const dead = (fields[fields.length - 1] ?? "").trim();
    panes.push({
      sessionId: fields[0] ?? "",
      sessionName: fields[1] ?? "",
      windowId: fields[2] ?? "",
      windowName: fields[3] ?? "",
      paneId: fields[4] ?? "",
      pid,
      command: fields[6] ?? "",
      cwd: cwd.length > 0 && cwd.length <= 400 ? cwd : null,
      dead: dead === "1",
    });
  }
  return panes;
}

export function createTmuxSource(options: TmuxSourceOptions): SessionSource {
  return {
    collect(signal) {
      return collectTmux(options, signal);
    },
  };
}

function findTmux(explicit: string | undefined): string | null {
  if (explicit && path.isAbsolute(explicit)) return existsSync(explicit) ? explicit : null;
  for (const segment of (process.env.PATH ?? "").split(path.delimiter)) {
    if (!segment) continue;
    const candidate = path.join(segment, "tmux");
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function makeHealth(status: SourceHealth["status"], reasonCode: string, now: string, cliVersion: string | null): SourceHealth {
  return sourceHealthSchema.parse({
    sourceId: "tmux",
    status,
    checkedAt: now,
    lastSuccessAt: status === "ok" ? now : null,
    reasonCode,
    cliVersion,
    parserVersion: PARSER_VERSION,
    provenance: "live",
  });
}

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex").slice(0, 16);
}

function clip(value: string, max: number): string {
  return Array.from(redactText(value).replace(/\s+/g, " ").trim()).slice(0, max).join("");
}

function socketPrefix(options: TmuxSourceOptions): string[] {
  if (options.socketPath) return ["-S", options.socketPath];
  if (options.socketName) return ["-L", options.socketName];
  return [];
}

function worktreeFor(cwd: string | null, roots: readonly string[]): string | null {
  if (!cwd) return null;
  let realCwd: string;
  try {
    realCwd = realpathSync(cwd);
  } catch {
    return null;
  }
  let best: string | null = null;
  for (const root of roots) {
    let realRoot: string;
    try {
      realRoot = realpathSync(root);
    } catch {
      continue;
    }
    if (realCwd !== realRoot && !realCwd.startsWith(`${realRoot}${path.sep}`)) continue;
    if (!best || realRoot.length > best.length) best = realRoot;
  }
  return best;
}

function sessionFromPane(
  pane: TmuxPane,
  provider: ProviderName,
  providerPid: number,
  factsCwd: string | null,
  factsTicks: number,
  options: TmuxSourceOptions,
  now: string,
  serverKey: string,
): AgentSession {
  const label = clip(pane.windowName, 160) || provider;
  const workspaceId = pane.sessionId.length > 0 && pane.sessionId.length <= 120 ? pane.sessionId : digest(pane.sessionId || pane.paneId);
  const root = worktreeFor(factsCwd, options.worktrees ?? []);
  const decision = root ? readLoopManifest(root, options.clock.now()) : null;
  const matched = decision?.ok === true
    && decision.manifest.pid === providerPid
    && decision.manifest.processStartTicks === factsTicks
    && decision.manifest.provider === provider;
  const loop = matched && decision?.ok
    ? {
        kind: decision.manifest.kind,
        state: decision.manifest.state,
        iteration: decision.manifest.iteration,
        objective: decision.manifest.objective,
        source: "manifest" as const,
      }
    : null;
  return agentSessionSchema.parse({
    id: `tmux:${digest(serverKey)}:${pane.paneId}`,
    provider,
    runtime: "tmux",
    sessionIdentity: matched && decision?.ok ? decision.manifest.sessionIdentity : null,
    workspaceId,
    paneId: pane.paneId,
    label,
    cwd: factsCwd && factsCwd.length <= 400 ? factsCwd : pane.cwd,
    status: "unknown",
    stateChangeSeq: 0,
    enteredAt: now,
    lastOutputAt: null,
    observedAt: now,
    evidenceSource: loop ? "manifest" : "tmux",
    confidence: "unknown",
    pid: providerPid,
    loop,
  });
}

async function collectTmux(options: TmuxSourceOptions, signal: AbortSignal): Promise<{ sessions: AgentSession[]; health: SourceHealth }> {
  const now = options.clock.now().toISOString();
  const executable = findTmux(options.tmuxExecutable);
  if (!executable) return { sessions: [], health: makeHealth("missing", "tmux_missing", now, null) };
  const lookup = options.processes ?? { inspect: inspectProcess };
  const privateDir = mkdtempSync(path.join(tmpdir(), "herdr-tmux-"));
  const run = async (args: string[]): Promise<TmuxRun> => {
    try {
      const result = await options.runner.run(
        {
          executable,
          args,
          cwd: privateDir,
          timeoutMs: 8_000,
          maxBytes: 1_048_576,
          allowedEnvironment: {
            PATH: process.env.PATH ?? "",
            HOME: privateDir,
            // The C locale makes tmux replace tab separators with underscores.
            LANG: "C.UTF-8",
            LC_ALL: "C.UTF-8",
            ...(process.env.TMUX_TMPDIR ? { TMUX_TMPDIR: process.env.TMUX_TMPDIR } : {}),
          },
        },
        signal,
      );
      return { ...result, denied: false };
    } catch (error) {
      if (error instanceof CommandDeniedError) {
        return { code: null, stdout: "", stderr: "", timedOut: false, truncated: false, denied: true };
      }
      throw error;
    }
  };

  try {
    const version = await run(["-V"]);
    const cliVersion = version.code === 0 ? (version.stdout.trim().split("\n")[0] ?? "").slice(0, 80) || null : null;
    const listed = await run([...socketPrefix(options), "list-panes", "-a", "-F", TMUX_PANE_FORMAT]);
    if (listed.denied) return { sessions: [], health: makeHealth("unsupported", "command_denied", now, cliVersion) };
    if (listed.timedOut) return { sessions: [], health: makeHealth("timeout", "timeout", now, cliVersion) };
    if (listed.truncated) return { sessions: [], health: makeHealth("parse_error", "truncated", now, cliVersion) };
    if (listed.code !== 0) return { sessions: [], health: makeHealth("missing", "tmux_server_missing", now, cliVersion) };
    const serverKey = options.socketPath ?? options.socketName ?? "default";
    const sessions: AgentSession[] = [];
    for (const pane of parseTmuxPanes(listed.stdout)) {
      if (pane.dead || pane.paneId.length === 0 || pane.paneId.length > 120) continue;
      const match = findProvider(pane.pid, lookup);
      if (!match) continue;
      sessions.push(sessionFromPane(pane, match.provider, match.pid, match.facts.cwd, match.facts.startTicks, options, now, serverKey));
    }
    return { sessions, health: makeHealth("ok", "observed", now, cliVersion) };
  } finally {
    rmSync(privateDir, { recursive: true, force: true });
  }
}
