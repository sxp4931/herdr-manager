import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync, readlinkSync } from "node:fs";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { frozenClock, type CommandRunner } from "@herdr/contracts";
import { createCommandRunner } from "../../apps/server/src/adapters/command-runner.js";
import { createGitSource } from "../../apps/server/src/adapters/git-source.js";
import {
  createActivityFixture,
  createConflictFixture,
  createStateFixture,
  gitExecutable,
  type ActivityFixture,
  type ConflictFixture,
  type StateFixture,
} from "../helpers/git-fixture.js";

const clock = frozenClock("2026-09-29T16:00:00.000Z");
const observedAt = "2026-09-29T16:00:00.000Z";
const cleanups: Array<() => void> = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

function auditingRunner(): { runner: CommandRunner; calls: string[][] } {
  const inner = createCommandRunner();
  const calls: string[][] = [];
  return {
    calls,
    runner: {
      async run(request, signal) {
        calls.push([...request.args]);
        return inner.run(request, signal);
      },
    },
  };
}

function hashTree(directory: string): string {
  const hash = createHash("sha256");
  const walk = (current: string, prefix: string): void => {
    const entries = readdirSync(current, { withFileTypes: true }).sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      if (entry.name === ".git") continue;
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      const full = path.join(current, entry.name);
      if (entry.isSymbolicLink()) {
        hash.update(`link ${relative}\0${readlinkSync(full)}\0`);
      } else if (entry.isDirectory()) {
        walk(full, relative);
      } else if (entry.isFile()) {
        hash.update(`file ${relative}\0`);
        hash.update(readFileSync(full));
        hash.update("\0");
      }
    }
  };
  walk(directory, "");
  return hash.digest("hex");
}

function repoSnapshot(directory: string): { head: string; status: string; files: string } {
  const git = gitExecutable();
  const head = spawnSync(git, ["-C", directory, "rev-parse", "HEAD"], { encoding: "utf8" });
  const status = spawnSync(git, ["-C", directory, "status", "--porcelain=v1", "-z", "--untracked-files=normal"], { encoding: "utf8" });
  return {
    head: head.status === 0 ? head.stdout : `missing:${head.stderr}`,
    status: status.stdout,
    files: hashTree(directory),
  };
}

