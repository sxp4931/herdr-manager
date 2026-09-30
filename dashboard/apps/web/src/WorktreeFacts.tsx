import type { GitWorktree } from "@herdr/contracts";
import { healthLabel } from "./format.js";

export function WorktreeFacts({ tree }: { tree: GitWorktree }) {
  return (
    <div className="worktree">
      <p>
        <span className="k">Branch</span> {tree.branch ?? "detached"}
      </p>
      <p>
        <span className="k">Changes</span> staged {tree.staged}, modified {tree.modified}, untracked {tree.untracked}, conflicted {tree.conflicted}
      </p>
      <p>
        <span className="k">Worktree health</span> {healthLabel(tree.health.status)}
      </p>
      {tree.recentCommits.length > 0 ? (
        <ul className="commits" aria-label="Recent commits">
          {tree.recentCommits.map((commit) => (
            <li key={commit.sha}>
              <code title={commit.sha}>{commit.sha}</code> {commit.subject}
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
