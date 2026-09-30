import type { AgentSession, GitWorktree } from "@herdr/contracts";

const STATUS_ORDER: Record<AgentSession["status"], number> = {
  blocked: 0,
  working: 1,
  idle: 2,
  done: 3,
  unknown: 4,
};

export function statusLabel(status: AgentSession["status"]): string {
  switch (status) {
    case "blocked":
      return "Blocked";
    case "working":
      return "Working";
    case "idle":
      return "Idle";
    case "done":
      return "Done";
    case "unknown":
      return "Unknown";
  }
}

export function providerLabel(provider: string): string {
  if (provider === "claude") return "Claude";
  if (provider === "codex") return "Codex";
  if (provider === "grok") return "Grok";
  return provider;
}

export function sortSessions(sessions: readonly AgentSession[]): AgentSession[] {
  return [...sessions].sort((left, right) => {
    const byStatus = STATUS_ORDER[left.status] - STATUS_ORDER[right.status];
    if (byStatus !== 0) return byStatus;
    if (left.id < right.id) return -1;
    if (left.id > right.id) return 1;
    return 0;
  });
}

export function filterSessions(
  sessions: readonly AgentSession[],
  query: { provider: string; status: string; search: string },
): AgentSession[] {
  const needle = query.search.trim().toLowerCase();
  const matched = sessions.filter((session) => {
    if (query.provider !== "all" && session.provider !== query.provider) return false;
    if (query.status !== "all" && session.status !== query.status) return false;
    if (needle.length === 0) return true;
    const haystack = [session.label, session.id, session.cwd ?? "", session.sessionIdentity ?? "", session.provider]
      .join("\n")
      .toLowerCase();
    return haystack.includes(needle);
  });
  return sortSessions(matched);
}

export function worktreeForCwd(cwd: string | null, worktrees: readonly GitWorktree[]): GitWorktree | null {
  if (cwd === null || cwd.length === 0) return null;
  const matches = worktrees.filter((tree) => pathCovers(tree.path, cwd));
  matches.sort((left, right) => right.path.length - left.path.length || compareText(left.id, right.id));
  return matches[0] ?? null;
}

export function unmappedWorktrees(sessions: readonly AgentSession[], worktrees: readonly GitWorktree[]): GitWorktree[] {
  const mapped = new Set<string>();
  for (const session of sessions) {
    const match = worktreeForCwd(session.cwd, worktrees);
    if (match) mapped.add(match.id);
  }
  return [...worktrees].filter((tree) => !mapped.has(tree.id)).sort((left, right) => compareText(left.id, right.id));
}

function pathCovers(root: string, cwd: string): boolean {
  if (cwd === root) return true;
  const prefix = root.endsWith("/") ? root : `${root}/`;
  return cwd.startsWith(prefix);
}

function compareText(left: string, right: string): number {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}