describe("git worktree collection", () => {
  it("reads two allowed worktrees and leaves the repository unchanged", async () => {
    const fixture: ActivityFixture = createActivityFixture();
    cleanups.push(fixture.cleanup);
    const before = {
      repo: repoSnapshot(fixture.repo),
      feature: repoSnapshot(fixture.feature),
      outside: repoSnapshot(fixture.outside),
    };
    const audit = auditingRunner();
    const source = createGitSource({ runner: audit.runner, clock });
    const result = await source.collect([fixture.repo, fixture.feature, fixture.repo], new AbortController().signal);
    const after = {
      repo: repoSnapshot(fixture.repo),
      feature: repoSnapshot(fixture.feature),
      outside: repoSnapshot(fixture.outside),
    };
    expect(after).toEqual(before);
    expect(JSON.stringify(result)).not.toContain("SYNTHETIC_SECRET_SENTINEL");
    expect(result.health.status).toBe("ok");
    expect(result.health.cliVersion).toBe(spawnSync(gitExecutable(), ["--version"], { encoding: "utf8" }).stdout.trim());
    const allowed = result.worktrees.filter((entry) => entry.health.status === "ok");
    const excluded = result.worktrees.filter((entry) => entry.health.reasonCode === "outside_root");
    expect(allowed).toHaveLength(2);
    expect(excluded).toHaveLength(1);
    const main = allowed.find((entry) => entry.path === fixture.repo);
    const feature = allowed.find((entry) => entry.path === fixture.feature);
    const outside = excluded[0];
    expect(main?.branch).toBe("main");
    expect(feature?.branch).toBe("feature");
    expect(main?.branch).not.toBe(feature?.branch);
    expect(main?.head).toBe(fixture.mainHead);
    expect(feature?.head).toBe(fixture.featureHead);
    expect(main?.head).not.toBe(feature?.head);
    expect(main?.detached).toBe(false);
    expect(main?.staged).toBe(1);
    expect(main?.modified).toBe(1);
    expect(main?.untracked).toBe(1);
    expect(main?.conflicted).toBe(0);
    expect(feature?.staged).toBe(2);
    expect(feature?.modified).toBe(1);
    expect(feature?.untracked).toBe(0);
    expect(feature?.conflicted).toBe(0);
    expect(main?.recentCommits[0]).toMatchObject({
      sha: fixture.mainHead,
      subject: "second [redacted-secret]",
      committedAt: fixture.mainCommittedAt,
    });
    expect(main?.recentCommits[1]?.subject).toBe("first commit");
    expect(feature?.recentCommits[0]).toMatchObject({
      sha: fixture.featureHead,
      subject: "feature commit",
      committedAt: fixture.featureCommittedAt,
    });
    expect(main?.repositoryId).toBe(feature?.repositoryId);
    expect(outside?.repositoryId).toBe(main?.repositoryId);
    expect(outside?.path).toBe(fixture.outside);
    expect(outside?.branch).toBe("elsewhere");
    expect(outside?.recentCommits).toEqual([]);
    expect(outside?.staged).toBe(0);
    expect(outside?.health.status).toBe("disabled");
    expect(main?.observedAt).toBe(observedAt);
    expect(audit.calls.some((args) => args.includes(fixture.outside))).toBe(false);
    for (const args of audit.calls) {
      expect(args).not.toEqual(expect.arrayContaining(["reset"]));
      expect(args).not.toEqual(expect.arrayContaining(["commit"]));
      expect(args).not.toEqual(expect.arrayContaining(["add"]));
      expect(args).not.toEqual(expect.arrayContaining(["checkout"]));
      expect(args).not.toEqual(expect.arrayContaining(["diff"]));
      expect(args).not.toEqual(expect.arrayContaining(["config"]));
      expect(args).not.toEqual(expect.arrayContaining(["clean"]));
      expect(args).not.toEqual(expect.arrayContaining(["merge"]));
    }
    const paths = result.worktrees.map((entry) => entry.path);
    expect(new Set(paths).size).toBe(paths.length);
  });

  it("counts a conflict without resolving it", async () => {
    const fixture: ConflictFixture = createConflictFixture();
    cleanups.push(fixture.cleanup);
    const before = repoSnapshot(fixture.repo);
    const source = createGitSource({ runner: createCommandRunner(), clock });
    const result = await source.collect([fixture.repo], new AbortController().signal);
    expect(repoSnapshot(fixture.repo)).toEqual(before);
    expect(result.worktrees).toHaveLength(1);
    expect(result.worktrees[0]).toMatchObject({
      conflicted: 1,
      staged: 0,
      modified: 0,
      untracked: 0,
      branch: "main",
    });
    expect(result.worktrees[0]?.health.status).toBe("ok");
  });

  it("reports detached, unborn, locked, and missing worktrees", async () => {
    const fixture: StateFixture = createStateFixture();
    cleanups.push(fixture.cleanup);
    const before = {
      detached: repoSnapshot(fixture.detached),
      locked: repoSnapshot(fixture.locked),
      lockedRepo: repoSnapshot(fixture.lockedRepo),
    };
    const audit = auditingRunner();
    const source = createGitSource({ runner: audit.runner, clock });
    const detached = await source.collect([fixture.detached], new AbortController().signal);
    const unborn = await source.collect([fixture.unborn], new AbortController().signal);
    const linked = await source.collect([fixture.lockedRepo, fixture.locked, fixture.missing], new AbortController().signal);
    expect(repoSnapshot(fixture.detached)).toEqual(before.detached);
    expect(repoSnapshot(fixture.locked)).toEqual(before.locked);
    expect(repoSnapshot(fixture.lockedRepo)).toEqual(before.lockedRepo);
    expect(detached.worktrees).toHaveLength(1);
    expect(detached.worktrees[0]).toMatchObject({
      detached: true,
      branch: null,
      head: fixture.detachedHead,
    });
    expect(detached.worktrees[0]?.recentCommits[0]?.subject).toBe("detached base");
    expect(unborn.worktrees).toHaveLength(1);
    expect(unborn.worktrees[0]).toMatchObject({
      branch: "main",
      head: null,
      detached: false,
      untracked: 1,
      staged: 0,
    });
    expect(unborn.worktrees[0]?.health).toMatchObject({ status: "ok", reasonCode: "unborn" });
    expect(unborn.worktrees[0]?.recentCommits).toEqual([]);
    const locked = linked.worktrees.find((entry) => entry.path === fixture.locked);
    const missing = linked.worktrees.find((entry) => entry.path === fixture.missing);
    expect(locked).toMatchObject({ locked: true, branch: "locked-branch", staged: 0, modified: 0, untracked: 0 });
    expect(locked?.health.status).toBe("ok");
    expect(missing).toMatchObject({ prunable: true, staged: 0, recentCommits: [] });
    expect(missing?.health).toMatchObject({ status: "missing", reasonCode: "worktree_missing" });
    expect(audit.calls.some((args) => args.includes(fixture.missing) && args.includes("status"))).toBe(false);
  });

  it("reports an empty directory and an empty root list as missing", async () => {
    const fixture: StateFixture = createStateFixture();
    cleanups.push(fixture.cleanup);
    const source = createGitSource({ runner: createCommandRunner(), clock });
    const missing = await source.collect([fixture.empty], new AbortController().signal);
    const none = await source.collect([], new AbortController().signal);
    expect(missing.worktrees).toHaveLength(1);
    expect(missing.worktrees[0]?.health).toMatchObject({ status: "missing", reasonCode: "not_a_repository" });
    expect(missing.health.reasonCode).toBe("not_a_repository");
    expect(none.worktrees).toEqual([]);
    expect(none.health).toMatchObject({ status: "missing", reasonCode: "no_roots" });
  });
});
