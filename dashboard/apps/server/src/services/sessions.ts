import { realpathSync } from "node:fs";
import type { AgentSession } from "@herdr/contracts";

function sameCwd(left: string, right: string): boolean {
  if (left === right) return true;
  try {
    return realpathSync(left) === realpathSync(right);
  } catch {
    return false;
  }
}

/** Pid and cwd must both be present and agree. A provider mismatch stays two rows. */
export function sameProcessIdentity(left: AgentSession, right: AgentSession): boolean {
  if (left.pid === null || right.pid === null || left.pid !== right.pid) return false;
  if (left.cwd === null || right.cwd === null || !sameCwd(left.cwd, right.cwd)) return false;
  return left.provider === right.provider;
}

function mergePair(herdr: AgentSession, tmux: AgentSession): AgentSession {
  const loop = herdr.loop ?? tmux.loop;
  return {
    ...herdr,
    label: herdr.label || tmux.label,
    cwd: herdr.cwd ?? tmux.cwd,
    pid: herdr.pid ?? tmux.pid,
    sessionIdentity: herdr.sessionIdentity ?? tmux.sessionIdentity,
    loop,
    evidenceSource: loop?.source === "manifest" && herdr.loop === null ? "manifest" : herdr.evidenceSource,
  };
}

/**
 * Herdr is authoritative for matched rows. Tmux rows remain when pid or cwd
 * does not prove they are the same process.
 */
export function reconcileSessions(herdr: readonly AgentSession[], tmux: readonly AgentSession[]): AgentSession[] {
  const consumed = new Set<number>();
  const merged: AgentSession[] = [];
  for (const session of herdr) {
    const index = tmux.findIndex((candidate, candidateIndex) => !consumed.has(candidateIndex) && sameProcessIdentity(session, candidate));
    if (index === -1) {
      merged.push(session);
      continue;
    }
    consumed.add(index);
    const match = tmux[index];
    merged.push(match ? mergePair(session, match) : session);
  }
  tmux.forEach((session, index) => {
    if (!consumed.has(index)) merged.push(session);
  });
  return merged;
}
