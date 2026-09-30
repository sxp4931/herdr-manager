import type { AgentSession, GitWorktree } from "@herdr/contracts";
import { unmappedWorktrees } from "./sessions.js";
import { WorktreeFacts } from "./WorktreeFacts.js";

export function GitPanel({ sessions, worktrees }: { sessions: readonly AgentSession[]; worktrees: readonly GitWorktree[] }) {
  const unmapped = unmappedWorktrees(sessions, worktrees);
  return (
    <section className="panel" aria-labelledby="unmapped-worktrees-heading">
      <h2 id="unmapped-worktrees-heading">Unmapped worktrees</h2>
      {unmapped.length === 0 ? <p>No unmapped worktrees</p> : (
        <ul className="unmapped-list">
          {unmapped.map((tree) => (
            <li key={tree.id}>
              <p>{tree.path}</p>
              <WorktreeFacts tree={tree} />
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
