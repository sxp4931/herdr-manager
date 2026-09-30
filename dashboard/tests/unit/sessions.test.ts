import { describe, expect, it } from "vitest";
import { scenarios } from "@herdr/contracts";
import { formatElapsed } from "../../apps/web/src/format.js";
import { filterSessions, sortSessions, unmappedWorktrees, worktreeForCwd } from "../../apps/web/src/sessions.js";

const NOW = "2026-09-29T16:00:00.000Z";

describe("agent triage", () => {
  it("sorts blocked, working, idle, done, then unknown, with id as the tie-break", () => {
    const sessions = sortSessions(scenarios.daily.sessions);
    expect(sessions.map((session) => session.status)).toEqual([
      "working",
      "working",
      "working",
      "working",
      "done",
      "unknown",
    ]);
    expect(sessions.map((session) => session.label)).toEqual([
      "daily-claude-worker",
      "daily-codex-worker",
      "daily-grok-worker",
      "goal-runner",
      "<img src=x onerror=alert(1)>",
      "codex-process-only",
    ]);
    expect(sessions.at(-1)?.status).toBe("unknown");
  });

  it("filters by provider and search without treating unknown as idle", () => {
    const claude = filterSessions(scenarios.daily.sessions, { provider: "claude", status: "all", search: "" });
    expect(claude.map((session) => session.label)).toEqual(["daily-claude-worker", "goal-runner"]);
    const goal = filterSessions(scenarios.daily.sessions, { provider: "all", status: "all", search: "goal-runner" });
    expect(goal.map((session) => session.label)).toEqual(["goal-runner"]);
    const unknown = filterSessions(scenarios.daily.sessions, { provider: "all", status: "unknown", search: "" });
    expect(unknown.map((session) => session.status)).toEqual(["unknown"]);
    expect(formatElapsed("2026-09-29T15:40:00.000Z", NOW)).toBe("20 minutes");
    expect(formatElapsed("2026-09-29T14:00:00.000Z", NOW)).toBe("2 hours");
  });

  it("maps a cwd to the most specific worktree and leaves other trees unmapped", () => {
    const demo = scenarios.daily.worktrees[0];
    if (!demo) throw new Error("missing demo worktree");
    const nested = { ...demo, id: "git:nested", path: "/work/demo/pkg" };
    const sibling = { ...demo, id: "git:sibling", path: "/work/demo-extra" };
    const trees = [demo, nested, sibling];
    expect(worktreeForCwd("/work/demo", trees)?.id).toBe("git:demo");
    expect(worktreeForCwd("/work/demo/pkg/src", trees)?.id).toBe("git:nested");
    expect(worktreeForCwd("/work/demo-extra", trees)?.id).toBe("git:sibling");
    expect(worktreeForCwd("/work/other", trees)).toBeNull();
    expect(worktreeForCwd(null, trees)).toBeNull();
    const unmapped = unmappedWorktrees(
      scenarios.daily.sessions.filter((session) => session.cwd === "/work/demo"),
      trees,
    );
    expect(unmapped.map((tree) => tree.id)).toEqual(["git:nested", "git:sibling"]);
  });
});
