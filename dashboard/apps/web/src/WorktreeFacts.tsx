import type { GitWorktree } from "@herdr/contracts";
import { healthLabel } from "./format.js";

export function WorktreeFacts({ tree }: { tree: GitWorktree }) {
  return (
    <div className="worktree">
      <p>Branch {tree.branch ?? "detached"}</p>
      <p>
        staged {tree.staged}, modified {tree.modified}, untracked {tree.untracked}, conflicted {tree.conflicted}
      </p>
      <ul>
        {tree.recentCommits.map((commit) => (
          <li key={commit.sha}>
            {commit.sha} {commit.subject}
          </li>
        ))}
      </ul>
      <p>Worktree health {healthLabel(tree.health.status)}</p>
    </div>
  );
}
